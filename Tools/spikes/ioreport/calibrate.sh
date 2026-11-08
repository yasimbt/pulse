#!/bin/sh
# Calibrates the PMP energy histograms against Energy Model counters at several CPU loads.
# Energy Model only counts while powermetrics runs, so this needs root.
# Run from the repo root: sudo sh Tools/spikes/ioreport/calibrate.sh
set -e
IOR=build/spikes/ior
powermetrics --samplers cpu_power -i 1000 -n 200 >/dev/null &
PM=$!
sleep 3
for LOAD in 0 1 2 4 8; do
  i=0; while [ $i -lt $LOAD ]; do yes >/dev/null & i=$((i+1)); done
  sleep 2
  echo "loops=$LOAD $($IOR calibrate 12)"
  pkill -x yes || true
  sleep 2
done
kill $PM 2>/dev/null || true
