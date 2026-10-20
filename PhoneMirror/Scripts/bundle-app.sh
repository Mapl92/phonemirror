#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds PhoneMirror (release) and packages the executable as an .app bundle in build/.
# Usage: Scripts/bundle-app.sh             → build/PhoneMirror.app (ad-hoc signed)
# Replay mode without a device:
#         swift run -c release hevc-test-stream /tmp/test.h265 4 1179 2556 collapse
#         open build/PhoneMirror.app --args -replay /tmp/test.h265
#
# Optional environment variables (used by Scripts/release.sh):
#   VERSION         CFBundleShortVersionString (default 0.2)
#   BUILD_NUMBER    CFBundleVersion (default: number of git commits, else 1)
#   SIGN_IDENTITY   codesign identity; default "-" (ad hoc)
#   HARDENED=1      sign with hardened runtime and secure timestamp (required for notarization)
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${VERSION:-0.2}
BUILD_NUMBER=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
SIGN_IDENTITY=${SIGN_IDENTITY:--}
HARDENED=${HARDENED:-0}

swift build -c release --product PhoneMirror
BIN_DIR=$(swift build -c release --show-bin-path)

APP=build/PhoneMirror.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PhoneMirror" "$APP/Contents/MacOS/PhoneMirror"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/ddi-hints.json "$APP/Contents/Resources/ddi-hints.json"
# Sparkle (automatic updates) – the framework sits next to the binary's @rpath.
mkdir -p "$APP/Contents/Frameworks"
SPARKLE=$(find .build/artifacts -path "*macos-arm64_x86_64/Sparkle.framework" -maxdepth 6 | head -1)
[[ -n "$SPARKLE" ]] || { echo "Sparkle.framework not found – run: swift package resolve" >&2; exit 1; }
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PhoneMirror</string>
    <key>CFBundleIdentifier</key><string>local.phonemirror.PhoneMirror</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>PhoneMirror</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/Mapl92/phonemirror/main/appcast.xml</string>
    <key>SUPublicEDKey</key><string>jha3xGzOMBgK71aZCvsMcAf0f+xWkNm956cXX70kDa8=</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>NSHumanReadableCopyright</key><string>GPL-3.0-or-later · github.com/Mapl92/phonemirror</string>
</dict>
</plist>
PLIST

sign_args=(--force --sign "$SIGN_IDENTITY")
if [[ $HARDENED == 1 ]]; then
  sign_args+=(--options runtime)
  # A secure timestamp needs a real certificate; ad-hoc signatures can't carry one.
  [[ $SIGN_IDENTITY != - ]] && sign_args+=(--timestamp)
fi
# Inside out, as Sparkle documents it: its helpers first, then the framework, then the app.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
codesign "${sign_args[@]}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" >/dev/null
codesign "${sign_args[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" >/dev/null
codesign "${sign_args[@]}" "$FRAMEWORK/Versions/B/Autoupdate" >/dev/null
codesign "${sign_args[@]}" "$FRAMEWORK/Versions/B/Updater.app" >/dev/null
codesign "${sign_args[@]}" "$FRAMEWORK" >/dev/null
codesign "${sign_args[@]}" "$APP" >/dev/null
echo "$APP"
