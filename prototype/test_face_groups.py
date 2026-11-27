#!/usr/bin/env python3
"""python3 test_face_groups.py — grouping should find each person and respect names."""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from face_groups import Face, group_faces  # noqa: E402

rng = np.random.default_rng(7)
DIM, PEOPLE, PER = 64, 6, 25


def make():
    centers = rng.normal(size=(PEOPLE, DIM))
    centers /= np.linalg.norm(centers, axis=1, keepdims=True)
    faces, truth = [], {}
    for p in range(PEOPLE):
        for i in range(PER):
            v = centers[p] + rng.normal(scale=0.06, size=DIM)   # same person, different frames
            f = Face(f"p{p}-{i}", v, quality=float(rng.uniform(0.2, 1)))
            faces.append(f)
            truth[f.id] = p
    for i in range(8):                                          # strangers seen once
        v = rng.normal(size=DIM)
        v /= np.linalg.norm(v)
        f = Face(f"x{i}", v, quality=0.5)
        faces.append(f)
        truth[f.id] = -1
    return faces, truth


def main():
    faces, truth = make()
    # The user named person 0 ("Mom") from two faces.
    for f in faces:
        if f.id in ("p0-0", "p0-1"):
            f.person = "Mom"

    people, groups, unsorted = group_faces(faces, threshold=0.75)
    fails = []

    mom = people["Mom"]
    if len(mom) != PER or any(truth[f.id] != 0 for f in mom):
        fails.append(f"Mom should have exactly her {PER} faces, got {len(mom)}")

    purity = [max(np.bincount([truth[f.id] + 1 for f in g.faces], minlength=PEOPLE + 1)) / len(g.faces)
              for g in groups]
    print("named:", {k: len(v) for k, v in people.items()})
    print("groups:", [len(g.faces) for g in groups], "purity min", round(min(purity), 2))
    print("unsorted:", len(unsorted))
    if len(groups) != PEOPLE - 1:
        fails.append(f"expected {PEOPLE - 1} unnamed groups, got {len(groups)}")
    if min(purity) < 0.99:
        fails.append("a group mixes people")
    if sum(1 for f in unsorted if truth[f.id] == -1) != 8:
        fails.append("strangers should stay unsorted")

    if fails:
        print("\nFAIL\n  " + "\n  ".join(fails))
        sys.exit(1)
    print("\nPASS: faces grouped into people, names respected")


if __name__ == "__main__":
    main()
