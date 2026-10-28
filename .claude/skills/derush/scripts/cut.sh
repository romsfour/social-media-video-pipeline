#!/usr/bin/env bash
# cut.sh — frame-accurate (or lossless) multi-range cut using ffmpeg concat demuxer.
#
# Usage:
#   cut.sh <source_video> <keep_ranges.json> <output_mp4>
#
# keep_ranges.json format:
#   [{"start": 12.5, "end": 45.0}, {"start": 72.0, "end": 90.0}]
#
# Options (environment variables):
#   LOSSLESS=1   Use -c copy (no re-encode). FAST but snaps every cut to the
#                nearest preceding keyframe — see the rationale below.
#
# DEFAULT = frame-accurate re-encode (-c:v libx264 -preset fast -crf 18 -c:a aac).
#
# Why re-encode is the default (empirical, not theoretical):
#   Screen recordings (macOS ScreenCaptureKit / .mov) have HIGHLY irregular
#   keyframe intervals — keyframes are inserted on scene changes, so gaps of
#   15+ seconds occur in static stretches and 1-3s gaps occur during activity.
#   With -c copy, ffmpeg can only cut at a keyframe boundary, so a requested
#   cut at t=76.0s can snap back as far as ~15s, destroying the precise
#   retraction / silence boundaries the upstream detector computed. Re-encoding
#   a few-minute 1080p clip is fast and lands cuts on the exact requested frame.
#   Use LOSSLESS=1 only when the source has dense, regular keyframes AND you can
#   tolerate keyframe-snapping (e.g. already-encoded delivery files).
#
# Dependencies: ffmpeg, ffprobe (dans le PATH), python3.
#
# Note: ffmpeg may emit "Non-monotonic DTS" warnings during concat when a
# source has non-zero base timestamps (e.g. synthetic test clips). These are
# cosmetic — ffmpeg self-corrects them and output duration/streams are correct.

set -euo pipefail

FFMPEG="${FFMPEG:-$(command -v ffmpeg)}"
FFPROBE="${FFPROBE:-$(command -v ffprobe)}"

SRC="${1:-}"
RANGES_JSON="${2:-}"
OUTPUT="${3:-}"

# --- Validate args -----------------------------------------------------------
if [[ -z "$SRC" || -z "$RANGES_JSON" || -z "$OUTPUT" ]]; then
  echo "Usage: cut.sh <source_video> <keep_ranges.json> <output_mp4>" >&2
  exit 1
fi

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: source video not found: $SRC" >&2
  exit 1
fi

if [[ ! -f "$RANGES_JSON" ]]; then
  echo "ERROR: keep_ranges.json not found: $RANGES_JSON" >&2
  exit 1
fi

# --- Parse JSON with python3 (available, avoids jq version quirks) -----------
PARSED=$(python3 - "$RANGES_JSON" <<'PYEOF'
import json, sys
data = json.loads(open(sys.argv[1]).read())
if not isinstance(data, list) or len(data) == 0:
    print("ERROR: keep_ranges.json must be a non-empty array", file=sys.stderr)
    sys.exit(1)
for item in data:
    print(f"{item['start']}\t{item['end']}")
PYEOF
)

NUM_RANGES=$(echo "$PARSED" | wc -l | tr -d ' ')
if [[ "$NUM_RANGES" -eq 0 ]]; then
  echo "ERROR: no ranges found in $RANGES_JSON" >&2
  exit 1
fi

# --- Set up temp dir ---------------------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

LIST_FILE="$TMPDIR/concat.txt"
touch "$LIST_FILE"

# Default: frame-accurate re-encode. LOSSLESS=1 opts into keyframe-snapping copy.
CODEC_FLAGS=(-c:v libx264 -preset fast -crf 18 -c:a aac)
MODE="re-encode (frame-accurate)"
if [[ "${LOSSLESS:-0}" == "1" ]]; then
  CODEC_FLAGS=(-c copy)
  MODE="lossless -c copy (snaps to nearest keyframe — may be off by seconds)"
fi
echo "Cut mode: $MODE"

# Invisible cuts: a short audio fade in/out on EACH kept segment so the joins
# between segments carry no click/pop — the edit is inaudible. FADE_MS=0 disables.
# Only possible on the re-encode path (afade needs to filter, not -c copy).
FADE_MS="${FADE_MS:-12}"
FADE_S=$(python3 -c "print(max(0.0, ${FADE_MS}/1000.0))" </dev/null)
APPLY_FADE=1
if [[ "${LOSSLESS:-0}" == "1" || "${FADE_MS}" == "0" ]]; then
  APPLY_FADE=0
  [[ "${LOSSLESS:-0}" == "1" && "${FADE_MS}" != "0" ]] && echo "Note: FADE_MS ignored in LOSSLESS mode (needs re-encode)."
