#!/bin/sh
# Calibrates the PMP energy histograms at several CPU loads against two references: the Energy
# Model counters and the CPU Power that powermetrics prints. Energy Model only counts while
# powermetrics runs, so this needs root, and a background powermetrics keeps it counting
# throughout: its first update after a pause includes energy from the pause. About 2 minutes.
# Run from the repo root: sudo sh Tools/spikes/ioreport/calibrate.sh
IOR=build/spikes/ior
OUT=build/spikes/calibrate-stage.txt
cleanup() { pkill -x yes 2>/dev/null; [ -n "$KEEP" ] && kill "$KEEP" 2>/dev/null; }
trap cleanup EXIT INT TERM
powermetrics --samplers cpu_power -i 1000 -n 400 >/dev/null 2>&1 &
KEEP=$!
sleep 5
for LOAD in 0 1 2 4 6 10; do
  i=0; while [ "$i" -lt "$LOAD" ]; do yes >/dev/null & i=$((i+1)); done
  sleep 2
  $IOR calibrate 12 > "$OUT" &
  CAL=$!
  PMW=$(powermetrics --samplers cpu_power -i 1000 -n 12 2>/dev/null \
    | awk '/^CPU Power/ { sum += $3; n++ } END { if (n) printf "%.3f", sum / n / 1000 }')
  # Only the measurement: a bare `wait` would also wait for the busy loops, which never end.
  wait "$CAL"
  echo "loops=$LOAD powermetrics_CPU_W=$PMW $(tr '\n' ' ' < "$OUT")"
  pkill -x yes 2>/dev/null
  sleep 2
done
echo "done"
