PROJECT := MacCam.xcodeproj
SCHEME  := MacCam
DERIVED := build
RELEASE_APP := $(DERIVED)/Build/Products/Release/MacCam.app
DEST := /Applications/MacCam.app

DEST_PLATFORM := -destination 'platform=macOS'

.PHONY: build test lint install dmg clean

## Build the Release app
build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-derivedDataPath $(DERIVED) $(DEST_PLATFORM) build

## Run the unit + integration test suite
test:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-derivedDataPath $(DERIVED) $(DEST_PLATFORM) test

## Lint (no-op if SwiftLint isn't installed)
lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint --strict; \
	else \
		echo "swiftlint not installed — skipping (brew install swiftlint)"; \
	fi

## Build Release and install to /Applications
install: build
	rm -rf "$(DEST)"
	cp -R "$(RELEASE_APP)" "$(DEST)"
	@echo "Installed to $(DEST)"

## Build a distributable DMG into dist/
dmg: build
	./scripts/make-dmg.sh "$(RELEASE_APP)"

clean:
	rm -rf $(DERIVED) dist
