#!/usr/bin/env python3
"""CineFam Phase 4 prototype: restore and upscale one stretch of a tape into a "restored master".

    python3 restore.py TAPE.mov --start 42.3 --end 70 -o master.mov \
        [--upscaler esrgan|lanczos] [--esrgan /path/to/realesrgan-ncnn-vulkan] \
        [--model fast|detailed] [--strength 0.6] [--height 1080] [--smooth-motion] \
        [--stabilize] [--no-color] [--no-edges] [--no-audio-cleanup] [--encoder libx264]

The Swift `Restorer` is a port of this file: same stages, same FFmpeg filter graphs.

Stages
  1. Prepass (one continuous FFmpeg run, so temporal filters never restart):
     deinterlace → square pixels → trim tape-edge noise → denoise → stabilize → auto color,
     plus audio cleanup. Written losslessly (FFV1 + FLAC) at the original size.
  2. Upscale in chunks of frames so disk use stays small: extract PNGs → Real-ESRGAN →
     blend with a plain lanczos scale by `strength` (1.0 = all AI) → encode the chunk.
     Chunks already on disk are reused, so an interrupted render picks up where it stopped.
  3. Join the chunks and add the cleaned audio.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys

CHUNK_FRAMES = 240

MODELS = {  # name -> (model file, allowed scales)
    "fast": ("realesr-animevideov3", (2, 3, 4)),
    "detailed": ("realesrgan-x4plus", (4,)),
}


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit(f"command failed: {' '.join(cmd[:6])} ...\n{r.stderr[-1500:]}")
    return r


def probe(path):
    out = run(["ffprobe", "-v", "error", "-print_format", "json", "-show_streams", "-show_format", path])
    data = json.loads(out.stdout)
    v = next(s for s in data["streams"] if s["codec_type"] == "video")
    num, den = v.get("r_frame_rate", "30000/1001").split("/")
    return {
        "width": v["width"], "height": v["height"],
        "fps_str": v.get("r_frame_rate", "30000/1001"), "fps": float(num) / float(den),
        "field_order": v.get("field_order", "unknown"),
        "nb_frames": int(v["nb_frames"]) if v.get("nb_frames", "").isdigit() else None,
        "duration": float(data["format"].get("duration", 0)),
        "has_audio": any(s["codec_type"] == "audio" for s in data["streams"]),
    }


def even(x):
    return max(2, int(round(x / 2)) * 2)


# ------------------------------------------------------------------ filter graphs (shared with Swift)

def prepass_video_filter(interlaced, smooth_motion, clean_edges, denoise, stabilize, auto_color):
    f = []
    if interlaced:
        f.append("bwdif=mode=send_field" if smooth_motion else "bwdif=mode=send_frame")
    f.append("scale=trunc(iw*sar/2)*2:ih:flags=lanczos,setsar=1")        # square pixels
    if clean_edges:   # VHS head-switching noise at the bottom, ragged sides
        f.append("crop=trunc(iw*0.98/2)*2:trunc(ih*0.96/2)*2:trunc(iw*0.01):trunc(ih*0.01)")
    if denoise == "light":
        f.append("hqdn3d=2:3:3:4.5")
    elif denoise == "strong":
        f.append("hqdn3d=4:6:6:9")
    if stabilize:
        f.append("deshake=edge=mirror")
    if auto_color:
        f.append("normalize=blackpt=black:whitept=white:smoothing=48:independence=0.5:strength=0.6")
    return ",".join(f)


AUDIO_CLEANUP = "highpass=f=70,afftdn=nf=-25,loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000"  # loudnorm outputs 192 kHz


def upscale_blend_filter(w, h, strength):
    k = f"{strength:.2f}"
    return (f"[0:v]scale={w}:{h}:flags=lanczos[ai];[1:v]scale={w}:{h}:flags=lanczos[plain];"
            f"[ai][plain]blend=all_expr='A*{k}+B*(1-{k})',format=yuv420p10le[v]")


def lanczos_filter(w, h):
    return f"scale={w}:{h}:flags=lanczos,cas=0.4,format=yuv420p10le"


def master_codec(encoder):
    if encoder == "hevc_videotoolbox":
        return ["-c:v", "hevc_videotoolbox", "-q:v", "80", "-profile:v", "main10", "-tag:v", "hvc1"]
    return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "16", "-pix_fmt", "yuv420p"]  # test stand-in


# ------------------------------------------------------------------ pipeline

def restore(a):
    work = a.work or (os.path.splitext(a.output)[0] + ".work")
    os.makedirs(work, exist_ok=True)
    src = probe(a.tape)
    interlaced = src["field_order"] not in ("progressive", "unknown", "")

    # 1. Prepass
    inter = os.path.join(work, "prepass.mkv")
    if not os.path.exists(inter):
        vf = prepass_video_filter(interlaced or a.force_deinterlace, a.smooth_motion, not a.no_edges,
                                  a.denoise, a.stabilize, not a.no_color)
        cmd = ["ffmpeg", "-hide_banner", "-y", "-ss", f"{a.start:.3f}", "-to", f"{a.end:.3f}", "-i", a.tape,
               "-map", "0:v:0", "-vf", vf, "-c:v", "ffv1", "-level", "3", "-pix_fmt", "yuv420p"]
        if src["has_audio"]:
            cmd += ["-map", "0:a:0"] + ([] if a.no_audio_cleanup else ["-af", AUDIO_CLEANUP]) + ["-c:a", "flac"]
        run(cmd + [inter + ".part.mkv"])
        os.replace(inter + ".part.mkv", inter)
    p = probe(inter)
    frames = p["nb_frames"] or int(round(p["duration"] * p["fps"]))
    h = a.height or p["height"]
    w = even(h * p["width"] / p["height"])
    print(f"prepass: {p['width']}x{p['height']} @ {p['fps']:.3f} fps, {frames} frames -> target {w}x{h}")

    # 2. Upscale in chunks
    chunks = []
    if a.upscaler == "esrgan":
        model, scales = MODELS[a.model]
        scale = next((s for s in scales if p["height"] * s >= h), scales[-1])
        for i, first in enumerate(range(0, frames, CHUNK_FRAMES)):
            n = min(CHUNK_FRAMES, frames - first)
            chunk = os.path.join(work, f"chunk_{i:05d}.mov")
            chunks.append(chunk)
            if os.path.exists(chunk):
                continue                                   # resume
            fin, fout = os.path.join(work, "in"), os.path.join(work, "out")
            for d in (fin, fout):
                shutil.rmtree(d, ignore_errors=True)
                os.makedirs(d)
            run(["ffmpeg", "-hide_banner", "-y", "-ss", f"{first / p['fps']:.6f}", "-i", inter,
                 "-frames:v", str(n), "-start_number", "1", os.path.join(fin, "%08d.png")])
            run([a.esrgan, "-i", fin, "-o", fout, "-n", model, "-s", str(scale), "-f", "png"])
            run(["ffmpeg", "-hide_banner", "-y",
                 "-framerate", p["fps_str"], "-i", os.path.join(fout, "%08d.png"),
                 "-framerate", p["fps_str"], "-i", os.path.join(fin, "%08d.png"),
                 "-filter_complex", upscale_blend_filter(w, h, a.strength), "-map", "[v]",
                 *master_codec(a.encoder), chunk + ".part.mov"])
            os.replace(chunk + ".part.mov", chunk)
            print(f"  chunk {i + 1}: frames {first}-{first + n - 1} at x{scale}")
        shutil.rmtree(os.path.join(work, "in"), ignore_errors=True)
        shutil.rmtree(os.path.join(work, "out"), ignore_errors=True)
    else:
        chunk = os.path.join(work, "chunk_00000.mov")
        chunks.append(chunk)
        if not os.path.exists(chunk):
            run(["ffmpeg", "-hide_banner", "-y", "-i", inter, "-map", "0:v:0", "-vf", lanczos_filter(w, h),
                 *master_codec(a.encoder), chunk + ".part.mov"])
            os.replace(chunk + ".part.mov", chunk)

    # 3. Join + audio
    listing = os.path.join(work, "chunks.txt")
    with open(listing, "w") as fh:
        fh.writelines(f"file '{os.path.abspath(c)}'\n" for c in chunks)
    cmd = ["ffmpeg", "-hide_banner", "-y", "-f", "concat", "-safe", "0", "-i", listing, "-i", inter,
           "-map", "0:v:0", "-c:v", "copy"]
    if p["has_audio"]:
        cmd += ["-map", "1:a:0", "-c:a", "aac", "-b:a", "256k"]
    run(cmd + ["-movflags", "+faststart", a.output])
    if not a.keep_work:
        shutil.rmtree(work, ignore_errors=True)
    return a.output


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("tape")
    ap.add_argument("--start", type=float, default=0)
    ap.add_argument("--end", type=float, required=True)
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--upscaler", choices=["esrgan", "lanczos"], default="esrgan")
    ap.add_argument("--esrgan", default="realesrgan-ncnn-vulkan")
    ap.add_argument("--model", choices=list(MODELS), default="fast")
    ap.add_argument("--strength", type=float, default=0.6)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--denoise", choices=["off", "light", "strong"], default="light")
    ap.add_argument("--smooth-motion", action="store_true")
    ap.add_argument("--stabilize", action="store_true")
    ap.add_argument("--force-deinterlace", action="store_true")
    ap.add_argument("--no-color", action="store_true")
    ap.add_argument("--no-edges", action="store_true")
    ap.add_argument("--no-audio-cleanup", action="store_true")
    ap.add_argument("--encoder", default="hevc_videotoolbox")
    ap.add_argument("--work")
    ap.add_argument("--keep-work", action="store_true")
    return restore(ap.parse_args(argv))


if __name__ == "__main__":
    main()
