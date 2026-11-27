#!/usr/bin/env python3
"""CineFam Phase 1 prototype: find dead space and split a digitized tape into events.

Usage:
    python3 cinefam_segment.py TAPE.mov [-o result.json] [--export-clips DIR]

Needs ffmpeg and ffprobe on PATH (brew install ffmpeg). Standard library only.

How it works (see the implementation plan, stages 2 and 3):
  1. One ffmpeg pass over a small 5 fps proxy runs `signalstats` (brightness, colour,
     spread, frame-to-frame change) and `scdet` (scene-cut score) on every frame.
  2. One audio pass runs `silencedetect`.
  3. Each frame is classified as blue screen, black, static/snow or content.
  4. Runs of non-content frames become dead ranges; content between them is split
     into shots at hard cuts, and shots are grouped into events.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field, asdict

ANALYSIS_FPS = 5


@dataclass
class Settings:
    min_dead_s: float = 1.0          # shortest run of junk frames counted as dead space
    min_black_s: float = 0.4         # black is often a short gap between recordings
    min_event_s: float = 3.0         # live stretches shorter than this are dropped
    event_gap_s: float = 2.0         # dead space at least this long separates events
    cut_score: float = 12.0          # scdet score that counts as a hard cut
    silence_db: int = -50
    silence_min_s: float = 2.0


@dataclass
class Frame:
    t: float
    yavg: float
    uavg: float
    vavg: float
    spread: float   # YHIGH - YLOW: tiny for a flat field
    sat: float
    ydif: float     # mean change from the previous frame
    cut: float      # scdet score
    kind: str = "content"


@dataclass
class Range:
    start: float
    end: float
    reason: str = ""

    @property
    def duration(self) -> float:
        return round(self.end - self.start, 3)


@dataclass
class Event:
    index: int
    start: float
    end: float
    shots: list = field(default_factory=list)
    quiet: bool = False   # mostly silent; worth a look in review


# ---------------------------------------------------------------- ffmpeg helpers

def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, errors="replace")


def probe(path: str) -> dict:
    out = run(["ffprobe", "-v", "error", "-print_format", "json",
               "-show_format", "-show_streams", path])
    if out.returncode != 0:
        sys.exit(f"ffprobe failed: {out.stderr.strip()}")
    data = json.loads(out.stdout)
    video = next((s for s in data["streams"] if s["codec_type"] == "video"), None)
    audio = next((s for s in data["streams"] if s["codec_type"] == "audio"), None)
    if video is None:
        sys.exit("No video stream found.")
    num, den = (video.get("avg_frame_rate") or "0/1").split("/")
    return {
        "path": os.path.abspath(path),
        "duration": float(data["format"].get("duration", 0)),
        "width": video.get("width"),
        "height": video.get("height"),
        "fps": round(float(num) / float(den), 3) if float(den) else None,
        "field_order": video.get("field_order", "unknown"),
        "video_codec": video.get("codec_name"),
        "has_audio": audio is not None,
    }


def analyze_video(path: str) -> list[Frame]:
    vf = (f"fps={ANALYSIS_FPS},scale=160:120,signalstats,scdet=threshold=0,"
          "metadata=mode=print:file=-")
    out = run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-an",
               "-vf", vf, "-f", "null", "-"])
    frames: list[Frame] = []
    cur: dict = {}

    def flush():
        if "t" in cur and "YAVG" in cur:
            frames.append(Frame(
                t=cur["t"], yavg=cur["YAVG"], uavg=cur.get("UAVG", 128),
                vavg=cur.get("VAVG", 128),
                spread=cur.get("YHIGH", 0) - cur.get("YLOW", 0),
                sat=cur.get("SATAVG", 0), ydif=cur.get("YDIF", 0),
                cut=cur.get("lavfi.scd.score", 0)))

    for line in out.stdout.splitlines():
        if line.startswith("frame:"):
            flush()
            cur = {}
            m = re.search(r"pts_time:([\d.]+)", line)
            if m:
                cur["t"] = float(m.group(1))
        elif "=" in line:
            key, _, val = line.partition("=")
            key = key.replace("lavfi.signalstats.", "")
            try:
                cur[key] = float(val)
            except ValueError:
                pass
    flush()
    if not frames:
        sys.exit("Video analysis produced no frames:\n" + out.stderr[-2000:])
    return frames


def analyze_silence(path: str, s: Settings, duration: float) -> list[Range]:
    out = run(["ffmpeg", "-hide_banner", "-nostats", "-i", path, "-vn",
               "-af", f"silencedetect=n={s.silence_db}dB:d={s.silence_min_s}",
               "-f", "null", "-"])
    ranges, start = [], None
    for line in out.stderr.splitlines():
        if m := re.search(r"silence_start: ([\d.]+)", line):
            start = float(m.group(1))
        elif (m := re.search(r"silence_end: ([\d.]+)", line)) and start is not None:
            ranges.append(Range(start, float(m.group(1)), "silence"))
            start = None
    if start is not None:
        ranges.append(Range(start, duration, "silence"))
    return ranges


# ---------------------------------------------------------------- classification

def classify(f: Frame) -> str:
    flat = f.spread < 12
    if flat and f.yavg < 30:
        return "black"
    # Blue screen: flat, strongly blue (high U, low V) and saturated.
    if flat and f.uavg > 160 and f.vavg < 140 and f.sat > 40:
        return "blue_screen"
    # Snow: colourless, mid-grey on average, a wide spread of brightness, and almost
    # nothing in common with the previous frame (measured on the 160x120 proxy).
    if f.sat < 6 and 70 < f.yavg < 185 and f.spread > 50 and f.ydif > 28:
        return "static"
    return "content"


def runs(frames: list[Frame], frame_s: float):
    """Yield (kind, start, end) for consecutive frames of the same kind."""
    start = 0
    for i in range(1, len(frames) + 1):
        if i == len(frames) or frames[i].kind != frames[start].kind:
            yield frames[start].kind, frames[start].t, frames[i - 1].t + frame_s
            start = i


def overlap(a: Range, b: Range) -> float:
    return max(0.0, min(a.end, b.end) - max(a.start, b.start))


def segment(info: dict, frames: list[Frame], silence: list[Range], s: Settings):
    frame_s = 1.0 / ANALYSIS_FPS
    for f in frames:
        f.kind = classify(f)

    # Absorb junk blips shorter than the minimum back into content first.
    dead: list[Range] = []
    for kind, a, b in runs(frames, frame_s):
        if kind == "content":
            continue
        need = s.min_black_s if kind == "black" else s.min_dead_s
        if b - a >= need:
            dead.append(Range(round(a, 2), round(min(b, info["duration"]), 2), kind))

    # Merge touching dead ranges (blue screen straight into static, etc.).
    merged: list[Range] = []
    for r in dead:
        if merged and r.start - merged[-1].end <= frame_s * 1.5:
            last = merged[-1]
            reasons = set(last.reason.split("+")) | {r.reason}
            merged[-1] = Range(last.start, r.end, "+".join(sorted(reasons)))
        else:
            merged.append(r)

    # Live stretches between dead ranges.
    live, t = [], 0.0
    for r in merged:
        if r.start - t > 0:
            live.append(Range(round(t, 2), r.start))
        t = r.end
    if info["duration"] - t > 0:
        live.append(Range(round(t, 2), round(info["duration"], 2)))
    live = [r for r in live if r.end - r.start >= s.min_event_s]

    # Group live stretches into events: a long enough dead gap starts a new event.
    groups: list[list[Range]] = []
    for r in live:
        if groups:
            gap = r.start - groups[-1][-1].end
            if gap < s.event_gap_s:
                groups[-1].append(r)
                continue
        groups.append([r])

    cuts = [f.t for f in frames if f.cut >= s.cut_score]
    events = []
    for i, g in enumerate(groups, 1):
        ev = Event(index=i, start=g[0].start, end=g[-1].end)
        for r in g:
            bounds = [r.start] + [c for c in cuts if r.start + 0.5 < c < r.end - 0.5] + [r.end]
            ev.shots += [{"start": round(a, 2), "end": round(b, 2)}
                         for a, b in zip(bounds, bounds[1:])]
        span = Range(ev.start, ev.end)
        quiet = sum(overlap(span, q) for q in silence)
        ev.quiet = quiet > 0.6 * (ev.end - ev.start)
        events.append(ev)
    return merged, events


# ---------------------------------------------------------------- output

def export_clips(info: dict, events: list[Event], out_dir: str):
    os.makedirs(out_dir, exist_ok=True)
    for ev in events:
        name = os.path.join(out_dir, f"Event {ev.index:02d}.mp4")
        run(["ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
             "-ss", f"{ev.start:.2f}", "-to", f"{ev.end:.2f}", "-i", info["path"],
             "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
             "-c:a", "aac", "-b:a", "192k", name])
        print(f"  wrote {name}")


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("tape")
    p.add_argument("-o", "--output", help="write JSON here (default: print)")
    p.add_argument("--export-clips", metavar="DIR", help="also cut each event to an MP4")
    p.add_argument("--min-event", type=float, default=Settings.min_event_s)
    p.add_argument("--event-gap", type=float, default=Settings.event_gap_s)
    args = p.parse_args(argv)
    s = Settings(min_event_s=args.min_event, event_gap_s=args.event_gap)

    info = probe(args.tape)
    frames = analyze_video(args.tape)
    silence = analyze_silence(args.tape, s, info["duration"]) if info["has_audio"] else []
    dead, events = segment(info, frames, silence, s)

    counts: dict[str, int] = {}
    for f in frames:
        counts[f.kind] = counts.get(f.kind, 0) + 1
    result = {
        "tape": info,
        "dead_ranges": [asdict(r) | {"duration": r.duration} for r in dead],
        "events": [asdict(e) | {"duration": round(e.end - e.start, 2)} for e in events],
        "summary": {
            "events": len(events),
            "dead_seconds": round(sum(r.duration for r in dead), 1),
            "frame_kinds": counts,
        },
    }
    text = json.dumps(result, indent=2)
    if args.output:
        with open(args.output, "w") as fh:
            fh.write(text)
        print(f"Wrote {args.output}: {len(events)} events, "
              f"{result['summary']['dead_seconds']} s dead space")
    else:
        print(text)
    if args.export_clips:
        export_clips(info, events, args.export_clips)
    return result


if __name__ == "__main__":
    main()
