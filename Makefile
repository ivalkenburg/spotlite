APP      := Spotlite
BUNDLE   := build/$(APP).app
BIN      := .build/release/$(APP)
# The first Apple Development certificate by its full name: the bare prefix is
# ambiguous when the keychain holds more than one. Ad-hoc ("-") when there is none.
# Override with `make IDENTITY="..."`.
IDENTITY ?= $(or $(shell security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $$2; exit}'),-)
SIGN_FLAGS ?= --timestamp=none

VERSION  := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DMG      := build/$(APP)-$(VERSION).dmg
# Distribution needs a Developer ID Application certificate, and a notarytool keychain
# profile stored once with `xcrun notarytool store-credentials spotlite`.
DEVELOPER_ID   ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $$2; exit}')
NOTARY_PROFILE ?= spotlite

.PHONY: all build bundle run clean install test dmg release cask

all: bundle

build:
	swift build -c release

bundle: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@codesign --force --sign "$(IDENTITY)" $(SIGN_FLAGS) --entitlements Resources/Spotlite.entitlements $(BUNDLE)
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

# A disk image with an Applications link to drag onto. Signed however `bundle` signs,
# so this alone is only fit for local testing; `release` produces the one to publish.
dmg: bundle
	@rm -rf build/dmg $(DMG)
	@mkdir -p build/dmg
	@cp -R $(BUNDLE) build/dmg/
	@ln -s /Applications build/dmg/Applications
	@# `diskutil image` replaces the deprecated `hdiutil create` but is new in macOS 26.
	@if diskutil image create from --help >/dev/null 2>&1; then \
		diskutil image create from --format UDZO --volumeName "$(APP)" build/dmg $(DMG) >/dev/null; \
	else \
		hdiutil create -volname "$(APP)" -srcfolder build/dmg -format UDZO -ov $(DMG) >/dev/null; \
	fi
	@rm -rf build/dmg
	@echo "built $(DMG)"

# Developer ID signature with the hardened runtime, then notarization, so Gatekeeper
# opens the download without a warning. The ticket is stapled to the disk image so
# that check also passes offline.
release:
	@test -n "$(DEVELOPER_ID)" || { echo "no Developer ID Application certificate in the keychain"; exit 1; }
	@$(MAKE) dmg IDENTITY="$(DEVELOPER_ID)" SIGN_FLAGS="--options runtime --timestamp"
	codesign --sign "$(DEVELOPER_ID)" --timestamp $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG)
	spctl --assess --type open --context context:primary-signature --verbose $(DMG)
	@shasum -a 256 $(DMG)

# Fills the cask template with this version and the disk image's checksum.
cask:
	@test -f $(DMG) || { echo "$(DMG) not found; run make release first"; exit 1; }
	@sed -e '1{/^#/d;}' -e 's/^  version ".*"/  version "$(VERSION)"/' \
	     -e "s/^  sha256 \".*\"/  sha256 \"$$(shasum -a 256 $(DMG) | cut -d' ' -f1)\"/" \
	     packaging/spotlite.rb > build/spotlite.rb
	@echo "wrote build/spotlite.rb"

clean:
	rm -rf .build build
