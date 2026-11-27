#!/usr/bin/env python3
"""CineFam Phase 7 prototype: group faces from across the library into people.

The Swift `FaceClusterer` is a port of this file. Faces arrive as feature vectors (Apple
Vision feature prints of face crops in the app). Three steps:

1. Faces close to a person the user already named join that person
   (distance = mean of the 3 nearest of that person's faces).
2. The rest are grouped greedily, best-quality faces first: each joins the nearest
   unnamed group (nearest of up to 32 of its faces) if it's within `threshold`,
   otherwise it starts a new group.
3. Groups whose 3 closest cross pairs average under `threshold` are merged. Groups with fewer than `min_size` faces are left
   as "unsorted" rather than shown as people.

Named people are never broken up; unnamed groups are rebuilt each time, so new tapes
and threshold changes regroup cleanly.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np


@dataclass
class Face:
    id: str
    vec: np.ndarray
    quality: float = 0.5
    person: str | None = None     # name, when the user has labeled it (or it joined a person)


@dataclass
class Group:
    faces: list[Face] = field(default_factory=list)


def dist(a: Face, b: Face) -> float:
    return float(np.linalg.norm(a.vec - b.vec))


def distance_to(face: Face, members: list[Face], k: int) -> float:
    ds = sorted(dist(face, m) for m in members)
    return sum(ds[:k]) / min(k, len(ds))


def group_faces(faces: list[Face], threshold: float, join_threshold: float | None = None,
                min_size: int = 2):
    join_threshold = join_threshold or threshold
    people: dict[str, list[Face]] = {}
    for f in faces:
        if f.person:
            people.setdefault(f.person, []).append(f)

    # 1. Join named people.
    loose = []
    for f in faces:
        if f.person:
            continue
        best, best_d = None, float("inf")
        for name, members in people.items():
            d = distance_to(f, members, 3)
            if d < best_d:
                best, best_d = name, d
        if best is not None and best_d < join_threshold:
            f.person = best
            people[best].append(f)
        else:
            loose.append(f)

    # 2. Greedy grouping of the rest, best faces first.
    groups: list[Group] = []
    for f in sorted(loose, key=lambda f: f.quality, reverse=True):
        best, best_d = None, float("inf")
        for g in groups:
            d = min(dist(f, m) for m in g.faces[:32])
            if d < best_d:
                best, best_d = g, d
        if best is not None and best_d < threshold:
            best.faces.append(f)
        else:
            groups.append(Group([f]))

    # 3. Merge groups that turned out to be one person (a stray early face can seed a
    #    second group): merge while the 3 closest cross-group pairs average under threshold.
    merged = True
    while merged:
        merged = False
        for i in range(len(groups)):
            for j in range(i + 1, len(groups)):
                ds = sorted(dist(a, b) for a in groups[i].faces[:32] for b in groups[j].faces[:32])
                if sum(ds[:3]) / min(3, len(ds)) < threshold:
                    groups[i].faces += groups.pop(j).faces
                    merged = True
                    break
            if merged:
                break

    unnamed = sorted((g for g in groups if len(g.faces) >= min_size), key=lambda g: -len(g.faces))
    unsorted = [f for g in groups if len(g.faces) < min_size for f in g.faces]
    return people, unnamed, unsorted
