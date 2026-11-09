#!/bin/sh
# M4 acceptance: a 5-minute session with 30 s idle, 240 s of CPU and GPU load, 30 s cooling.
# Run from the repo root: sh Tools/spikes/session-check/run.sh
set -e
OUT=build/spikes/session-check
CORE=build/relcore/Build/Products/Release
LOAD=build/spikes/power-accuracy/pulse-power
mkdir -p "$OUT" build/spikes/power-accuracy
swiftc -O -parse-as-library -swift-version 6 -F "$CORE" -framework PulseCore \
  -Xlinker -rpath -Xlinker "$PWD/$CORE" -o "$OUT/session-check" Tools/spikes/session-check/main.swift
swiftc -O -parse-as-library -swift-version 6 -F "$CORE" -framework PulseCore \
  -Xlinker -rpath -Xlinker "$PWD/$CORE" -o "$LOAD" Tools/spikes/power-accuracy/main.swift
trap 'pkill -f "pulse-power (cpu|gpu)-load" 2>/dev/null; true' EXIT INT TERM
"$OUT/session-check" 300 &
CHECK=$!
sleep 32
"$LOAD" cpu-load 240 &
"$LOAD" gpu-load 240 &
wait "$CHECK"
