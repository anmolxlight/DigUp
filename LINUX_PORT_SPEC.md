# Task: port DigUp to Linux, same features

Repo: ~/DigUp (branch `linux`). Host: Ubuntu 24.04 aarch64, no GPU, no display (Xvfb installable via apt, sudo works).
Swift 6.2.4 is installed via swiftly: run `. ~/.local/share/swiftly/env.sh` first in every shell.
Installed: ffmpeg, ffprobe, tesseract (+eng, ben, ara), pdftotext/pdftoppm/pdfinfo (poppler-utils), pandoc, libsqlite3-dev, libgtk-4-dev, cmake, xdotool, xclip, uv.

## Goal
DigUp (macOS-only Swift app: semantic file search with EmbeddingGemma 2 on llama.cpp) must build and run on Linux
with NO functionality change. macOS build must keep working exactly as before: keep all Apple code paths, add Linux
paths behind `#if os(Linux)` / `#if canImport(X)`. Do not delete or rewrite macOS behaviour.

## Must do, in order (commit after each step, small commits, author email anmolxlight@gmail.com)
1. **Engine (DigUpKit) + LlamaRuntime + `digup` CLI build and test on Linux.**
   - Package.swift: keep macOS targets; on Linux exclude Sparkle/DigUpApp (use `#if os(macOS)` conditional in the manifest),
     link sqlite3 (system library or `SQLite3` via a systemLibrary target), llama lib path, no Metal.
   - scripts/build-llama.sh: on Linux use `sha256sum`, CPU build (GGML_METAL off), produce the same libllamacpp.a.
   - Replacements on Linux: SQLite (system libsqlite3), Accelerate (plain Swift loops / SIMD), CryptoKit (swift-crypto
     only if needed, else a small SHA-256 via `sha256sum` or Foundation), ImageIO/CoreGraphics (ffmpeg to decode/resize
     images to JPEG/PNG), PDFKit (pdftotext per page, pdftoppm for scanned pages), Vision OCR (tesseract), AVFoundation
     (ffmpeg/ffprobe for audio windows, durations, frames, shot changes), NSAttributedString doc/rtf/odt/docx/html
     (pandoc or existing pure-Swift readers), UTType (extension tables), CoreServices/FSEvents (inotify or polling),
     iCloud placeholder checks (no-op on Linux), app-support path -> `$XDG_DATA_HOME/DigUp` (~/.local/share/DigUp),
     settings -> `$XDG_CONFIG_HOME/DigUp`.
   - `swift build -c release` and `swift test` must pass on Linux (all tests that don't intrinsically need Apple
     frameworks; Reference vector tests may tolerate CPU float drift only if the existing tolerance allows it — do not
     loosen tolerances silently, report it).
2. **Linux desktop app with the same features as DigUpApp** (search panel with global hotkey, results with previews/
   thumbnails, open at page/moment, reveal in file manager, copy file, bigger search window with grid + filters,
   tray/status menu with indexing progress + pause, settings window incl. folders/code folders/editors/hotkey/power
   policy, onboarding with model download + folder picker + estimates, folder watching, update check).
   Use GTK4 via a thin C shim or an existing Swift GTK binding if it builds; or if that is not workable, a small
   local web UI (Swift HTTP server bundled in the binary + `xdg-open`) is acceptable as long as every feature maps.
   Use: xdg-open (open files), `dbus-send org.freedesktop.FileManager1.ShowItems` (reveal), `mpv --start=` or
   `vlc --start-time=` fallback to xdg-open (open at moment), `evince -p`/`okular -p` (PDF at page), xclip/wl-copy (copy
   file as text/uri-list), StatusNotifierItem or GTK tray-less fallback, global hotkey via the desktop's custom shortcut
   (document `digup-app --toggle` command) since X11/Wayland global grabs vary. Editors: code/cursor/zed/subl/idea
   `--goto file:line` equivalents.
   Reuse DigUpApp logic files (AppModel, Engine, Estimates, FolderChoices, CodeEditors, Moments, PowerPolicy, etc.) by
   making them compile on Linux where they are UI-free; only rewrite the actual view/AppKit layer.
3. `build.sh` / new `scripts/build-linux.sh` produce `build.noindex/linux/` with `digup` + app binary + .desktop file.
4. README: add a "Linux" section (deps, build, run, hotkey setup). Keep the Mac docs.
5. Verify end to end on this box, headless: build llama, download the model (README says 865 MB; same HF repo the
   macOS app uses, see ModelFiles.swift / ModelDownload.swift), run `scripts/make-testbed.sh` (or a subset if it needs
   macOS-only swift scripts — port those generators too, or generate equivalent files with ffmpeg/python), index it with
   the CLI, run the evals in `evals/` and some searches across image, PDF, doc, audio, video, code. Run the GUI under
   Xvfb and take a screenshot (`import -window root` or ffmpeg x11grab) of the search panel with results to
   /home/ubuntu/DigUp/build.noindex/linux-proof.png.

## Rules
- Do NOT ask questions. Make reasonable calls and note them in LINUX_PORT_NOTES.md.
- Never remove macOS functionality. Shortest diffs, no speculative abstractions.
- Don't push. Don't touch anything outside ~/DigUp (except apt installs and ~/.cache for the model).
- At the end print: what works, eval numbers, anything not 1:1 with macOS and why.
