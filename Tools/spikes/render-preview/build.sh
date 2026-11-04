#!/bin/sh
# Build after `make build`. Usage: Tools/spikes/render-preview/build.sh <output binary>
P=build/Build/Products/Debug
swiftc -parse-as-library -swift-version 6 -F "$P" -framework PulseCore -Xlinker -rpath -Xlinker "$PWD/$P" -o "$1" \
  Tools/spikes/render-preview/main.swift Pulse/App/LiveModel.swift Pulse/Features/MenuBar/StatusItemRenderer.swift \
  Pulse/Features/Panels/*.swift
