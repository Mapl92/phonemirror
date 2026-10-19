#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds WebDriverAgent (Appium, BSD license) once for the paired iPhone and signs it with your team.
# Usage: Scripts/build-wda.sh <Team-ID> [bundle-ID-prefix] [version]
#   Team ID: see Xcode › Settings › Accounts or `security find-identity -p codesigning -v` (in parentheses).
# Result: ~/Library/Application Support/PhoneMirror/WDA/wda-build/Build/Products/*.xctestrun –
# PhoneMirror finds it there automatically (outside ~/Documents, where macOS would prompt for folder access).
set -euo pipefail
TEAM=${1:?Pass your Team ID}
PREFIX=${2:-local.phonemirror}
VERSION=${3:-v16.15.3}
VENDOR="${0:A:h}/../../Vendor"
mkdir -p "$VENDOR"
cd "$VENDOR"
if [[ ! -d WebDriverAgent ]]; then
  git clone --depth 1 --branch "$VERSION" https://github.com/appium/WebDriverAgent.git
fi
UDID=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && /available/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) {print $i; exit}}')
[[ -n "$UDID" ]] || { echo "No available iPhone found (unlocked and paired?)"; exit 1; }
xcodebuild build-for-testing \
  -project WebDriverAgent/WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
  -destination "id=$UDID" -derivedDataPath "$HOME/Library/Application Support/PhoneMirror/WDA/wda-build" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic PRODUCT_BUNDLE_IDENTIFIER="$PREFIX.WebDriverAgentRunner" \
  | grep -E "error:|\*\* " || true
ls "$HOME/Library/Application Support/PhoneMirror/WDA/wda-build/Build/Products/"*.xctestrun
