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
  every document. On Linux the no-break space goes into the pattern as the character itself; the Mac keeps its
  pattern exactly as it was (the first version of this port changed it on both, which was reverted).
- **Screenshots.** macOS marks them with an extended attribute that survives copies; Linux has no such convention, so
  there it's the file name (`Screenshot…`, what GNOME, KDE and Android write; "Spectacle" was added to the prefixes)
  or a folder named Screenshots (where GNOME 42+ and KDE save them). The testbed's `synthetic/screenshots/` counts;
  its two Bengali and Arabic screenshots (`lang/bn`, `lang/ar`, marked by `xattr` on a Mac) index as pictures here,
  without OCR.
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
- **llama.cpp is built for this CPU, and uses all of it.** `GGML_NATIVE=ON` on Linux (dot-product instructions on
  ARM), and `n_threads` = the core count instead of llama.cpp's default 4 (`#if os(Linux)` in `LlamaEmbedder`).
  Three files went from 50 s to 20 s here; the reference vectors still pass. `LLAMA_PORTABLE=1 scripts/build-llama.sh`
  builds for any CPU of the architecture, for a build folder meant for other machines. The Mac build is untouched.
- **The helper never exited** (found here, in step 1's code): glibc's `exit()` waits for stdin's lock, which the
  index-service's command reader holds while it waits for a line. `digup index-service` ends with `_exit` on Linux.
- **Video moments are the frames' own times** (found in step 1's code): ffmpeg's `fps` filter reported each sampled
  frame on its own grid (6.0 s) while taking the frame half a second later, so a moment pointed at the end of the
  shot before it. `select` keeps the frames' real timestamps, as `AVAssetImageGenerator` reports them on a Mac.
- **Estimates on Linux** use per-unit costs measured here (`Costs` in `Estimator.swift`, `#if os(Linux)`): CPU
  inference is 10–30x slower than the Mac's Metal, so the M4 Pro numbers would promise minutes that take an hour.
- **Package.resolved.** The first version of the manifest declared no dependencies on Linux, and SwiftPM there deleted
  the Mac's Sparkle pin. Sparkle is declared on both (fetched, unused, on Linux), and the pin stays.

## The desktop app (`Sources/DigUpApp/Linux`)

- **GTK 4 from Swift, no binding library.** `Sources/CGtk` is a module map over `gtk/gtk.h` plus three C helpers (the
  main-queue hook below, and a file content provider for dragging, which needs a variadic call). `Gtk.swift` has the
  casts (GTK's are macros), closures as signal handlers, and a `watch` that re-runs a view update when the
  `@Observable` models it read change, which is what SwiftUI did for the Mac views.
- **One main loop.** GLib runs the app; libdispatch's main queue (where `DispatchQueue.main` and `@MainActor` work go)
  is drained from GLib through the queue's eventfd (`_dispatch_get_main_queue_handle_4CF`), so the shared Engine,
  ModelDownload and Estimates code runs unchanged.
- **Shared, not copied:** `AppLog`, `AppModel`, `AppSettings`, `CodeFolders`, `Engine`, `Estimates`, `FolderChoices`,
  `ModelDownload`, `PowerPolicy` and `Results` compile into both apps. Their Linux differences are `#if` lines: the
  helper next to the binary instead of in `Contents/Helpers`, `malloc_trim` for the malloc-zone call, `statvfs` for free
  space, no Time Machine exclusion, no `waitsForConnectivity` (not in Linux Foundation; a lost connection retries on
  the existing 2/5/15/30 s schedule instead), the default hotkey (`ctrl+alt+space`: Super+Space switches input sources
  on GNOME), and the SwiftUI half of `FolderChoices.swift`.
- **The hotkey is the desktop's.** X11 grabs don't work on Wayland and Wayland has no general global-shortcut API, so
  the app is single-instance (GApplication) and `digup-app --toggle` toggles the panel in the running copy. On GNOME
  the app writes the custom shortcut itself (gsettings); elsewhere Settings shows the command to bind. The shortcut
  recorder and onboarding's "try it now" step work the same way (`--toggle` reaches the tester).
- **No tray.** GTK 4 dropped status icons, and StatusNotifierItem needs a dbusmenu implementation and an extension on
  GNOME. The menu's contents (status, progress, Search…, Open, Pause/Resume, Download the Model, Settings, Check for
  Updates, Quit) are the search window's ☰ popover and a small window (`--status`, also a launcher action).
- **Panel placement.** GTK 4 can't position windows (Wayland doesn't allow it), so the panel is an undecorated window
  the window manager places (usually centered) rather than one 16% from the top of the screen with the pointer.
- **Quick Look** is a big preview window (Space / Ctrl+Y, Esc closes) showing the same preview as the panel: the page
  with the words marked, the frame with ▶ to play from the moment, the passage, the code lines.
