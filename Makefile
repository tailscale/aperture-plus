# Top-level Makefile for Aperture.
#
#   make            build everything from scratch (libtailscale + app for sim)
#   make test       build, then run the UI tests on the simulator
#   make ipa        archive + export a dev-signed .ipa for a real device
#   make look       screenshot the booted sim + describe it with a vision sub-pi
#   make clean      remove app build artifacts (not the libtailscale submodule)
#
# The libtailscale build needs Go 1.26.3 and the iOS SDK; the app build needs
# Xcode 26.x. Both are slow the first time. `make` skips re-running the
# libtailscale build if the xcframework already exists.

# ----- config -----
PROJECT      := Aperture.xcodeproj
SCHEME       := Aperture
CONFIG       := Debug
SIM_NAME     ?= iPhone 17
DERIVED      := build/DerivedData

XCFRAMEWORK  := ThirdParty/libtailscale/swift/build/Build/Products/Release-iphonefat/TailscaleKit.xcframework
# Rebuild the generated framework when a tracked libtailscale source changes.
# Depending only on the xcframework's existence silently packaged stale native
# code into new archives (especially dangerous for local submodule edits).
LIBTSCALE_SOURCES := $(shell git -C ThirdParty/libtailscale ls-files '*.go' '*.c' '*.h' 'swift/TailscaleKit/*.swift' 'swift/TailscaleKit/**/*.swift' | sed 's|^|ThirdParty/libtailscale/|')
LIBTSCALEDIR := ThirdParty/libtailscale/swift

# Device IPA build (see `make ipa`). Archive + export live under build/.
ARCHIVE      := build/Aperture.xcarchive
IPA_DIR      := build/ipa
EXPORT_OPTS  := ExportOptions.plist

# Pipe xcodebuild through xcpretty if installed, else cat. Use pipefail so a
# failed xcodebuild isn't masked by the prettifier's exit status (matches the
# libtailscale Makefile's approach).
XCPRETTIFIER := xcpretty
ifeq (, $(shell which $(XCPRETTIFIER)))
	XCPRETTIFIER := cat
endif
XCB := set -o pipefail; xcodebuild

# ----- default -----
.PHONY: all
all: framework app  ## Build the libtailscale xcframework and the app for the simulator

.PHONY: test-lock-resume
test-lock-resume: framework  ## Background + genuinely freeze app process; assert prompt resume
	scripts/test-lock-resume.sh

# ----- libtailscale -----
.PHONY: framework
framework: $(XCFRAMEWORK)  ## Build TailscaleKit.xcframework (skipped if it exists)

$(XCFRAMEWORK): $(LIBTSCALE_SOURCES)
	@echo
	@echo "::: Building TailscaleKit.xcframework (libtailscale submodule) :::"
	@echo "(needs Go 1.26.3; slow the first time)"
	cd $(LIBTSCALEDIR) && make ios-fat

# ----- app -----
.PHONY: app
app: framework  ## Build the Aperture app for the simulator
	@echo
	@echo "::: Building Aperture for $(SIM_NAME) simulator :::"
	$(XCB) build \
		-project $(PROJECT) -scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-destination 'platform=iOS Simulator,name=$(SIM_NAME)' \
		-derivedDataPath $(DERIVED) | $(XCPRETTIFIER)

# ----- device ipa (real device install) -----
.PHONY: ipa
ipa: framework  ## Archive + export a dev-signed .ipa for a real iOS device
	@./scripts/unlock-keychain.sh
	@echo
	@echo "::: Archiving Aperture for generic iOS (Release) :::"
	@echo "(needs a valid signing identity + provisioning profile for team W5364U7YZB;"
	@echo " the login keychain must be unlocked — unlock-keychain.sh above prompts"
	@echo " interactively if it's locked, or aborts if stdin isn't a terminal)"
	$(XCB) archive \
		-project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath $(ARCHIVE) \
		-derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates | $(XCPRETTIFIER)
	@echo
	@echo "::: Exporting dev-signed IPA → $(IPA_DIR)/ :::"
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE) \
		-exportPath $(IPA_DIR) \
		-exportOptionsPlist $(EXPORT_OPTS) \
		-allowProvisioningUpdates
	@echo
	@echo "✅ IPA: $$(ls -1 $(IPA_DIR)/*.ipa 2>/dev/null | head -1)"
	@echo "Install on a plugged-in device with Xcode locally:"
	@echo "  xcrun devicectl device install app --device <udid-or-name> $(IPA_DIR)/Aperture.ipa"

