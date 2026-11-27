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
3. Drag digitized tapes (MOV, AVI, DV, MP4…) or a whole folder of them into the window, or
   **File › Import Tapes or Folder…** (⇧⌘I). Folders are searched inside, sorted by name.
4. CineFam makes a 360p preview copy and analyzes it: dead space, events, then for each
   event it reads the camcorder date stamp, transcribes speech for subtitles (asks for Speech
   Recognition permission) and suggests a title and summary with Apple Intelligence.
5. When the tape says **Needs review**, pick events on the timeline, fix titles and dates,
   split or merge them. **Suggest Title & Date** re-runs the AI for one event.
6. **Preview Restoration** (wand button) restores 10 seconds from the playhead and plays it
   side by side with the original, so you can tune the settings first.
7. **Poster Studio** (sidebar) designs a movie poster for each event: pick one of the best
   stills, a color grade and a layout, edit the words, **Save Poster**. **Generate Missing**
   makes one for every event with the defaults.
8. **Approve & Export…** → pick formats and restoration settings → Export. The first time,
   download Real-ESRGAN from the Restoration section (52 MB, checked against a known SHA-256).
   Files go to `~/Movies/Home Videos` by default.

The library lives in `~/Library/Application Support/CineFam/` (`library.json` + `Proxies/`).

## Status

| Phase | What | State |
| --- | --- | --- |
| 1 | Prove segmentation | ✅ `prototype/` — passes its test tape |
| 2 | App shell: import, queue, review timeline | ✅ first pass (needs a build in Xcode) |
| 3 | Dating and naming | ✅ first pass — date-stamp OCR, scene tags, faces, transcripts, AI titles (needs a build in Xcode) |
| 4 | Restore and export | ✅ first pass — Real-ESRGAN upscaling, cleanup, previews, export in 7 formats (needs a build in Xcode) |
| 5 | Poster art | ✅ first pass — hero frames, color grades, 4 templates, poster + backdrop (needs a build in Xcode) |
| 6 | Illustrated posters | ✅ first pass — 4 drawn styles + Image Playground (needs a build in Xcode) |
| 7 | Library mode | ✅ first pass — folder import, unattended processing, people, search (needs a build in Xcode) |

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
             EventEnricher (Phase 3 pipeline, date fill-in) · Restorer (Phase 4 restore +
             upscale, Real-ESRGAN install, previews) · HeroFramePicker (best stills) ·
             PosterArt (spec, grades, templates, rendering, taglines) · PosterStyles
             (drawn styles, Image Playground) · FaceIndex (faces, prints, grouping) · Notifier
  Views/     ContentView · SidebarView · LibraryView · TapeReviewView (+ TapeTimeline)
             EventInspector · ExportSheet (+ SettingsView) · RestorationViews · PosterStudioView
             QueueView · PeopleView
prototype/   Python prototypes + tests: segmentation (1), date stamps (3), restoration (4),
             hero frames (5), face grouping (7)
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

## Library mode

- **Processing** (sidebar) lists every tape with its stage and progress. Tapes are worked on
  one at a time; *Do This One Next* reorders, *Pause After This Tape* and *Stop Now* (the
  tape goes back in line) control the run. Your Mac is kept awake while it works.
- **Unattended**: switch on *Export without waiting for review* and each tape is analyzed,
  scanned for people, given posters and exported with the Export settings — a shoebox
  overnight. A notification says when it's done. Off, tapes wait for review.
- **People**: faces are found in 8 frames per event (Vision; at least 48 px and decent capture
  quality), cropped and described with Vision feature prints, then grouped across the library
  (port of `prototype/face_groups.py`: named people absorb close faces, the rest grouped
  greedily, then near groups merged). Name a group once and that name is added to every movie
  it's in; rename and it changes everywhere; *Not <name>…* removes a wrong face. The
  *Grouping* slider trades more groups for fewer mistakes. Feature prints are general image
  descriptors, not a face-recognition model, so expect to correct some groups — especially
  across very different lighting or ages.
- **Search** covers titles, summaries, keywords, people, tape labels and everything said;
  results show where the words were spoken. Filter the library by person.

## Restoration

Each kept event is restored once into a **restored master** (HEVC 10-bit `.mov` in
`~/Library/Application Support/CineFam/Restored/`). Every export format is then made from it,
so exporting more formats later doesn't redo the slow part.

