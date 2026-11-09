#!/bin/sh
# M2 acceptance: Pulse's PowerCollector against powermetrics on the same workload.
# Builds as you, then asks for your password once, for powermetrics only. About 2 minutes.
# Run from the repo root: sh Tools/spikes/power-accuracy/run.sh
set -e
OUT=build/spikes/power-accuracy
TOOL=$OUT/pulse-power
CORE=build/relcore/Build/Products/Release
mkdir -p "$OUT"

if [ ! -d "$CORE/PulseCore.framework" ]; then
  xcodebuild -scheme PulseCore -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/relcore build >/dev/null
fi
swiftc -O -parse-as-library -swift-version 6 -F "$CORE" -framework PulseCore \
  -Xlinker -rpath -Xlinker "$PWD/$CORE" -o "$TOOL" Tools/spikes/power-accuracy/main.swift

sudo -v
trap 'pkill -x yes 2>/dev/null; pkill -f "pulse-power gpu-load" 2>/dev/null; true' EXIT INT TERM
SECS=15

stage() {
  NAME=$1
  sleep 3
  "$TOOL" measure $SECS > "$OUT/pulse.txt" &
  PULSE=$!
  sudo powermetrics --samplers cpu_power,gpu_power -i 1000 -n $SECS 2>/dev/null > "$OUT/pm.txt"
  wait "$PULSE"
  python3 -I - "$NAME" "$OUT/pulse.txt" "$OUT/pm.txt" <<'PY'
import re, sys
name, pulse_file, pm_file = sys.argv[1:]
pulse = dict(kv.split("=") for kv in open(pulse_file).read().split())
text = open(pm_file).read()
def average(label):
    values = [float(v) for v in re.findall(rf"^{label} Power: (\d+) mW", text, re.M)]
    return sum(values) / len(values) / 1000 if values else float("nan")
pm_cpu, pm_gpu = average("CPU"), average("GPU")
cpu, gpu = float(pulse["pulse_cpu"]), float(pulse["pulse_gpu"])
def error(a, b):
    return f"{(a / b - 1) * 100:+.1f}%" if b > 0.5 else f"{(a - b) * 1000:+.0f} mW"
print(f"{name:10} CPU pulse {cpu:6.2f} W  powermetrics {pm_cpu:6.2f} W  {error(cpu, pm_cpu):>8}   "
      f"GPU pulse {gpu:6.2f} W  powermetrics {pm_gpu:6.2f} W  {error(gpu, pm_gpu):>8}   "
      f"(E {float(pulse['pulse_e']):.2f} W, P {float(pulse['pulse_p']):.2f} W)")
PY
}

echo "Errors are percentages above 0.5 W and milliwatts below it."
stage idle
for LOAD in 2 4 10; do
  i=0; while [ "$i" -lt "$LOAD" ]; do yes >/dev/null & i=$((i+1)); done
  stage "cpu x$LOAD"
  pkill -x yes || true
done
"$TOOL" gpu-load 25 &
stage gpu
wait
echo "done"
