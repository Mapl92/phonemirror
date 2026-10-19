#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds PhoneMirror (release) and packages the executable as an .app bundle in build/.
# Usage: Scripts/bundle-app.sh             → build/PhoneMirror.app
# Replay mode without a device:
#         swift run -c release hevc-test-stream /tmp/test.h265 4 1179 2556 collapse
#         open build/PhoneMirror.app --args -replay /tmp/test.h265
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product PhoneMirror
BIN_DIR=$(swift build -c release --show-bin-path)

APP=build/PhoneMirror.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PhoneMirror" "$APP/Contents/MacOS/PhoneMirror"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>PhoneMirror</string>
    <key>CFBundleIdentifier</key><string>local.phonemirror.PhoneMirror</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleName</key><string>PhoneMirror</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign -s - -f "$APP" >/dev/null
echo "$APP"
