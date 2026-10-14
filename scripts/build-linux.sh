#!/bin/bash
# Builds DigUp for Linux into build.noindex/linux/ (build.sh runs this on Linux):
#   digup          the CLI, and the app's indexing helper and query encoder (the app runs the one next to it)
#   digup-app      the desktop app (GTK 4)
#   digup.desktop  its launcher, with Search, Status and Settings actions; the icon and the version beside them
# The Swift runtime is linked in, so the folder runs on its own (needs GTK 4, and ffmpeg, poppler-utils, tesseract
# and pandoc for reading files; README.md, "Linux"). There's no install step: link the launcher into
# ~/.local/share/applications (and ~/.config/autostart, or let Settings do that) to use it from the desktop.
set -euo pipefail
cd "$(dirname "$0")/.."

# llama.cpp, the embedding runtime, linked into the helper (only rebuilt when its tag or patch changes).
scripts/build-llama.sh

swift build -c release --static-swift-stdlib --product digup
swift build -c release --static-swift-stdlib --product digup-app
BIN="$(swift build -c release --static-swift-stdlib --show-bin-path)"

OUT=build.noindex/linux
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$BIN/digup" "$BIN/digup-app" "$OUT/"
cp Resources/AppIcon/appicon.svg "$OUT/digup.svg"
cp Resources/Acknowledgements.txt "$OUT/"
# The version the update check compares with the appcast's (the Mac's CFBundleShortVersionString).
sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' Resources/Info.plist > "$OUT/VERSION"

HERE="$(cd "$OUT" && pwd)"
cat > "$OUT/digup.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=DigUp
GenericName=File Search
Comment=Find your files by describing them
Exec="$HERE/digup-app"
Icon=$HERE/digup.svg
Categories=Utility;FileTools;
Keywords=search;find;files;photos;screenshots;pdf;
StartupNotify=false
Actions=Search;Status;Settings;

[Desktop Action Search]
Name=Search…
Exec="$HERE/digup-app" --toggle

[Desktop Action Status]
Name=Indexing Status
Exec="$HERE/digup-app" --status

[Desktop Action Settings]
Name=Settings…
Exec="$HERE/digup-app" --settings
EOF
chmod +x "$OUT/digup.desktop"
echo "Built $OUT ($(cat "$OUT/VERSION")): $(ls "$OUT" | tr '\n' ' ')"
