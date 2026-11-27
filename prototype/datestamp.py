#!/usr/bin/env python3
"""Reads camcorder date stamps from OCR text (Phase 3 prototype).

The Swift `DateStampParser` is a port of this file: same patterns, same rules.

    parse("JUL 4 1996  PM 9:41")  -> Stamp(1996, 7, 4, 21, 41)
    vote([...readings from several frames...]) -> (Stamp, confidence)
"""
from __future__ import annotations

import re
from collections import Counter
from dataclasses import dataclass
from datetime import date

MONTHS = {"JAN": 1, "FEB": 2, "MAR": 3, "APR": 4, "MAY": 5, "JUN": 6, "JUL": 7,
          "AUG": 8, "SEP": 9, "SEPT": 9, "OCT": 10, "NOV": 11, "DEC": 12}
MON = r"(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEPT|SEP|OCT|NOV|DEC)[A-Z]*\.?"
SEP = r"[\s.,/\-]*"
SEP1 = r"[\s.,/\-]+"

# Order matters: the most specific patterns first.
DATE_PATTERNS = [
    ("mdy_name", re.compile(rf"\b{MON}{SEP}(\d{{1,2}}){SEP1}(\d{{4}}|\d{{2}})\b")),   # DEC 25 1994
    ("dmy_name", re.compile(rf"\b(\d{{1,2}}){SEP}{MON}{SEP}(\d{{4}}|\d{{2}})\b")),    # 25 DEC 1994
    ("ymd_name", re.compile(rf"\b(\d{{4}}){SEP1}{MON}{SEP}(\d{{1,2}})\b")),           # 1994 DEC 25
    ("ymd_num", re.compile(r"\b(\d{4})[.\-/ ](\d{1,2})[.\-/ ](\d{1,2})\b")),        # 1994.12.25
    ("mdy_num", re.compile(r"\b(\d{1,2})[.\-/ ](\d{1,2})[.\-/ ](\d{4}|\d{2})\b")),  # 12.25.94
]
TIME_PATTERNS = [
    re.compile(r"\b(AM|PM)\s*(\d{1,2})[:.](\d{2})(?:[:.]\d{2})?\b"),          # PM 9:41
    re.compile(r"\b(\d{1,2})[:.](\d{2})(?:[:.]\d{2})?\s*(AM|PM)\b"),          # 9:41 PM
    re.compile(r"\b([01]?\d|2[0-3]):([0-5]\d)(?::[0-5]\d)?\b"),               # 21:41
]

UNSET_CLOCKS = {(1980, 1, 1), (1990, 1, 1), (2000, 1, 1), (2001, 1, 1)}
EARLIEST_YEAR = 1975


@dataclass(frozen=True)
class Stamp:
    year: int
    month: int
    day: int
    hour: int | None = None
    minute: int | None = None

    @property
    def day_key(self):
        return (self.year, self.month, self.day)


def normalize(text: str) -> str:
    """Upper-case and fix common OCR slips next to digits (O→0, I/l/|→1)."""
    # l, I and | touching a digit (but not inside a word like "JUL4") are a 1.
    t = re.sub(r"(?<=\d)[lI|]|(?<![A-Za-z])[lI|](?=\d)", "1", text)
    t = t.upper()
    while True:   # repeat so runs like "2OO2" resolve
        fixed = re.sub(r"(?<=\d)O|(?<![A-Z])O(?=\d)", "0", t)
        if fixed == t:
            break
        t = fixed
    return t.replace("’", "'")


def full_year(y: int) -> int:
    if y >= 100:
        return y
    return 1900 + y if y >= 70 else 2000 + y


def valid(y: int, m: int, d: int, this_year: int) -> bool:
    if not (EARLIEST_YEAR <= y <= this_year and 1 <= m <= 12):
        return False
    try:
        date(y, m, d)
    except ValueError:
        return False
    return (y, m, d) not in UNSET_CLOCKS


def parse_date(t: str, this_year: int):
    for kind, rx in DATE_PATTERNS:
        for m in rx.finditer(t):
            g = m.groups()
            if kind == "mdy_name":
                y, mo, d = full_year(int(g[2])), MONTHS[g[0][:4] if g[0].startswith("SEPT") else g[0][:3]], int(g[1])
            elif kind == "dmy_name":
                y, mo, d = full_year(int(g[2])), MONTHS[g[1][:3]], int(g[0])
            elif kind == "ymd_name":
                y, mo, d = int(g[0]), MONTHS[g[1][:3]], int(g[2])
            elif kind == "ymd_num":
                y, mo, d = int(g[0]), int(g[1]), int(g[2])
            else:  # US camcorders: month first
                y, mo, d = full_year(int(g[2])), int(g[0]), int(g[1])
                if mo > 12 and d <= 12:           # day-first stamp
                    mo, d = d, mo
            if valid(y, mo, d, this_year):
                return (y, mo, d), m.span()
    return None, None


def parse_time(t: str):
    for i, rx in enumerate(TIME_PATTERNS):
        m = rx.search(t)
        if not m:
            continue
        if i == 0:
            ampm, h, mi = m.group(1), int(m.group(2)), int(m.group(3))
        elif i == 1:
            h, mi, ampm = int(m.group(1)), int(m.group(2)), m.group(3)
        else:
            return int(m.group(1)), int(m.group(2))
        if not (1 <= h <= 12 and mi < 60):
            continue
        h = h % 12 + (12 if ampm == "PM" else 0)
        return h, mi
    return None


def parse(text: str, this_year: int | None = None) -> Stamp | None:
    this_year = this_year or date.today().year
    t = normalize(text)
    day, span = parse_date(t, this_year)
    if day is None:
        return None
    # Don't read the date's own digits as a time ("12.25" in "12.25.94").
    rest = t[:span[0]] + " " + t[span[1]:]
    hm = parse_time(rest)
    return Stamp(*day, *(hm or (None, None)))


def vote(readings: list[Stamp | None], frames: int | None = None):
    """Most common day across frames, with the earliest time seen on that day."""
    found = [r for r in readings if r]
    if not found:
        return None, 0.0
    day, votes = Counter(r.day_key for r in found).most_common(1)[0]
    times = sorted((r.hour, r.minute) for r in found if r.day_key == day and r.hour is not None)
    h, mi = times[0] if times else (None, None)
    total = frames or len(readings)
    return Stamp(*day, h, mi), round(votes / max(total, 1), 2)
