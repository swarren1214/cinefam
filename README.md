# CineFam

Turn old home-video tapes into a movie library. CineFam takes a digitized tape, cuts out
the dead space (blue screens, static, black, silence), splits what's left into events, and
saves each event as a finished movie file — subtitles, chapters, poster and all. Everything
runs on this Mac with free, open-source tools. Nothing is uploaded.

Plan: *Home Video Restoration App — Implementation Plan* (Claude doc).
Design: *Home Video Restoration App — Mac Design* (Claude Design canvas).

## Run it

1. Install FFmpeg (free): `brew install ffmpeg`
2. Open `CineFam.xcodeproj` in Xcode 26 and run (macOS 26, Apple silicon).
3. Drag a digitized tape (MOV, AVI, DV, MP4…) into the window, or **File › Import Tapes…** (⇧⌘I).
4. CineFam makes a 360p preview copy and analyzes it: dead space, events, then for each
   event it reads the camcorder date stamp, transcribes speech for subtitles (asks for Speech
   Recognition permission) and suggests a title and summary with Apple Intelligence.
5. When the tape says **Needs review**, pick events on the timeline, fix titles and dates,
   split or merge them. **Suggest Title & Date** re-runs the AI for one event.
6. **Approve & Export…** → pick formats → Export. Files go to `~/Movies/Home Videos` by default.

The library lives in `~/Library/Application Support/CineFam/` (`library.json` + `Proxies/`).

## Status

| Phase | What | State |
| --- | --- | --- |
| 1 | Prove segmentation | ✅ `prototype/` — passes its test tape |
| 2 | App shell: import, queue, review timeline | ✅ first pass (needs a build in Xcode) |
| 3 | Dating and naming | ✅ first pass — date-stamp OCR, scene tags, faces, transcripts, AI titles (needs a build in Xcode) |
| 4 | Restore and export | 🟡 export in 7 formats with subtitles, chapters, metadata done; Real-ESRGAN upscale to do (uses lanczos scaling for now) |
| 5 | Poster art | ⬜ |
| 6 | Illustrated posters | ⬜ |
| 7 | Library mode | ⬜ |

## Layout

```
CineFam/
  App/       CineFamApp (scenes, menus) · AppModel (library, analysis queue, edits, export)
  Models/    Tape, TapeEvent, DeadRange, Shot, TimedWord, Chapter…
  Engine/    FFmpeg (find + run tools) · Analyzer (probe, proxy, dead space, events)
             Subtitles (cue rules, SRT, chapter file) · ExportFormat (7 formats, naming)
             Exporter (ffmpeg command per event/format) · Transcriber (on-device speech)
             DateStampParser (camcorder stamps) · FrameInsights (keyframes + Vision OCR,
             scene tags, faces) · EventNamer (Foundation Models + fallback) ·
             EventEnricher (Phase 3 pipeline, date fill-in)
  Views/     ContentView · SidebarView · LibraryView · TapeReviewView (+ TapeTimeline)
             EventInspector · ExportSheet (+ SettingsView)
prototype/   Python prototypes + tests: segmentation (Phase 1), date stamps (Phase 3)
```

The Xcode project uses a synchronized folder: any file added under `CineFam/` is built
automatically.

## Export formats

| Format | Video | Subtitles | Chapters | Cover art |
| --- | --- | --- | --- | --- |
| M4V | HEVC 10-bit (VideoToolbox) | embedded (mov_text) | ✓ | ✓ |
| MP4 | HEVC 10-bit (VideoToolbox) | embedded (mov_text) | ✓ | ✓ |
| MOV | ProRes 422 HQ | embedded (mov_text) | ✓ | poster.jpg beside it |
| MKV | HEVC 10-bit | embedded (SRT) | ✓ | poster.jpg beside it |
| Windows MP4 | H.264 High | embedded (mov_text) | ✓ | ✓ |
| WMV | WMV2 | .srt file or burn-in | — | — |
| AVI | MPEG-4 (Xvid tag) | .srt file or burn-in | — | — |

The exact FFmpeg argument patterns were tested on a sample clip for every container
(subtitle streams, chapter names, cover art, metadata), except the Apple-only VideoToolbox HEVC encoder.

## How dates are found

1. **Date stamp** burned into the picture: 8 keyframes per event, Vision text recognition,
   then `DateStampParser` reads stamps like `JUL 4 1996 PM 9:41`, `12.25.94`, `25 DEC 1994`
   and fixes OCR slips (O→0, l→1). The day most frames agree on wins. Clocks that were never
   set (Jan 1 1980/1990/2000) and impossible dates are ignored.
2. **Nearby events**: an undated event between two events from the same day gets that day;
   otherwise it gets the year of the nearest dated event.
3. **Tape label**: "Summer 1996" or "Christmas '94" gives a year.
4. **You**: anything typed in the inspector is never overwritten.

Each date remembers how precise it is (date and time, day, or year only), and file names,
movie info and the library show only what's known.

Titles come from Apple's on-device Foundation Models (Apple Intelligence must be on) using
the scene labels, face count, transcript, date and tape label. Without it, a simple
keyword match names events ("Birthday – Jul 4, 1996"). Both can be turned off in Settings.

## Prototype

```
cd prototype
python3 test_segment.py                    # builds a fake tape and checks the results
python3 test_datestamp.py                  # 23 camcorder date-stamp cases
python3 cinefam_segment.py TAPE.mov -o result.json --export-clips clips/
```

The Swift `Analyzer` is a port of `cinefam_segment.py`. Tune thresholds in the prototype
against real tapes first, then copy them across.

## Next up

- Build in Xcode and fix anything the compiler flags (this first pass was written without
  a Mac to compile on).
- Run the prototype on 3 real tapes (VHS, MiniDV, mixed) and tune `classify()` thresholds.
- `dvrescue` for exact MiniDV recording dates.
- Faces → people names (label once, apply across the library).
- Real-ESRGAN upscaling (Phase 4), then Poster Studio (Phase 5).