# ----- TestFlight / App Store -----
# App Store distribution export uses a SEPARATE options plist so that the
# existing `make ipa` (dev-signed real-device installs) keeps using the
# debugging method. Requires an Apple Distribution signing identity + an
# App Store provisioning profile for team W5364U7YZB (automatic signing will
# fetch the profile via -allowProvisioningUpdates if the identity exists and
# the Developer Portal session is valid).
IPA_APPSTORE_DIR     := build/ipa-appstore
EXPORT_OPTS_APPSTORE := ExportOptions.AppStore.plist
# Optional env file sourced for App Store Connect upload creds (API key or
# Apple ID). Defaults to ~/.aperture-testflight.env; override with
# APERTURE_TF_ENV=/path/to/file. See scripts/tf-check-creds.sh and
# README.testflight.md. Creds may also be provided as real env vars or on the
# make command line (ASC_KEY_ID=... ASC_ISSUER_ID=...). `make tf` checks for
# creds up front via tf-check-creds and fails fast before archiving.
APERTURE_TF_ENV      ?= $(HOME)/.aperture-testflight.env

# TestFlight build number (CFBundleVersion / CURRENT_PROJECT_VERSION) is
# DERIVED FROM GIT, not stored in the repo — same principle as the main
# Tailscale app, which computes its build number from git via mkversion's
# changeCount (see tailscale.com/version/mkversion) instead of bookkeeping a
# counter. We use the total reachable commit count (git rev-list --count
# HEAD): monotonically increasing, identical across fresh clones, and unique
# per commit, so every commit yields a fresh upload-able build number with
# zero state to maintain. Override with BUILD_NUMBER=N only if you need to
# (e.g. re-upload the same commit, or adopt a different scheme).
ifndef BUILD_NUMBER
  BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null)
endif
BUILD_NUM_FLAG :=
ifneq ($(strip $(BUILD_NUMBER)),)
  BUILD_NUM_FLAG := CURRENT_PROJECT_VERSION=$(BUILD_NUMBER)
endif

.PHONY: tf-check-creds
tf-check-creds:  ## Check ASC upload creds are available; fail fast w/ instructions
	@APERTURE_TF_ENV="$(APERTURE_TF_ENV)" ./scripts/tf-check-creds.sh

.PHONY: tf-archive
tf-archive: framework  ## Archive a Release build for App Store / TestFlight
	@./scripts/unlock-keychain.sh
	@echo
	@echo "::: Archiving Aperture for App Store distribution (Release) :::"
	$(XCB) archive \
		-project $(PROJECT) -scheme $(SCHEME) \
		-configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath $(ARCHIVE) \
		-derivedDataPath $(DERIVED) \
		-allowProvisioningUpdates $(BUILD_NUM_FLAG) | $(XCPRETTIFIER)

.PHONY: tf-export
tf-export:  ## Export an App Store .ipa from build/Aperture.xcarchive -> build/ipa-appstore/
	@./scripts/unlock-keychain.sh
	@echo
	@echo "::: Exporting App Store IPA -> $(IPA_APPSTORE_DIR)/ :::"
	rm -rf $(IPA_APPSTORE_DIR)
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE) \
		-exportPath $(IPA_APPSTORE_DIR) \
		-exportOptionsPlist $(EXPORT_OPTS_APPSTORE) \
		-allowProvisioningUpdates
	@echo
	@echo "✅ App Store IPA: $$(ls -1 $(IPA_APPSTORE_DIR)/*.ipa 2>/dev/null | head -1)"

