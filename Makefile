# Uses tools from PATH when installed; otherwise fetches them through Nix.
XCODEGEN  := $(shell command -v xcodegen 2>/dev/null || echo 'nix run nixpkgs\#xcodegen --')
SWIFTLINT := $(shell command -v swiftlint 2>/dev/null || echo 'nix run nixpkgs\#swiftlint --')

DERIVED     := build
DESTINATION := platform=macOS,arch=arm64
APP         := $(DERIVED)/Build/Products/Debug/Pulse.app

.PHONY: generate build test run lint clean cli

generate:
	$(XCODEGEN) generate --quiet

build: generate
	xcodebuild -scheme Pulse -configuration Debug -destination '$(DESTINATION)' -derivedDataPath $(DERIVED) build

test: generate
	xcodebuild test -scheme PulseCoreTests -destination '$(DESTINATION)' -derivedDataPath $(DERIVED)

run: build
	@pkill -x Pulse || true
	open $(APP)

# Prints current metrics with the command-line tool built into Pulse.app. Pass options with
# ARGS, for example: make cli ARGS="--prometheus".
cli: build
	$(APP)/Contents/MacOS/pulse-cli $(ARGS)

lint:
	$(SWIFTLINT) lint --quiet

clean:
	rm -rf $(DERIVED) Pulse.xcodeproj
