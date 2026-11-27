#!/usr/bin/env python3
"""Restores a fake interlaced SD tape clip and checks the master.

    python3 test_restore.py --esrgan /path/to/realesrgan-ncnn-vulkan [--encoder libx264]

Checks: output size (1080p, 4:3 after square pixels and edge trim), frame count and
duration match the input stretch, audio survives, interrupted renders resume, and the
plain lanczos path works too.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import restore  # noqa: E402


def ffprobe(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-print_format", "json",
                          "-show_streams", "-show_format", path], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def make_tape(path, size):
    # NTSC DV-style: interlaced, 10:11 pixels, noisy, with a tone.
    subprocess.run([
        "ffmpeg", "-y", "-loglevel", "error",
        "-f", "lavfi", "-i", f"testsrc2=s={size}:r=60000/1001,noise=alls=12:allf=t",
        "-f", "lavfi", "-i", "sine=f=440:r=48000",
        "-t", "12", "-vf", "setsar=10/11,interlace=scan=tff",  # 59.94p fields -> 29.97i
        "-c:v", "libx264", "-flags", "+ildct+ilme", "-x264opts", "tff=1", "-pix_fmt", "yuv420p",
        "-c:a", "aac", path], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--esrgan", required=True)
    ap.add_argument("--encoder", default="libx264")
    ap.add_argument("--quick", action="store_true",
                    help="small 360x240 tape and 1 s of AI upscaling (for CPU-only test machines)")
    args = ap.parse_args()
    size, seconds, height = ("360x240", 1, 480) if args.quick else ("720x480", 3, 1080)
    fails = []

    with tempfile.TemporaryDirectory() as tmp:
        tape = os.path.join(tmp, "tape.mp4")
        make_tape(tape, size)
        info = restore.probe(tape)
        print("source:", info["width"], "x", info["height"], info["field_order"], f"{info['fps']:.3f} fps")

        # AI path, 3 seconds starting mid-tape, small chunks to exercise joining + resume.
        restore.CHUNK_FRAMES = 8 if args.quick else 20
        out = os.path.join(tmp, "master.mov")
        work = os.path.join(tmp, "work")
        common = [tape, "--start", "2", "--end", str(2 + seconds), "--esrgan", args.esrgan,
                  "--encoder", args.encoder, "--work", work, "--height", str(height)]
        restore.main(common + ["-o", out, "--keep-work", "--force-deinterlace"])
        # Simulate an interrupted render: drop the last chunk and the output, run again.
        chunks = sorted(f for f in os.listdir(work) if f.startswith("chunk_"))
        os.remove(os.path.join(work, chunks[-1]))
        os.remove(out)
        restore.main(common + ["-o", out, "--force-deinterlace"])

        m = ffprobe(out)
        v = next(s for s in m["streams"] if s["codec_type"] == "video")
        has_audio = any(s["codec_type"] == "audio" for s in m["streams"])
        dur = float(m["format"]["duration"])
        frames = int(v["nb_read_frames"])
        print(f"master: {v['width']}x{v['height']}, {frames} frames, {dur:.2f} s, audio={has_audio}, "
              f"chunks={len(chunks)}")
        if v["height"] != height:
            fails.append(f"height {v['height']} != {height}")
        ratio = v["width"] / v["height"]
        # 720x480 @ 10:11 -> 654x480 square, minus 2%/4% edges -> ~1.36:1
        if not 1.30 < ratio < 1.42:
            fails.append(f"aspect {ratio:.3f} not ~4:3")
        if abs(frames - seconds * 29.97) > 3:
            fails.append(f"{frames} frames, expected ~{seconds * 30}")
        if abs(dur - seconds) > 0.25:
            fails.append(f"duration {dur:.2f}, expected ~{seconds}")
        if not has_audio:
            fails.append("no audio")
        if len(chunks) < 4:
            fails.append("expected several chunks")

        # Plain path.
        out2 = os.path.join(tmp, "plain.mov")
        restore.main([tape, "--start", "0", "--end", "2", "--upscaler", "lanczos", "--height", "720",
                      "--encoder", args.encoder, "-o", out2, "--stabilize", "--smooth-motion",
                      "--force-deinterlace"])
        v2 = next(s for s in ffprobe(out2)["streams"] if s["codec_type"] == "video")
        print(f"plain: {v2['width']}x{v2['height']}, {v2['nb_read_frames']} frames (60p)")
        if v2["height"] != 720 or abs(int(v2["nb_read_frames"]) - 2 * 59.94) > 4:
            fails.append("plain/smooth-motion output wrong")

    if fails:
        print("\nFAIL\n  " + "\n  ".join(fails))
        sys.exit(1)
    print("\nPASS: restoration pipeline works end to end")


if __name__ == "__main__":
    main()