fi
[[ "$APPLY_FADE" == "1" ]] && echo "Invisible cuts: ${FADE_MS}ms audio fade per segment edge"

# --- Re-encode path: ONE pass, trim/atrim + concat filter --------------------
# Never encode segments separately and glue them with the concat demuxer: each
# segment file carries its own AAC priming/padding and a whole-frame video length,
# the two never match, and the gap ACCUMULATES at every join. Measured 2026-10-17
# (IMG_4631, 80 cuts): sound ~210 ms behind the lips by the end; test_cut_sync.sh
# reproduces 640 ms over 40 cuts. Here every range is snapped to the source frame
# grid, so each kept piece has the same audio and video length, and one encoder
# writes one timeline: no join can drift.
mkdir -p "$(dirname "$OUTPUT")"
if [[ "${LOSSLESS:-0}" != "1" ]]; then
  FPS=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$SRC")
  GRAPH="$TMPDIR/graph.txt"
  TOTAL_KEPT=$(python3 - "$RANGES_JSON" "$FPS" "$FADE_S" "$APPLY_FADE" "$GRAPH" <<'PYEOF'
import json, sys
from fractions import Fraction
ranges = json.load(open(sys.argv[1])); fps = Fraction(sys.argv[2])
fade, apply_fade, out = float(sys.argv[3]), sys.argv[4] == "1", sys.argv[5]
parts, labels, total = [], [], 0.0
for i, r in enumerate(ranges):
    s = float(round(Fraction(r["start"]).limit_denominator(10**6) * fps) / fps)
    e = float(round(Fraction(r["end"]).limit_denominator(10**6) * fps) / fps)
    if e <= s:
        continue
    d = e - s
    af = f",afade=t=in:st=0:d={fade},afade=t=out:st={d - fade:.6f}:d={fade}" if apply_fade and d > 2 * fade else ""
    parts.append(f"[0:v]trim=start={s:.6f}:end={e:.6f},setpts=PTS-STARTPTS[v{i}];")
    parts.append(f"[0:a]atrim=start={s:.6f}:end={e:.6f},asetpts=PTS-STARTPTS{af}[a{i}];")
    labels.append(f"[v{i}][a{i}]")
    total += d
parts.append("".join(labels) + f"concat=n={len(labels)}:v=1:a=1[vo][ao]")
open(out, "w").write("\n".join(parts))
print(round(total, 3))
PYEOF
)
  IDX=$(grep -c "^\[0:v\]trim" "$GRAPH")
  "$FFMPEG" -nostdin -y -loglevel warning -i "$SRC" -filter_complex_script "$GRAPH" \
    -map "[vo]" -map "[ao]" -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p \
    -c:a aac -b:a 192k -movflags +faststart "$OUTPUT"
  echo "Cut complete: $IDX range(s), ${TOTAL_KEPT}s kept → $OUTPUT"
  exit 0
fi

# --- LOSSLESS path: per-range stream copy + concat demuxer (keyframe-snapped) --
IDX=0
TOTAL_KEPT=0
while IFS=$'\t' read -r START END <&3; do
  SEG="$TMPDIR/seg_${IDX}.mp4"
  DURATION=$(python3 -c "print(round($END - $START, 3))" </dev/null)
  "$FFMPEG" -nostdin -y -loglevel warning \
    -ss "$START" -to "$END" \
    -i "$SRC" \
    "${CODEC_FLAGS[@]}" \
    -reset_timestamps 1 \
    "$SEG"
  echo "file '${SEG}'" >> "$LIST_FILE"
  TOTAL_KEPT=$(python3 -c "print(round($TOTAL_KEPT + $DURATION, 3))" </dev/null)
  IDX=$((IDX + 1))
done 3<<< "$PARSED"

if [[ "$IDX" -eq 1 ]]; then
  mv "$TMPDIR/seg_0.mp4" "$OUTPUT"
else
  "$FFMPEG" -nostdin -y -loglevel warning \
    -f concat -safe 0 -i "$LIST_FILE" \
    -c copy -avoid_negative_ts make_zero \
    "$OUTPUT"
fi

echo "Cut complete: $IDX range(s), ${TOTAL_KEPT}s kept → $OUTPUT"
