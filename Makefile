# Top-level Makefile for Aperture.
#
#   make            build everything from scratch (libtailscale + app for sim)
#   make test       build, then run the UI tests on the simulator
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
LIBTSCALEDIR := ThirdParty/libtailscale/swift

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

# ----- libtailscale -----
.PHONY: framework
framework: $(XCFRAMEWORK)  ## Build TailscaleKit.xcframework (skipped if it exists)

$(XCFRAMEWORK):
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

# ----- test -----
.PHONY: test
test: all  ## Build, then run the UI tests on the simulator (with log capture)
	@echo
	@echo "::: Running UI tests on $(SIM_NAME) :::"
	./scripts/run-uitests.sh --no-build "$(SIM_NAME)"

# ----- vision helper (manual / for debugging) -----
.PHONY: look
look:  ## Screenshot the booted sim + describe it with a vision sub-pi (ask Q=...)
	./scripts/look.sh "$(Q)"

# ----- clean -----
.PHONY: clean
clean:  ## Remove app build artifacts (keeps the libtailscale xcframework)
	@echo "::: Cleaning app build artifacts :::"
	rm -rf $(DERIVED)

.PHONY: clean-all
clean-all: clean  ## Also remove the libtailscale build artifacts (xcframework etc.)
	cd $(LIBTSCALEDIR) && make clean

# ----- help -----
.PHONY: help
help:  ## Show this help
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-][a-zA-Z0-9_-]*:.*##/ {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.DEFAULT_GOAL := all
