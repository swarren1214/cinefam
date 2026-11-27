#!/usr/bin/env python3
"""python3 test_datestamp.py — checks the date-stamp parser on stamps camcorders really print."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from datestamp import Stamp, parse, vote  # noqa: E402

Y = 2026
CASES = [
    ("JUL 4 1996  PM 9:41", Stamp(1996, 7, 4, 21, 41)),
    ("DEC.25 1994", Stamp(1994, 12, 25)),
    ("AM 10:05\nDEC 25 1994", Stamp(1994, 12, 25, 10, 5)),
    ("25 DEC 1994", Stamp(1994, 12, 25)),
    ("SEPT 3 1999 8:15 PM", Stamp(1999, 9, 3, 20, 15)),
    ("12.25.94", Stamp(1994, 12, 25)),
    ("7/4/1996 21:41", Stamp(1996, 7, 4, 21, 41)),
    ("1998.05.11  14:02:33", Stamp(1998, 5, 11, 14, 2)),
    ("1998 MAY 11", Stamp(1998, 5, 11)),
    ("25.12.94", Stamp(1994, 12, 25)),                      # day-first camera
    ("JUL 4 l996", Stamp(1996, 7, 4)),                      # OCR read 1 as l
    ("JUL 4 1996 PM 9:4I", Stamp(1996, 7, 4, 21, 41)),      # I read for 1
    ("JUL 4 1996 PM 9:", Stamp(1996, 7, 4)),                # time cut off, date kept
    ("JUL4 1996", Stamp(1996, 7, 4)),                       # no space after month
    ("OCT 3O 2OO2", Stamp(2002, 10, 30)),                   # O for 0
    ("jan 14 2003 am 7:30", Stamp(2003, 1, 14, 7, 30)),
    ("JAN 1 1980 AM 12:00", None),                          # clock never set
    ("JAN 1 2000", None),
    ("FEB 30 1995", None),                                  # not a real day
    ("REC  SP  0:12:44", None),                             # tape counter, no date
    ("HAPPY BIRTHDAY", None),
    ("MAR 3 2031", None),                                   # future
]


def main():
    fails = 0
    for text, want in CASES:
        got = parse(text, this_year=Y)
        ok = got == want
        fails += not ok
        print(f"{'ok ' if ok else 'BAD'}  {text!r:32} -> {got}")

    readings = [parse(t, Y) for t in
                ["JUL 4 1996 PM 9:41", "JUL 4 1996 PM 9:43", "JUL 4 1996", "","JUN 4 1996", "garbage"]]
    best, conf = vote(readings)
    ok = best == Stamp(1996, 7, 4, 21, 41) and conf == 0.5
    fails += not ok
    print(f"{'ok ' if ok else 'BAD'}  vote -> {best} confidence {conf}")

    if fails:
        print(f"\nFAIL: {fails} case(s)")
        sys.exit(1)
    print("\nPASS: all date-stamp cases")


if __name__ == "__main__":
    main()
