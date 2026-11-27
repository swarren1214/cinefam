#!/usr/bin/env python3
"""Builds a fake VHS tape with ffmpeg and checks the segmenter finds what it should.

    python3 test_segment.py

Tape layout (seconds):
   0–4   blue screen, silent            -> dead
   4–12  test pattern + tone            -> event 1, shot 1
  12–18  different pattern + tone       -> event 1, shot 2 (hard cut)
  18–23  snow / static + hiss           -> dead
  23–26  black, silent                  -> dead
  26–33  moving pattern + tone          -> event 2
  33–38  blue screen, silent            -> dead
"""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cinefam_segment as seg  # noqa: E402

SIZE, RATE = "320x240", 30

SEGMENTS = [
    (4, f"color=c=0x0000ff:s={SIZE}:r={RATE}", "anullsrc=r=48000:cl=stereo"),
    (8, f"testsrc2=s={SIZE}:r={RATE}", "sine=f=440:r=48000"),
    (6, f"mandelbrot=s={SIZE}:r={RATE}", "sine=f=660:r=48000"),
    (5, f"nullsrc=s={SIZE}:r={RATE},geq=lum='random(1)*255':cb=128:cr=128",
     "anoisesrc=r=48000:a=0.3"),
    (3, f"color=c=black:s={SIZE}:r={RATE}", "anullsrc=r=48000:cl=stereo"),
    (7, f"life=s={SIZE}:r={RATE}:mold=10:ratio=0.5:death_color=#203040:life_color=#e0a060",
     "sine=f=330:r=48000"),
    (5, f"color=c=0x0000ff:s={SIZE}:r={RATE}", "anullsrc=r=48000:cl=stereo"),
]


def build_tape(path: str):
    tmp = os.path.dirname(path)
    parts = []
    for i, (dur, video, audio) in enumerate(SEGMENTS):
        part = os.path.join(tmp, f"part{i}.mp4")
        subprocess.run([
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "lavfi", "-i", video, "-f", "lavfi", "-i", audio,
            "-t", str(dur), "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-ac", "2", "-ar", "48000", part], check=True)
        parts.append(part)
    listing = os.path.join(tmp, "list.txt")
    with open(listing, "w") as fh:
        fh.writelines(f"file '{p}'\n" for p in parts)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0",
                    "-i", listing, "-c", "copy", path], check=True)


def near(a, b, tol=0.6):
    return abs(a - b) <= tol


def main():
    with tempfile.TemporaryDirectory() as tmp:
        tape = os.path.join(tmp, "fake_tape.mp4")
        build_tape(tape)
        result = seg.main([tape, "-o", os.path.join(tmp, "out.json")])

    dead = result["dead_ranges"]
    events = result["events"]
    print("dead :", [(r["start"], r["end"], r["reason"]) for r in dead])
    print("events:", [(e["start"], e["end"], len(e["shots"])) for e in events])

    failures = []
    expect_dead = [(0, 4, "blue_screen"), (18, 26, None), (33, 38, "blue_screen")]
    if len(dead) != len(expect_dead):
        failures.append(f"expected {len(expect_dead)} dead ranges, got {len(dead)}")
    else:
        for r, (a, b, reason) in zip(dead, expect_dead):
            if not (near(r["start"], a) and near(r["end"], b)):
                failures.append(f"dead range {r} should be about {a}–{b}")
            if reason and r["reason"] != reason:
                failures.append(f"dead range {r} should be {reason}")
        if not {"static", "black"} <= set(dead[1]["reason"].split("+")):
            failures.append(f"middle dead range should be static+black, got {dead[1]['reason']}")

    if len(events) != 2:
        failures.append(f"expected 2 events, got {len(events)}")
    else:
        e1, e2 = events
        if not (near(e1["start"], 4) and near(e1["end"], 18)):
            failures.append(f"event 1 should be 4–18, got {e1['start']}–{e1['end']}")
        if len(e1["shots"]) != 2:
            failures.append(f"event 1 should have 2 shots, got {len(e1['shots'])}")
        if not (near(e2["start"], 26) and near(e2["end"], 33)):
            failures.append(f"event 2 should be 26–33, got {e2['start']}–{e2['end']}")

    if failures:
        print("\nFAIL\n  " + "\n  ".join(failures))
        sys.exit(1)
    print("\nPASS: dead space and events found as expected")


if __name__ == "__main__":
    main()
