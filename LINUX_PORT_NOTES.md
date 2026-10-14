# DigUp on Linux: the port, and the calls made along the way

DigUp was macOS-only. This is the same app on Linux, with the Mac build untouched: every Apple code path is still
there, and the Linux ones sit beside it behind `#if os(Linux)` / `#if canImport(…)`. Nothing was deleted or rewritten
for the Mac's sake.

Host it was built and run on: Ubuntu 24.04, aarch64, 2 cores, no GPU, no display.

## What stands in for what

| macOS | Linux |
|---|---|
| SQLite3 module | system libsqlite3 through `Sources/CSQLite` (3.45, FTS5 + JSON1 built in) |
| Accelerate (`vDSP_mmul`, `vImageConvert_Planar16FtoPlanarF`) | `Vectors.multiply` / a `Float16` loop (hardware fp16 on aarch64) |
| CryptoKit `SHA256` | `Sources/DigUpKit/SHA256Linux.swift` (FIPS 180-4, ~80 lines, no new dependency) |
| ImageIO | ffmpeg + ffprobe, with heif-convert for HEIC/AVIF and dcraw for camera RAW |
| EXIF through ImageIO | `EXIF` in `ExtractorsLinux.swift`: JPEG APP1 / TIFF, DateTimeOriginal + Orientation |
| Vision text recognition | tesseract (eng + ben + ara installed here) |
| PDFKit | pdfinfo (page count, title, locked), pdftotext (per page, reading order), pdftoppm (pages that must be pictures) |
| AVFoundation | ffprobe (durations, which tracks there are) and ffmpeg (16 kHz mono PCM, sampled frames) |
| `NSAttributedString` doc/rtf/odt/docx | pandoc; the old binary `.doc` goes through catdoc |
| UniformTypeIdentifiers | `UTTypeLinux.swift`: extension tables for pdf/image/movie/audio/source/script |
| CoreServices (Spotlight `MDItem`) | pdfinfo and ffprobe read the page count and duration straight from the file |
| FSEvents | inotify (`Sources/DigUpApp/Linux/FolderWatcher.swift`) |
| iCloud placeholder checks | no-op: Linux has no dataless files |
| `~/Library/Application Support/DigUp` | `$XDG_DATA_HOME/DigUp` (`~/.local/share/DigUp`) |
| settings in `com.abdurrahim.DigUp.plist` | `$XDG_CONFIG_HOME/DigUp/settings.plist` (a Foundation defaults suite) |
| AppKit + SwiftUI | GTK 4, called from Swift (`Sources/CGtk` is the module map plus a few C helpers for macros) |
| Sparkle | a daily read of the same appcast; a newer version waits in the menu and opens its release page |
| Carbon hotkey | the desktop's own custom shortcut running `digup-app --toggle` (set up automatically on GNOME) |
| menubar status item | the search window's ☰ menu and `digup-app --status` (GTK 4 has no tray) |
| Quick Look | a big preview window (Space), the same preview the panel shows |
| NSWorkspace open / reveal / pasteboard | `xdg-open`, `org.freedesktop.FileManager1.ShowItems`, `wl-copy`/`xclip` (text/uri-list) |
| QuickTime/IINA at a moment, Preview at a page | `mpv --start` / `vlc --start-time`, `evince --page-index` / `okular -p` |
| SMAppService login item | `~/.config/autostart/digup.desktop` |
| IOKit power source, thermal state, Low Power Mode | `/sys/class/power_supply`, none, power-profiles-daemon's Power Saver (read once a minute) |

## Decisions worth knowing about

- **Reference vectors pass unchanged.** `ReferenceVectorTests` checks this build's vectors against the ones the Mac's
  Metal build makes, at the tolerance that was already there (cosine ≥ 0.999). The Linux CPU build passes it as it
  stands; no tolerance was loosened, and `LlamaEmbedder.vectorVersion` did not have to move. An index made on a Mac
  and one made here hold the same vectors.
- **`\u{00A0}` in a regex** (`DocExtractor.chunks`) made Linux's ICU reject the whole pattern, which silently emptied
  every document. The no-break space now goes into the pattern as the character itself — the same thing on both
  platforms, and the one change in this port that touches shared code for a reason other than platform APIs.
- **Screenshots.** macOS marks them with an extended attribute that survives copies; Linux has no such convention, so
  there it's the file name alone (`Screenshot…`, which is what GNOME, KDE and Android all write). The name fallback
  was already in `Rules.isScreenshot`; "Spectacle" (KDE) was added to the prefixes.
- **Shot detection in video** is the same 8×8 average hash within 4 bits. One ffmpeg pass samples the frames, writes
  them as JPEG and, on a second branch of the same filter graph, as 8×8 grey — so the hashes cost no extra decoding.
  `showinfo` reports the time each frame really sits at, which is what `AVAssetImageGenerator` returned.
- **Audio windowing is shared code now.** The window/hop/silence-gate/WAV logic moved into `AudioExtractor.slice`,
  which both platforms call; only the thing producing PCM differs (an `AVAssetReader` or an ffmpeg pipe). The Mac's
  arithmetic is unchanged.
- **HEIC needs ffmpeg 7 or heif-convert.** Ubuntu 24.04 ships ffmpeg 6.1, which has no HEIF demuxer, so `.heic`,
  `.heif` and `.avif` go through `heif-convert` (libheif-examples) and camera RAW through `dcraw`. Without those two
  packages those formats report "unreadable" instead of being indexed; everything else works with ffmpeg alone.
- **EXIF only from JPEG and TIFF/DNG.** ImageIO reads EXIF out of every container it knows; the small reader here
  covers the two that matter for "when was this taken". Other formats report no date, which is what a Mac does for a
  picture that has none.
- **`vDSP_mmul` vs the loop.** The replacement keeps four running sums so the NEON pipelines overlap. Float addition
  isn't associative, so cosines can differ in the seventh decimal; that is far below the 0.999 the reference test
  asks for and far below anything that reorders results.
- **`ar` instead of `libtool`.** `scripts/build-llama.sh` merges the static libraries with an `ar` MRI script on
  Linux. Metal, BLAS and OpenMP are off: a plain CPU build, so the archive needs no libgomp at link time.
