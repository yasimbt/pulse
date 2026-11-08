#!/bin/sh
# Calibrates the PMP energy histograms against Energy Model counters at several CPU loads.
# Energy Model only counts while powermetrics runs, so this needs root. Takes about 2 minutes.
# Run from the repo root: sudo sh Tools/spikes/ioreport/calibrate.sh
IOR=build/spikes/ior
cleanup() { pkill -x yes 2>/dev/null; kill "$PM" 2>/dev/null; }
trap cleanup EXIT INT TERM
powermetrics --samplers cpu_power -i 1000 -n 300 >/dev/null 2>&1 &
PM=$!
sleep 3
for LOAD in 0 1 2 4 6 10; do
  i=0; while [ "$i" -lt "$LOAD" ]; do yes >/dev/null & i=$((i+1)); done
  sleep 2
  echo "loops=$LOAD $($IOR calibrate 12)"
  pkill -x yes 2>/dev/null
  sleep 2
done
echo "done"
