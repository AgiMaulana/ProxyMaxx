#!/bin/bash
#
# Captures the Phase 0 baseline for the capture-performance work (issue #58):
# a `sample` of the running app plus the signpost stream from its capture path.
#
# Usage: Scripts/capture-perf-baseline.sh [output-directory]
#
# Start the app first (Scripts/run.sh or the bundled ProxyMaxx.app), open the CCTV
# reproduction from the issue, then run this. The duration defaults to 15 s and can be
# changed with PROXYMAXX_SAMPLE_SECONDS. Set PROXYMAXX_PID to sample a specific process.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$PWD/perf-baseline}"
DURATION="${PROXYMAXX_SAMPLE_SECONDS:-15}"
PID="${PROXYMAXX_PID:-}"

if [[ -z "$PID" ]]; then
    PID="$(pgrep -x ProxyMaxx || true)"
fi
if [[ -z "$PID" ]]; then
    PID="$(pgrep -f 'ProxyMaxxApp' || true)"
fi
if [[ -z "$PID" ]]; then
    echo "No ProxyMaxx process found. Start the app, then rerun, or set PROXYMAXX_PID." >&2
    exit 1
fi

mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
SAMPLE="$OUT/sample-$STAMP.txt"
SIGNPOSTS="$OUT/signposts-$STAMP.log"

echo "Sampling pid $PID for ${DURATION}s ..."
sample "$PID" "$DURATION" -file "$SAMPLE" &
SAMPLE_PID=$!

# `sample` shows where the time went; the signpost stream shows which capture stage it
# went to, even when Instruments is not attached.
log stream --signpost --style compact \
    --predicate 'subsystem == "oss.proxymaxx" AND category == "capture"' \
    > "$SIGNPOSTS" 2>&1 &
LOG_PID=$!

wait "$SAMPLE_PID"
kill "$LOG_PID" 2>/dev/null || true
wait "$LOG_PID" 2>/dev/null || true

echo "wrote:"
echo "  $SAMPLE"
echo "  $SIGNPOSTS"
echo
echo "For interval timelines, record the same reproduction in Instruments:"
echo "  xctrace record --template 'Time Profiler' --attach $PID \\"
echo "      --time-limit ${DURATION}s --output \"$OUT/trace-$STAMP.trace\""
echo
echo "The app also logs a 'capture:' summary every 5 s while a backlog exists; see"
echo "  $ROOT/docs/capture-performance.md"
