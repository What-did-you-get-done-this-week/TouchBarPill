#!/bin/bash
# Ad-hoc Release build without Xcode.app (Command Line Tools).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
run_policy_tests() {
	local sdk out
	sdk="$(xcrun --show-sdk-path)"
	out="$ROOT/build/policy-tests"
	mkdir -p "$ROOT/build"
	swiftc -sdk "$sdk" -target arm64-apple-macos12.0 \
		-framework CoreGraphics -framework Foundation \
		"$ROOT/TouchBarPill/ZonePolicy.swift" "$ROOT/Tests/policy-tests.swift" \
		-o "$out"
	"$out"
}
if [[ "${1:-}" == "test" ]]; then
	run_policy_tests
	exit 0
fi
SDK="$(xcrun --show-sdk-path)"
SRC="$ROOT/TouchBarPill"
APP="$ROOT/build/TouchBarPill.app"
MACOS="$APP/Contents/MacOS"
RES="$APP/Contents/Resources"
OBJ="$ROOT/build/obj"
mkdir -p "$OBJ" "$MACOS" "$RES/en.lproj" "$RES/es.lproj"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>es</string>
	</array>
	<key>CFBundleDisplayName</key>
	<string>TouchBarPill</string>
	<key>CFBundleExecutable</key>
	<string>TouchBarPill</string>
	<key>CFBundleIdentifier</key>
	<string>com.touchbarpill.TouchBarPill</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>TouchBarPill</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.5.2</string>
	<key>CFBundleVersion</key>
	<string>19</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<key>LSMultipleInstancesProhibited</key>
	<true/>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
</dict>
</plist>
PLIST
run_policy_tests

printf 'APPL????' > "$APP/Contents/PkgInfo"
cp "$SRC/en.lproj/Localizable.strings" "$RES/en.lproj/"
cp "$SRC/es.lproj/Localizable.strings" "$RES/es.lproj/"

clang -c -fobjc-arc -fmodules -mmacosx-version-min=12.0 -isysroot "$SDK" -I"$SRC" \
  "$SRC/DFRMirror.m" -o "$OBJ/DFRMirror.o"

swiftc -sdk "$SDK" -target arm64-apple-macos12.0 -O -whole-module-optimization \
  -import-objc-header "$SRC/TouchBarPill-Bridging-Header.h" -I"$SRC" \
  -framework AppKit -framework QuartzCore -framework CoreImage \
  -framework IOSurface -framework ImageIO -framework CoreGraphics \
  -framework ServiceManagement -framework Foundation -framework CoreAudio \
  "$SRC/main.swift" "$SRC/AppDelegate.swift" "$SRC/L10n.swift" \
  "$SRC/LaunchAtLogin.swift" "$SRC/Placement.swift" \
  "$SRC/FocusSession.swift" "$SRC/FullscreenWatcher.swift" \
  "$SRC/SystemVolume.swift" "$SRC/ZonePolicy.swift" \
  "$SRC/PillPanelController.swift" \
  "$SRC/TouchBarStreamView.swift" "$OBJ/DFRMirror.o" \
  -o "$MACOS/TouchBarPill"

codesign --force --deep --sign - --entitlements "$SRC/TouchBarPill.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString) ($(defaults read "$APP/Contents/Info.plist" CFBundleVersion))"