- **Previews and thumbnails** are made by ffmpeg (frames, scaled pictures) and poppler (`pdftoppm`; `pdftotext -bbox`
  for where the words are, marked with ffmpeg's `drawbox`), cached in `~/.cache/DigUp/pictures` and trimmed after a
  day, where the Mac uses Quick Look thumbnails, AVFoundation and PDFKit with in-memory caches.
- **Playing from the moment** uses GTK's media stream (GStreamer); mp4/H.264 needs gstreamer1.0-libav.
- **Opening at the page/moment** goes to the desktop's default app when it's one that takes a page or time (Evince
  `--page-index`, Okular `-p`, mpv `--start`, VLC `--start-time`), else any of those installed, else xdg-open. The Mac
  fills Preview's search with words from the page; Evince and Okular go to the page itself instead.
- **Editors** for code results are found on PATH (`code`/`cursor`/`codium`/`windsurf --goto`, `zed`/`subl path:line`,
  JetBrains `--line`, `kate --line`, `gedit`/`gnome-text-editor +line`) instead of by bundle id.
- **Copy** puts the file on the clipboard as `text/uri-list` (wl-copy on Wayland, xclip on X11), which file managers
  paste as the file. Drag-and-drop out of the results uses GTK's own file provider.
- **Updates.** No Sparkle on Linux and no single way to install, so the update check reads the same appcast daily
  (same setting, same "Update to DigUp x…" item and status-bar note) and offers the release page; installing is a
  rebuild. `build.noindex/linux/VERSION` is what it compares with (dev builds count as older).
- **Login item** = `~/.config/autostart/digup.desktop`, starting `digup-app --background`.
- **Power policy** reads `/sys/class/power_supply` once a minute instead of IOKit notifications; Power Saver
  (power-profiles-daemon) stands in for Low Power Mode; Linux has no thermal state, so "Mac is warm" never applies.
- **Onboarding's folders** are the XDG user folders (`xdg-user-dir`), so they're the localized names a desktop uses.
- **Drives** connecting and going come from GIO's volume monitor (NSWorkspace's mount notifications on a Mac).
- **Not done:** the panel's right-click menu on a result (its actions are the keys and buttons), and the Mac's
  snapshot-to-PNG debug hooks (a screenshot of the X display does that job: see below).

## Build and test files

- `scripts/build-linux.sh` (and `build.sh` on Linux) builds into `build.noindex/linux/` with the Swift runtime linked
  in (`--static-swift-stdlib`; linking FoundationNetworking statically needs `libcurl4-openssl-dev`).
- The testbed: `make-testbed.sh` and its helpers keep their Mac steps and gain Linux ones (`make_files.py`,
  `speak.sh`). Differences in the files themselves: macOS's sample pictures aren't on Linux, so the same subjects come
  as photos from Wikipedia's articles; speech is Piper's (English, Arabic) and espeak-ng's (Bengali) instead of macOS's
  Samantha, Majed and Piya; PDFs are laid out by Pango rather than CoreText and WebKit (Bengali text layers come out
  in glyph order just as WebKit's do, so they get the same "render the page" treatment); the four system sounds are
  synthesized. The evals' expected answers are the same files at the same paths.


## Verified on this machine (Ubuntu 24.04, aarch64, 2 cores, no GPU, headless)

- `swift build -c release` and `swift test`: 76 tests pass, `ReferenceVectorTests` included at its existing
  tolerance (no tolerance changed).
- The model downloaded by the app itself from Hugging Face (865 MB in ~95 s) and passed its SHA-256 checks.
- The testbed (`scripts/make-testbed.sh`, 83 files to index plus 37 code files) indexed with the CLI in 22.5 min, the
  code index in 1.4 min. Evals (`digup eval`, the testbed's base path pointed at its folder):

  | eval | queries | R@1 | R@5 | R@10 | MRR |
  |---|---|---|---|---|---|
  | synthetic | 37 | 0.97 | 1.00 | 1.00 | 0.99 |
  | multilingual | 48 | 0.90 | 0.94 | 0.94 | 0.92 |
  | code | 41 | 1.00 | 1.00 | 1.00 | 1.00 |

  The misses: a screenshot ranked #2 below a recording for "my flight to Japan"; Bengali speech made by espeak-ng
  (not found, and one en→bn miss about it), which is a much rougher voice than macOS's Piya; an Arabic speech clip at
  #2; the Bengali wallet screenshot, which has no OCR here (see Screenshots), at #2 and taking first place in one
  bn→en query. The code eval needs the testbed outside any git repository (code search leaves out what git ignores,
  and `.dev/` is ignored in this repo), so it ran on a copy in /tmp.
- The app under Xvfb: onboarding (all steps, the folder estimates), the panel (results, previews, the frame at the
  moment, highlighted passages), the window, Settings, `--toggle` from a second process, `--status`.
  `build.noindex/linux-proof.png` is the panel finding "a zebra": the picture, and the moment in two videos.
