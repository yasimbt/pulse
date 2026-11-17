#!/bin/sh
# Builds the GPU spike against a Release PulseCore, then runs it with the given arguments.
# Run from the repo root: sh Tools/spikes/gpu/run.sh watch 10 0.5
set -e
OUT=build/spikes/gpu
TOOL=$OUT/gpu-spike
CORE=build/relcore/Build/Products/Release
mkdir -p "$OUT"

if [ ! -d "$CORE/PulseCore.framework" ] || [ -n "$REBUILD_CORE" ]; then
  xcodebuild -scheme PulseCore -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/relcore build >/dev/null
fi
swiftc -O -parse-as-library -swift-version 6 -F "$CORE" -framework PulseCore -framework Metal \
  -Xlinker -rpath -Xlinker "$PWD/$CORE" -o "$TOOL" Tools/spikes/gpu/main.swift

exec "$TOOL" "$@"
