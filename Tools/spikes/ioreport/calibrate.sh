#!/bin/sh
# Calibrates the PMP energy histograms at several CPU loads against two references: the Energy
# Model counters and the CPU Power that powermetrics prints. Energy Model only counts while
# powermetrics runs, so this needs root. Takes about 2 minutes.
# Run from the repo root: sudo sh Tools/spikes/ioreport/calibrate.sh
IOR=build/spikes/ior
OUT=build/spikes/calibrate-stage.txt
trap 'pkill -x yes 2>/dev/null' EXIT INT TERM
for LOAD in 0 1 2 4 6 10; do
  i=0; while [ "$i" -lt "$LOAD" ]; do yes >/dev/null & i=$((i+1)); done
  sleep 2
  $IOR calibrate 12 > "$OUT" &
  PMW=$(powermetrics --samplers cpu_power -i 1000 -n 12 2>/dev/null \
    | awk '/^CPU Power/ { sum += $3; n++ } END { if (n) printf "%.3f", sum / n / 1000 }')
  wait
  echo "loops=$LOAD powermetrics_CPU_W=$PMW $(cat "$OUT" | tr '\n' ' ')"
  pkill -x yes 2>/dev/null
  sleep 2
done
echo "done"
