APP_NAME := Temple
APP := dist/$(APP_NAME).app
DEST := /Applications/$(APP_NAME).app

.PHONY: build test run ghostty app open install release clean

build: ## Compile the SwiftPM targets
	swift build

test: ## Run the full test suite
	swift test

run: ## Run the app straight from SwiftPM (dev loop; stub-free ghostty build required)
	swift run temple

ghostty: ## Build Vendor/GhosttyKit.xcframework (one-time; pins zig + ghostty)
	./Scripts/build-ghostty.sh

app: ## Build the signed dist/Temple.app (xcodegen + xcodebuild + ghostty resources)
	./Scripts/build-app.sh

open: app ## Build then launch the .app
	open "$(APP)"

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

install: app ## Build, sign, and install to /Applications
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 1
	@rm -rf "$(DEST)"
	@ditto "$(APP)" "$(DEST)"
	@# Remove the dist copy: two bundles with the same id at different paths each
	@# register with LaunchServices, letting a second instance launch.
	@rm -rf "$(APP)"
	@# Make /Applications the canonical handler (and drop the stale dist/ entry).
	@"$(LSREGISTER)" -f "$(DEST)" 2>/dev/null || true
	@codesign --verify --strict "$(DEST)" && echo "✓ installed → $(DEST)"

release: ## Build, sign, notarize, package, and publish a GitHub release (VERSION=v0.1.0; see RELEASE.md)
	@test -n "$(VERSION)" || (echo "usage: make release VERSION=v0.1.0" && exit 1)
	VERSION=$(VERSION) ./Scripts/release.sh

clean: ## Remove build artifacts (keeps Vendor/)
	rm -rf .build dist Temple.xcodeproj
