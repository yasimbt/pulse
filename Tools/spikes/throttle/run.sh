#!/bin/sh
# Records throttling signals: 30 s idle, LOAD_SECONDS of heavy load, then 60 s cooling.
# The load is floating-point work on every CPU core plus a Metal GPU load, from the power-accuracy
# helper; `yes` loops mostly wait in the kernel and barely heat the chip.
# Run from the repo root: sh Tools/spikes/throttle/run.sh [load seconds, default 300]
set -e
OUT=build/spikes/throttle
CORE=build/relcore/Build/Products/Release
LOAD_SECONDS=${1:-300}
mkdir -p "$OUT"
swiftc -O -parse-as-library -swift-version 6 -F "$CORE" -framework PulseCore \
  -Xlinker -rpath -Xlinker "$PWD/$CORE" -o "$OUT/throttle" Tools/spikes/throttle/main.swift
LOAD=build/spikes/power-accuracy/pulse-power
mkdir -p build/spikes/power-accuracy
swiftc -O -parse-as-library -swift-version 6 -F "$CORE" -framework PulseCore \
  -Xlinker -rpath -Xlinker "$PWD/$CORE" -o "$LOAD" Tools/spikes/power-accuracy/main.swift
trap 'pkill -f "pulse-power (cpu|gpu)-load" 2>/dev/null; true' EXIT INT TERM
"$OUT/throttle" $((30 + LOAD_SECONDS + 60)) > "$OUT/throttle.csv" &
RECORDER=$!
sleep 30
"$LOAD" cpu-load "$LOAD_SECONDS" &
"$LOAD" gpu-load "$LOAD_SECONDS" &
wait "$RECORDER"
echo "wrote $OUT/throttle.csv"