1. **Prepass** (one continuous FFmpeg run so temporal filters never restart): deinterlace
   (`bwdif`; 60 fps with *Smooth motion*), square pixels, trim tape-edge noise, denoise
   (`hqdn3d`), optional stabilizing (`deshake`), auto color (`normalize`), and audio cleanup
   (hum filter, `afftdn` noise reduction, `loudnorm`). Saved losslessly (FFV1 + FLAC).
2. **Upscale in chunks of 240 frames**: PNGs → Real-ESRGAN → blended with a plain lanczos
   scale by *AI strength* (default 60%, which keeps faces natural) → encoded. Finished chunks
   are reused, so a stopped render picks up where it left off.
3. **Join** the chunks and add the cleaned audio.

Models: *Fast* is `realesr-animevideov3` (2×/3×/4×), *Detailed* is `realesrgan-x4plus` (4×,
much slower). With *Standard* upscaling (or before Real-ESRGAN is installed) it's lanczos +
`cas` sharpening. Settings › Restoration shows and clears the disk space restored copies use.

## Posters

1. **Hero frames**: 40 stills across the event (from the restored master if there is one),
   skipping moments next to cuts. Each is scored on sharpness (variance of the Laplacian),
   exposure, contrast and colorfulness — scaled against the event's best frame — plus Apple
   Vision's face-capture quality and aesthetics score; "utility" shots are marked down. The
   top 6, at least 2 s apart, are offered. Vision also finds the subject (biggest face, else
   the salient area) so crops keep it in frame.
2. **Look**: Core Image grades — Natural, Warm ’80s, Faded Film, Teal & Orange, Black & White.
   **Style** (Phase 6):
   - *Drawn on this Mac* — Comic, Screen Print (flat inks + halftone), Pencil Sketch (lines
     on paper with a color wash) and Retro Print (two-color duotone). Core Image, instant, no
     downloads, every face kept as filmed; *Strength* mixes the drawing with the photo.
   - *Image Playground* — Animated, Illustration and Sketch, generated on this Mac by Apple's
     Image Playground from the still plus a description of the scene (never names). Needs
     Apple Intelligence. Faces become a likeness. Results are kept with the poster.
3. **Templates** (SwiftUI, rendered with `ImageRenderer`): Classic One-Sheet, Minimal,
   VHS Box, Title Card. Title, tagline (Apple Intelligence, with a fallback), top line, date
   and credits ("Starring …" from the event's people) are all editable.
4. **Files**: `poster.jpg` 1000×1500 and `fanart.jpg` 1920×1080 (no text). Exports embed the
   poster as cover art (M4V/MP4) and copy both beside the movie: `poster.jpg`/`fanart.jpg` in
   movie folders, `<name>.jpg`/`<name>-fanart.jpg` with date-first naming. An event with
   **Poster** switched on gets a default poster at export if it doesn't have one.

## Prototype

```
cd prototype
python3 test_segment.py                    # builds a fake tape and checks the results
python3 test_datestamp.py                  # 23 camcorder date-stamp cases
python3 test_restore.py --esrgan PATH/realesrgan-ncnn-vulkan [--quick]
                                           # restores a fake interlaced tape with Real-ESRGAN
python3 test_hero_frames.py                # sharp frames beat blurry/dark/blown/smeared
python3 test_face_groups.py                # 6 people + strangers grouped; names respected
python3 restore.py TAPE.mov --start 42 --end 70 -o master.mov --esrgan PATH/realesrgan-ncnn-vulkan
python3 cinefam_segment.py TAPE.mov -o result.json --export-clips clips/
```

The Swift `Analyzer` is a port of `cinefam_segment.py`. Tune thresholds in the prototype
against real tapes first, then copy them across.

## Next up

All seven phases have a first pass. Next is getting it to build and run:

- Build in Xcode and fix anything the compiler flags (this first pass was written without
  a Mac to compile on).
- Run the prototype on 3 real tapes (VHS, MiniDV, mixed) and tune `classify()` thresholds.
- `dvrescue` for exact MiniDV recording dates.
- Tune restoration defaults on real VHS (AI strength, denoise, edge trim).
- Optional local Stable Diffusion img2img (Apple's ml-stable-diffusion, Core ML) for
  styles Image Playground doesn't offer — a 2–5 GB model download, so opt-in.
- Face restoration for poster stills (GFPGAN, Apache 2.0).
