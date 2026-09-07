APP      := Spotlite
BUNDLE   := build/$(APP).app
BIN      := .build/release/$(APP)
IDENTITY ?= Apple Development

.PHONY: all build bundle sign run clean install test

all: bundle

build:
	swift build -c release

bundle: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@codesign --force --sign "$(IDENTITY)" --timestamp=none $(BUNDLE)
	@echo "built $(BUNDLE)"

run: bundle
	@pkill -x $(APP) || true
	@open $(BUNDLE)

# SMAppService registers an absolute path, so autostart is only offered
# once the bundle lives at its final location.
install: bundle
	@rm -rf /Applications/$(APP).app
	@cp -R $(BUNDLE) /Applications/
	@echo "installed to /Applications/$(APP).app"

test:
	swift test

clean:
	rm -rf .build build
