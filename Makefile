APP_NAME := Temple
APP := dist/$(APP_NAME).app
DEST := /Applications/$(APP_NAME).app

.PHONY: build test run demo demo-clean ghostty app open install stage release version clean

build: ## Compile the SwiftPM targets
	swift build

test: ## Run the full test suite
	swift test

run: ## Run the app straight from SwiftPM (dev loop; stub-free ghostty build required)
	swift run temple

demo: build ## Run against a fake session store (screenshots, demos — no real projects)
	@./Scripts/demo-data.py
	@TEMPLE_CLAUDE_ROOT=/private/tmp/temple-demo/claude-store \
	 TEMPLE_CODEX_ROOT=/private/tmp/temple-demo/codex-store \
	 TEMPLE_STATE_DIR=/private/tmp/temple-demo/state \
	 .build/debug/temple

demo-clean: ## Remove the demo store, demo state, and any sessions it created
	@rm -rf /private/tmp/temple-demo
	@rm -rf ~/.claude/projects/-private-tmp-temple-demo-projects-*
	@echo "✓ demo data removed"

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

stage: app ## Install to /Applications WITHOUT killing the running app (relaunch picks it up)
	@# For working from a terminal that lives inside Temple itself: the running
	@# instance keeps its bundle — moved to the Trash intact (its open files
	@# stay valid, and it doubles as the rollback) — never deleted under it.
	@if [ -d "$(DEST)" ]; then \
	  mv "$(DEST)" "$$HOME/.Trash/$(APP_NAME).app.replaced-$$(date +%Y%m%d-%H%M%S)"; \
	fi
	@ditto "$(APP)" "$(DEST)"
	@# Same LaunchServices hygiene as `install` (see comments there).
	@rm -rf "$(APP)"
	@"$(LSREGISTER)" -f "$(DEST)" 2>/dev/null || true
	@codesign --verify --strict "$(DEST)" \
	  && echo "✓ staged → $(DEST) — running app untouched; quit + reopen to pick it up"

release: ## Build, sign, notarize, package, and publish a GitHub release (VERSION=v0.1.0; see RELEASE.md)
	@test -n "$(VERSION)" || (echo "usage: make release VERSION=v0.1.0" && exit 1)
	VERSION=$(VERSION) ./Scripts/release.sh

version: ## What is released, what users get, and what is waiting to ship
	@echo "released:   $$(git tag -l 'v*' --sort=-v:refname | head -3 | tr '\n' ' ')"
	@echo "published:  $$(gh release list --limit 3 --json tagName,isDraft \
	    --jq '.[] | .tagName + (if .isDraft then " (draft)" else "" end)' 2>/dev/null | tr '\n' ' ')"
	@echo "on brew:    $$(brew info --cask ramsrib/tap/temple 2>/dev/null | head -1 | sed 's/.*: //')"
	@echo "installed:  $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
	    /Applications/Temple.app/Contents/Info.plist 2>/dev/null || echo 'not installed')"
	@last=$$(git tag -l 'v*' --sort=-v:refname | head -1); \
	  n=$$(git log --oneline $$last..HEAD 2>/dev/null | wc -l | tr -d ' '); \
	  echo "unreleased: $$n commits since $$last"; \
	  git log --oneline $$last..HEAD 2>/dev/null | sed 's/^/              /'

clean: ## Remove build artifacts (keeps Vendor/)
	rm -rf .build dist Temple.xcodeproj
