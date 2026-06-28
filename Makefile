# openTihui — build the llama.cpp xcframework, then the iOS app.
#
#   make            # build framework (if missing) + app for the Simulator
#   make framework  # (re)build the llama.cpp xcframework into Frameworks/
#   make app        # build the app (reuses the existing xcframework)
#   make run        # build + install + launch in the Simulator
#   make clean      # clean app build artifacts
#   make distclean  # also remove the xcframework + llama.cpp build dirs
#
# Overrides:  make app CONFIG=Release DEST='platform=iOS,name=My iPhone'

PROJECT      := openTihui.xcodeproj
SCHEME       := openTihui
BUNDLE_ID    := org.cyyself.opentihui
XCFRAMEWORK  := Frameworks/llama.xcframework
DERIVED      := build
CONFIG       ?= Debug
DEST         ?= platform=iOS Simulator,name=iPhone 17 Pro
ICON_PNG     := src/openTihui/Assets.xcassets/AppIcon.appiconset/AppIcon.png

.PHONY: all framework app run clean distclean submodule icon

all: app

# --- llama.cpp xcframework -------------------------------------------------

submodule:
	@if [ ! -f llama.cpp/build-xcframework.sh ]; then \
		echo "Fetching llama.cpp submodule"; \
		git submodule update --init --depth 1 llama.cpp; \
	fi

# Builds only when the xcframework is missing. Use `make framework` to force.
$(XCFRAMEWORK): | submodule
	@echo "Building llama.cpp xcframework (iOS device + simulator, incl. libmtmd)"
	cd llama.cpp && bash ../scripts/build-llama-ios.sh
	mkdir -p Frameworks
	rm -rf $(XCFRAMEWORK)
	cp -R llama.cpp/build-apple/llama.xcframework Frameworks/

framework:
	rm -rf $(XCFRAMEWORK)
	$(MAKE) $(XCFRAMEWORK)

# --- app icon --------------------------------------------------------------
# Regenerate the 1024px app-icon PNG from the TikZ source (design/AppIcon.tex).
# Needs a LaTeX toolchain (pdflatex) + poppler (pdftoppm).
icon:
	@command -v pdflatex >/dev/null || { echo "pdflatex not found (install MacTeX/BasicTeX)"; exit 1; }
	@command -v pdftoppm >/dev/null || { echo "pdftoppm not found (brew install poppler)"; exit 1; }
	cd design && pdflatex -interaction=nonstopmode -halt-on-error AppIcon.tex >/dev/null
	pdftoppm -png -r 520 design/AppIcon.pdf design/AppIcon-hi >/dev/null
	sips -z 1024 1024 design/AppIcon-hi-1.png --out "$(ICON_PNG)" >/dev/null
	rm -f design/AppIcon-hi-1.png design/AppIcon.aux design/AppIcon.log design/AppIcon.pdf
	@echo "Wrote $(ICON_PNG)"

# --- app -------------------------------------------------------------------

app: $(XCFRAMEWORK)
	@echo "Building $(SCHEME) ($(CONFIG))"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-sdk iphonesimulator -destination '$(DEST)' \
		-derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO build

run: app
	xcrun simctl install booted "$(DERIVED)/Build/Products/$(CONFIG)-iphonesimulator/$(SCHEME).app"
	xcrun simctl launch booted $(BUNDLE_ID)

# --- cleaning --------------------------------------------------------------

clean:
	rm -rf $(DERIVED) build-release
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean >/dev/null 2>&1 || true

distclean: clean
	rm -rf $(XCFRAMEWORK) \
		llama.cpp/build-apple llama.cpp/build-ios-sim llama.cpp/build-ios-device