# altool auth: prefer an App Store Connect API key (ASC_KEY_ID + ASC_ISSUER_ID;
# key file at ~/private_keys/AuthKey_<ASC_KEY_ID>.p8, or override its path with
# ASC_KEY_PATH). Else Apple ID + an app-specific password (ASC_USERNAME +
# ASC_PASSWORD — the password is an app-specific one from appleid.apple.com,
# NOT the account login password). Uploads also require the Paid Applications
# Agreement to be signed in App Store Connect and an app record to exist for
# io.tailscale.Aperture (auto-created on first successful upload).
.PHONY: tf-validate
tf-validate:  ## Validate the App Store .ipa with altool (needs ASC_* creds)
	@IPATH=$$(ls -1 $(IPA_APPSTORE_DIR)/*.ipa 2>/dev/null | head -1); \
	[ -n "$$IPATH" ] || { echo "❌ No IPA in $(IPA_APPSTORE_DIR)/ — run 'make tf-archive tf-export' first."; exit 1; }; \
	[ -f "$(APERTURE_TF_ENV)" ] && { set -a; . "$(APERTURE_TF_ENV)"; set +a; }; \
	APERTURE_TF_ENV="$(APERTURE_TF_ENV)" ./scripts/tf-check-creds.sh; \
	if [ -n "$$ASC_KEY_ID" ] && [ -n "$$ASC_ISSUER_ID" ]; then \
	  AUTH="--apiKey $$ASC_KEY_ID --apiIssuer $$ASC_ISSUER_ID"; \
	  [ -n "$$ASC_KEY_PATH" ] && AUTH="$$AUTH --apiKey-key-path $$ASC_KEY_PATH"; \
	else \
	  AUTH="--username $$ASC_USERNAME --password $$ASC_PASSWORD"; \
	fi; \
	echo "Validating $$IPATH ..."; \
	xcrun altool --validate-app -f "$$IPATH" -t ios $$AUTH

.PHONY: tf-upload
tf-upload:  ## Upload the App Store .ipa to App Store Connect (TestFlight)
	@IPATH=$$(ls -1 $(IPA_APPSTORE_DIR)/*.ipa 2>/dev/null | head -1); \
	[ -n "$$IPATH" ] || { echo "❌ No IPA in $(IPA_APPSTORE_DIR)/ — run 'make tf-archive tf-export' first."; exit 1; }; \
	[ -f "$(APERTURE_TF_ENV)" ] && { set -a; . "$(APERTURE_TF_ENV)"; set +a; }; \
	APERTURE_TF_ENV="$(APERTURE_TF_ENV)" ./scripts/tf-check-creds.sh; \
	if [ -n "$$ASC_KEY_ID" ] && [ -n "$$ASC_ISSUER_ID" ]; then \
	  AUTH="--apiKey $$ASC_KEY_ID --apiIssuer $$ASC_ISSUER_ID"; \
	  [ -n "$$ASC_KEY_PATH" ] && AUTH="$$AUTH --apiKey-key-path $$ASC_KEY_PATH"; \
	else \
	  AUTH="--username $$ASC_USERNAME --password $$ASC_PASSWORD"; \
	fi; \
	echo "Uploading $$IPATH to App Store Connect ..."; \
	xcrun altool --upload-app -f "$$IPATH" -t ios $$AUTH --output-format json

.PHONY: tf
tf:  ## Archive -> export -> upload to TestFlight (fails fast if no ASC creds)
	@APERTURE_TF_ENV="$(APERTURE_TF_ENV)" ./scripts/tf-check-creds.sh
	@$(MAKE) --no-print-directory tf-archive
	@$(MAKE) --no-print-directory tf-export
	@$(MAKE) --no-print-directory tf-upload

# ----- test -----
# An auth key automates login on a fresh sim so the connected tests run.
# Resolution order: `make test AUTHKEY=...` > APERTURE_TEST_AUTHKEY env >
# ~/.aperture-ios-authkey. Without any of these, connected tests FAIL (they no
# longer skip) — a broken connection must be loud, not silently green.
# ----- split-tunnel policy unit tests (host-only, ~2s) -----
# Compiles the real TSNet/TailnetProxyPolicy.swift against stubs and asserts the
# routing rules: tailnet hosts proxied, public hosts DIRECT. No xcframework, no
# simulator, no signing. See scripts/proxy-semantics/ for how the expectations
# were measured against a real SOCKS proxy.
.PHONY: test-policy
test-policy:  ## Run the split-tunnel routing unit tests (fast, host-only)
	@./scripts/test-proxy-policy.sh

.PHONY: test
test: test-policy all  ## Build, then run the UI tests on the simulator (with log capture)
	@echo
	@echo "::: Running UI tests on $(SIM_NAME) :::"
	@if [ -n "$(AUTHKEY)" ]; then \
	    APERTURE_TEST_AUTHKEY='$(AUTHKEY)' ./scripts/run-uitests.sh "$(SIM_NAME)"; \
	else \
	    ./scripts/run-uitests.sh "$(SIM_NAME)"; \
	fi

# ----- crash-capture + symbolication test (real Go abort) -----
# Verifies the experiment end-to-end: a deliberate Go runtime panic aborts the
# app, the panic+stack is captured to stderr.log in the container, and a
# TailscaleKit frame in the Apple crash report symbolicates via the dSYM to a
# named Go function + file:line. Uses mode 0 (real SIGABRT); the non-aborting
# mode-2 capture/surface path is covered by the UI test above. See
# TSNet/CrashCapture.swift and scripts/run-crashtest.sh.
.PHONY: crashtest
crashtest: app  ## Build, then verify Go panic capture + dSYM symbolication via a real abort
	@echo
	@echo "::: Running crash-capture + symbolication test on $(SIM_NAME) :::"
	./scripts/run-crashtest.sh "$(SIM_NAME)"

# ----- vision helper (manual / for debugging) -----
.PHONY: look
look:  ## Screenshot the booted sim + describe it with a vision sub-pi (ask Q=...)
	./scripts/look.sh "$(Q)"

# ----- clean -----
.PHONY: clean
clean:  ## Remove app build artifacts (keeps the libtailscale xcframework)
	@echo "::: Cleaning app build artifacts :::"
	rm -rf $(DERIVED) $(ARCHIVE) $(IPA_DIR)

.PHONY: clean-all
clean-all: clean  ## Also remove the libtailscale build artifacts (xcframework etc.)
	cd $(LIBTSCALEDIR) && make clean

# ----- help -----
.PHONY: help
help:  ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-][a-zA-Z0-9_-]*:.*##/ {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := all
