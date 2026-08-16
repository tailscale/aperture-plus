# Copyright (c) Tailscale Inc & AUTHORS
# SPDX-License-Identifier: BSD-3-Clause

## Prettifies xcode output for xcode tests using xcpretty, if it is installed
XCPRETTIFIER := xcpretty
ifeq (, $(shell which $(XCPRETTIFIER)))
        XCPRETTIFIER := cat
endif

# xcodebuild is piped through $(XCPRETTIFIER); without pipefail, make would see
# the prettifier's (xcpretty/cat) exit status and treat a failed xcodebuild as
# success, leaving a hollow .framework and a confusing create-xcframework error.
# GNU make 3.81 (the default on macOS) predates .SHELLFLAGS, so set pipefail inline.
XCB = set -o pipefail; xcodebuild

# The xcodebuild schemes will run the Makefile in the root directory to build
# the libtailscale.a and libtailscale_ios.a dependencies.

.PHONY: all
all: test ios macos ios-fat  ## Runs the tests and builds all library targets

.PHONY: macos
macos:  ## Builds TailscaleKit for macos to swift/build/Build/Products/Release (unsigned)
	@echo
	@echo "::: Building TailscaleKit.framework for macOS :::"
	cd .. && make c-archive
	mkdir -p build
	$(XCB) build -scheme "TailscaleKit (macOS)" \
	 -derivedDataPath build \
	 -configuration Release \
	 -destination 'platform=macOS,arch=arm64' \
	 CODE_SIGNING_ALLOWED=NO | $(XCPRETTIFIER)

.PHONY: ios
ios:  ## Builds TailscaleKit for iOS to swift/build/Build/Products/Release-iphoneos (unsigned)
	@echo
	@echo "::: Building TailscaleKit.framework for iOS :::"
	cd .. && make c-archive-ios
	mkdir -p build
	$(XCB) build -scheme "TailscaleKit (iOS)" \
	 -derivedDataPath build \
	 -configuration Release \
	 -destination 'generic/platform=iOS' \
	 CODE_SIGNING_ALLOWED=NO | $(XCPRETTIFIER)

.PHONY: ios-sim
ios-sim:  ## Builds TailscaleKit for iOS to swift/build/Build/Products/Release-iphonesimulator (unsigned)
	@echo
	@echo "::: Building TailscaleKit.framework for iOS Simulator :::"
	cd .. && make c-archive-ios-sim
	mkdir -p build
	$(XCB) build -scheme "TailscaleKit (Simulator)" \
	 -derivedDataPath build \
	 -configuration Release \
	 -destination 'generic/platform=iOS Simulator' \
	 CODE_SIGNING_ALLOWED=NO | $(XCPRETTIFIER)

.PHONY: ios-fat
ios-fat: ios-sim ios ## Builds TailscaleKit.xcframework (with bundled dSYMs) to swift/build/Build/Products/Release-iphonefat
	@echo 
	@echo "::: Building TailscaleKit.xcframework for ios and ios-simulator :::"
	mkdir -p ./build/Build/Products/Release-iphonefat
	# -create-xcframework won't overwrite an existing bundle, and it does NOT
	# auto-discover adjacent .dSYM bundles — both must be handled explicitly.
	# Bundling the dSYMs here is what lets them flow into the app archive and
	# get uploaded to App Store Connect for TestFlight crash symbolication
	# (without them, every Go/TailscaleKit frame in a TestFlight crash log is
	# an unreadable "TailscaleKit + <offset>"). The dSYMs are produced by the
	# `ios`/`ios-sim` prerequisites via DEBUG_INFORMATION_FORMAT=dwarf-with-dsym.
	rm -rf ./build/Build/Products/Release-iphonefat/TailscaleKit.xcframework
	xcodebuild -create-xcframework \
		-framework ./build/Build/Products/Release-iphoneos/TailscaleKit.framework \
		-debug-symbols $(CURDIR)/build/Build/Products/Release-iphoneos/TailscaleKit.framework.dSYM \
		-framework ./build/Build/Products/Release-iphonesimulator/TailscaleKit.framework \
		-debug-symbols $(CURDIR)/build/Build/Products/Release-iphonesimulator/TailscaleKit.framework.dSYM \
		-output ./build/Build/Products/Release-iphonefat/TailscaleKit.xcframework

.PHONY: test
test: ## Run tests (macOS)
	@echo 
	@echo "::: Running tests for TailscaleKit :::"
	cd ../tstestcontrol && make all
	cd .. && make c-archive
	mkdir -p build
	xcodebuild build-for-testing -scheme TailscaleKitXCTests \
	 -derivedDataPath build \
	 -configuration Debug \
	 -quiet \
	 -destination 'platform=macOS,arch=arm64' \
	 CODE_SIGNING_ALLOWED=NO
	@set -e; \
	for test in \
	 testMessageReaderStartStopRaceDoesNotCrash \
	 testNotifyDecodesNodeWithOmittedZeroFields \
	 testVMNetworkBridgeLifecycleUsesExistingNode \
	 testProxy testStatus testV4 testV6; do \
	  echo "::: Running TailscaleKitTests/$$test in a fresh process :::"; \
	  xcodebuild test-without-building -scheme TailscaleKitXCTests \
	   -derivedDataPath build -configuration Debug \
	   -destination 'platform=macOS,arch=arm64' \
	   -parallel-testing-enabled NO \
	   -only-testing:TailscaleKitXCTests/TailscaleKitTests/$$test \
	   CODE_SIGNING_ALLOWED=NO || exit $$?; \
	done

.PHONY: clean
clean: ## Clean up build artifacts (including the libtailscale dependencies)
	cd .. && make clean
	rm -rf build 

.PHONY: help
help: ## Show this help
	@echo "\nSpecify a command. The choices are:\n"
	@grep -hE '^[0-9a-zA-Z_-]+:.*?## .*$$' ${MAKEFILE_LIST} | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[0;36m%-12s\033[m %s\n", $$1, $$2}'
	@echo ""

.DEFAULT_GOAL := help
