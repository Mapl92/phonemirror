#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Baut WebDriverAgent (Appium, BSD-Lizenz) einmalig für das gekoppelte iPhone und signiert es mit deinem Team.
# Aufruf: Scripts/build-wda.sh <Team-ID> [Bundle-ID-Präfix] [Version]
#   Team-ID: steht in Xcode › Settings › Accounts bzw. `security find-identity -p codesigning -v` (in Klammern).
# Ergebnis: ~/Library/Application Support/PhoneMirror/WDA/wda-build/Build/Products/*.xctestrun –
# PhoneMirror findet es dort automatisch (außerhalb von ~/Documents, sonst fragt macOS nach Ordnerzugriff).
set -euo pipefail
TEAM=${1:?Team-ID angeben}
PREFIX=${2:-local.phonemirror}
VERSION=${3:-v16.15.3}
VENDOR="${0:A:h}/../../Vendor"
mkdir -p "$VENDOR"
cd "$VENDOR"
if [[ ! -d WebDriverAgent ]]; then
  git clone --depth 1 --branch "$VERSION" https://github.com/appium/WebDriverAgent.git
fi
UDID=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')
[[ -n "$UDID" ]] || { echo "Kein verfügbares iPhone gefunden (entsperrt und gekoppelt?)"; exit 1; }
xcodebuild build-for-testing \
  -project WebDriverAgent/WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
  -destination "id=$UDID" -derivedDataPath "$HOME/Library/Application Support/PhoneMirror/WDA/wda-build" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER="$PREFIX.WebDriverAgentRunner" \
  | grep -E "error:|\*\* " || true
ls "$HOME/Library/Application Support/PhoneMirror/WDA/wda-build/Build/Products/"*.xctestrun
