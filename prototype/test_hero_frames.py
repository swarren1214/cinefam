#!/usr/bin/env python3
"""python3 test_hero_frames.py — the picker should prefer sharp, well-exposed frames.

Fake event (4 s each): sharp | blurry | too dark | blown out | motion smear.
Expect every pick from the sharp stretch first, and the blurry/dark/blown stretches last.
"""
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hero_frames as hf  # noqa: E402

SRC = "testsrc2=s=640x480:r=30,format=yuv420p"
PARTS = [
    ("sharp", ""),
    ("blurry", ",gblur=sigma=5"),
    ("dark", ",eq=brightness=-0.42:contrast=0.6"),
    ("blown", ",eq=brightness=0.45:contrast=0.7"),
    ("smear", ",tmix=frames=12,gblur=sigma=1.5:sigmaV=0"),
]


def main():
    with tempfile.TemporaryDirectory() as tmp:
        parts = []
        for name, vf in PARTS:
            p = os.path.join(tmp, f"{name}.mp4")
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", SRC + vf, "-t", "4",
                            "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", p], check=True)
            parts.append(p)
        listing = os.path.join(tmp, "l.txt")
        with open(listing, "w") as fh:
            fh.writelines(f"file '{p}'\n" for p in parts)
        video = os.path.join(tmp, "event.mp4")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", listing,
                        "-c", "copy", video], check=True)

        cuts = [4 * i for i in range(1, len(PARTS))]
        picks, cands = hf.hero_frames(video, 0, 20, count=3, samples=40, cuts=cuts,
                                      out_dir=os.path.join(tmp, "f"), min_gap=0.5)

    def part(t):
        return PARTS[min(int(t // 4), len(PARTS) - 1)][0]

    print("picks:", [(c.time, part(c.time), round(c.score, 2)) for c in picks])
    means = {}
    for c in cands:
        means.setdefault(part(c.time), []).append(c.score)
    means = {k: round(sum(v) / len(v), 2) for k, v in means.items()}
    print("mean score by stretch:", means)

    fails = []
    if any(part(c.time) != "sharp" for c in picks):
        fails.append("a pick came from outside the sharp stretch")
    if max(means, key=means.get) != "sharp":
        fails.append("sharp stretch didn't score best")
    for bad in ("blurry", "dark", "blown", "smear"):
        if means[bad] >= means["sharp"] - 0.1:
            fails.append(f"{bad} scored too close to sharp")
    if fails:
        print("\nFAIL\n  " + "\n  ".join(fails))
        sys.exit(1)
    print("\nPASS: hero frames favour sharp, well-exposed footage")


if __name__ == "__main__":
    main()
