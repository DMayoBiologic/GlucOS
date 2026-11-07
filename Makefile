# GlucOS — build & release helpers.
#
#   make                  build locally (ad-hoc signed), install to /Applications, launch
#   make sparkle-keys     one-time: generate Sparkle EdDSA keys, set repo secret, commit public key
#   make release V=0.2.0  bump version, tag, push → GitHub Actions builds & publishes the release
#   make install-release  install the latest GitHub release (what auto-updates will deliver)
#   make open             open the generated project in Xcode

PROJECT   := GlucOS.xcodeproj
SCHEME    := GlucOS
BUILD_DIR := build
APP       := $(BUILD_DIR)/Build/Products/Release/GlucOS.app
REPO      := DMayoBiologic/GlucOS
SPARKLE_BIN = $(shell find $(BUILD_DIR)/SourcePackages/artifacts -type d -path '*Sparkle/bin' 2>/dev/null | head -1)

.PHONY: all generate resolve build install run open sparkle-keys release install-release doctor clean

all: build install run

generate:
	@command -v xcodegen >/dev/null 2>&1 || { echo "Installing xcodegen via Homebrew…"; brew install xcodegen; }
	xcodegen generate --spec project.yml

resolve: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -derivedDataPath $(BUILD_DIR) \
	  -resolvePackageDependencies -skipPackagePluginValidation >/dev/null

build: generate
	@set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -derivedDataPath $(BUILD_DIR) -skipPackagePluginValidation -skipMacroValidation build 2>&1 \
	  | grep -E "error:|BUILD" || true
	@test -d "$(APP)" || { echo "Build failed — run 'make open' to see errors in Xcode"; exit 1; }
	@echo "Built $(APP)"

install:
	@pkill -x GlucOS 2>/dev/null || true
	rm -rf /Applications/GlucOS.app
	cp -R "$(APP)" /Applications/GlucOS.app
	@echo "Installed /Applications/GlucOS.app"

run:
	open -a /Applications/GlucOS.app

open: generate
	open $(PROJECT)

## One-time Sparkle setup. Needs `gh auth login` done once.
sparkle-keys: resolve
	@test -n "$(SPARKLE_BIN)" || { echo "Sparkle tools not found after resolve"; exit 1; }
	@command -v gh >/dev/null 2>&1 || { echo "Installing GitHub CLI…"; brew install gh; }
	@gh auth status >/dev/null 2>&1 || gh auth login
	@"$(SPARKLE_BIN)/generate_keys" >/dev/null 2>&1 || true
	@PUB=$$("$(SPARKLE_BIN)/generate_keys" -p); \
	 TMP=$$(mktemp); "$(SPARKLE_BIN)/generate_keys" -x "$$TMP"; \
	 gh secret set SPARKLE_PRIVATE_KEY -R $(REPO) < "$$TMP"; rm -f "$$TMP"; \
	 gh variable set SPARKLE_PUBLIC_ED_KEY -R $(REPO) --body "$$PUB"; \
	 sed -i '' -E "s|SPARKLE_PUBLIC_ED_KEY: \"[^\"]*\"|SPARKLE_PUBLIC_ED_KEY: \"$$PUB\"|" project.yml; \
	 git add project.yml; git commit -m "Add Sparkle public key" >/dev/null 2>&1 || true; git push; \
	 echo "Sparkle public key: $$PUB"; \
	 echo "Private key is in your login Keychain (Sparkle) and in the repo secret SPARKLE_PRIVATE_KEY."

## Cut a release: make release V=0.2.0
release:
	@test -n "$(V)" || { echo "Usage: make release V=0.2.0"; exit 1; }
	@sed -i '' -E 's|MARKETING_VERSION: "[^"]*"|MARKETING_VERSION: "$(V)"|' project.yml
	git add project.yml
	git commit -m "Release $(V)" || true
	git tag -a "v$(V)" -m "GlucOS $(V)"
	git push && git push origin "v$(V)"
	@echo "Tagged v$(V). Watch: https://github.com/$(REPO)/actions"

## Install the latest published release (identical to what auto-update delivers).
install-release:
	@command -v gh >/dev/null 2>&1 || brew install gh
	@TMP=$$(mktemp -d); \
	 gh release download -R $(REPO) --pattern 'GlucOS-*.zip' -D "$$TMP" && \
	 ditto -x -k "$$TMP"/GlucOS-*.zip "$$TMP" && \
	 pkill -x GlucOS 2>/dev/null; rm -rf /Applications/GlucOS.app && \
	 cp -R "$$TMP/GlucOS.app" /Applications/GlucOS.app && \
	 xattr -dr com.apple.quarantine /Applications/GlucOS.app 2>/dev/null; \
	 rm -rf "$$TMP"; open -a /Applications/GlucOS.app; echo "Installed latest release."

doctor:
	@echo "Xcode:       $$(xcodebuild -version 2>/dev/null | head -1 || echo MISSING — install Xcode from the App Store)"
	@echo "xcodegen:    $$(command -v xcodegen || echo MISSING — make generate installs it)"
	@echo "gh:          $$(command -v gh || echo MISSING — needed for sparkle-keys/install-release)"
	@echo "Sparkle key: $$(grep -E 'SPARKLE_PUBLIC_ED_KEY:' project.yml | sed -E 's/.*\"([^\"]*)\".*/\1/' | sed 's/^$$/NOT SET — run make sparkle-keys/')"

clean:
	rm -rf $(BUILD_DIR) $(PROJECT)
