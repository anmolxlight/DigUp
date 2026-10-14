#!/bin/bash
# Speech for the testbed on Linux, where the Mac scripts use `say`: Piper's neural voices for English (lessac) and
# Arabic (kareem), espeak-ng for Bengali (Piper has no Bengali voice). 16 kHz mono WAV, as `say` + ffmpeg make it.
#   speak.sh en|ar|bn <out.wav> "<text>"
# Piper's voices (~60 MB each) are kept in ${XDG_CACHE_HOME:-~/.cache}/piper-voices.
set -euo pipefail
LANG_CODE="$1"; OUT="$2"; TEXT="$3"
VOICES="${XDG_CACHE_HOME:-$HOME/.cache}/piper-voices"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
case "$LANG_CODE" in
  en) VOICE=en/en_US/lessac/medium/en_US-lessac-medium ;;
  ar) VOICE=ar/ar_JO/kareem/medium/ar_JO-kareem-medium ;;
  bn) espeak-ng -v bn -s 150 -w "$TMP/raw.wav" "$TEXT"
      ffmpeg -loglevel error -y -i "$TMP/raw.wav" -ac 1 -ar 16000 "$OUT"; exit 0 ;;
esac
NAME="$(basename "$VOICE")"
mkdir -p "$VOICES"
for ext in onnx onnx.json; do
  [[ -f "$VOICES/$NAME.$ext" ]] || curl -sSfL -o "$VOICES/$NAME.$ext" \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/$VOICE.$ext"
done
printf '%s' "$TEXT" | uv run --no-project --with piper-tts python -I -m piper -m "$VOICES/$NAME.onnx" -f "$TMP/raw.wav"
ffmpeg -loglevel error -y -i "$TMP/raw.wav" -ac 1 -ar 16000 "$OUT"
