#!/usr/bin/env python3
"""CineFam Phase 5 prototype: pick the best "hero" frames of an event for its poster.

    python3 hero_frames.py VIDEO --start 10 --end 70 [--count 6] [--samples 40] [--out frames/]

Scores each sampled frame on what can be measured from pixels alone:
  sharpness  variance of the Laplacian (blurry and motion-smeared frames score low)
  exposure   mid-grey average, little crushed black or blown white
  contrast   spread of brightness
  color      Hasler–Süsstrunk colorfulness
Each measure is scaled against the best frame in the set, so the ranking adapts to the
footage (a dim VHS tape still has a "best" frame). The Swift `HeroFramePicker` uses the
same measures and weights, and adds Apple Vision's face quality and aesthetics scores.
Picks are spread out in time (at least `min_gap` seconds apart) so the choices differ.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass

import numpy as np
from PIL import Image

WEIGHTS = {"sharpness": 0.40, "exposure": 0.25, "contrast": 0.20, "color": 0.15}
ANALYSIS_WIDTH = 256


@dataclass
class Candidate:
    time: float
    path: str
    sharpness: float = 0
    exposure: float = 0
    contrast: float = 0
    color: float = 0
    score: float = 0


def sample_times(start, end, samples, cuts=(), edge=0.4):
    """Evenly spaced, skipping frames right next to a cut (often mid-transition)."""
    step = (end - start) / (samples + 1)
    times = [start + step * (i + 1) for i in range(samples)]
    return [t for t in times if all(abs(t - c) > edge for c in cuts)]


def extract(video, t, path):
    subprocess.run(["ffmpeg", "-hide_banner", "-y", "-loglevel", "error", "-ss", f"{t:.3f}", "-i", video,
                    "-frames:v", "1", "-vf", "scale=trunc(iw*sar/2)*2:ih,setsar=1", "-q:v", "2", path],
                   check=True)


def measure(c: Candidate):
    img = Image.open(c.path).convert("RGB")
    img = img.resize((ANALYSIS_WIDTH, max(1, round(img.height * ANALYSIS_WIDTH / img.width))))
    rgb = np.asarray(img, dtype=np.float32) / 255
    y = rgb @ np.array([0.299, 0.587, 0.114], dtype=np.float32)

    lap = (-4 * y[1:-1, 1:-1] + y[:-2, 1:-1] + y[2:, 1:-1] + y[1:-1, :-2] + y[1:-1, 2:])
    c.sharpness = float(lap.var())

    mean = float(y.mean())
    clipped = float(((y < 0.03) | (y > 0.97)).mean())
    c.exposure = max(0.0, 1 - abs(mean - 0.45) * 2.2 - clipped * 1.5)

    c.contrast = float(y.std())

    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    rg, yb = r - g, 0.5 * (r + g) - b
    c.color = float(np.sqrt(rg.std() ** 2 + yb.std() ** 2) + 0.3 * np.sqrt(rg.mean() ** 2 + yb.mean() ** 2))


def rank(cands: list[Candidate]) -> list[Candidate]:
    best = {k: max((getattr(c, k) for c in cands), default=0) or 1 for k in WEIGHTS}
    for c in cands:
        c.score = sum(w * getattr(c, k) / best[k] for k, w in WEIGHTS.items())
    return sorted(cands, key=lambda c: c.score, reverse=True)


def pick(ranked: list[Candidate], count: int, min_gap: float) -> list[Candidate]:
    chosen: list[Candidate] = []
    for c in ranked:
        if all(abs(c.time - p.time) >= min_gap for p in chosen):
            chosen.append(c)
        if len(chosen) == count:
            break
    return chosen


def hero_frames(video, start, end, count=6, samples=40, cuts=(), out_dir=None, min_gap=2.0):
    out_dir = out_dir or tempfile.mkdtemp(prefix="hero-")
    os.makedirs(out_dir, exist_ok=True)
    cands = []
    for i, t in enumerate(sample_times(start, end, samples, cuts)):
        path = os.path.join(out_dir, f"frame_{i:03d}.jpg")
        extract(video, t, path)
        c = Candidate(time=round(t, 2), path=path)
        measure(c)
        cands.append(c)
    return pick(rank(cands), count, min_gap), cands


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("video")
    ap.add_argument("--start", type=float, default=0)
    ap.add_argument("--end", type=float, required=True)
    ap.add_argument("--count", type=int, default=6)
    ap.add_argument("--samples", type=int, default=40)
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    picks, _ = hero_frames(a.video, a.start, a.end, a.count, a.samples, out_dir=a.out)
    for c in picks:
        print(f"{c.time:8.2f}s  score {c.score:.2f}  sharp {c.sharpness:.4f}  exp {c.exposure:.2f}  "
              f"contrast {c.contrast:.2f}  color {c.color:.2f}  {c.path}")
    return picks


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
