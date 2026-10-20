#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds a signed, notarized and stapled PhoneMirror release (ZIP + DMG) and creates a draft GitHub release.
#
# Usage: Scripts/release.sh <version> [--dry-run] [--no-github]
#   <version>     e.g. 0.3 → tag v0.3, CFBundleShortVersionString 0.3
#   --dry-run     ad-hoc signature with hardened runtime, no notarization, no GitHub release
#                 (checks that the app still works under the hardened runtime)
#   --no-github   build, sign and notarize, but don't create the GitHub release
#
# One-time setup:
#   1. Developer ID Application certificate in the login keychain
#      (Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application).
#   2. notarytool credentials stored under the profile name below (default: phonemirror-notary):
#        xcrun notarytool store-credentials phonemirror-notary --apple-id <apple-id> --team-id <team-id>
#      (asks for an app-specific password from account.apple.com).
#   3. GitHub CLI logged in (`gh auth status`).
#
# Environment: NOTARY_PROFILE (default phonemirror-notary), SIGN_IDENTITY (default: first
# "Developer ID Application" identity found).
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${1:?Usage: Scripts/release.sh <version> [--dry-run] [--no-github]}
shift
DRY_RUN=0
GITHUB=1
for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=1; GITHUB=0 ;;
    --no-github) GITHUB=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
[[ $VERSION =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || { echo "Version must look like 0.3 or 1.0.1" >&2; exit 2; }

TAG="v$VERSION"
NOTARY_PROFILE=${NOTARY_PROFILE:-phonemirror-notary}
OUT=build/release
APP=build/PhoneMirror.app
ZIP="$OUT/PhoneMirror-$VERSION.zip"
DMG="$OUT/PhoneMirror-$VERSION.dmg"

step() { print -P "%F{cyan}==>%f $*"; }
fail() { print -P "%F{red}Error:%f $*" >&2; exit 1; }

# MARK: Preflight

step "Preflight"
if [[ $DRY_RUN == 1 ]]; then
  SIGN_IDENTITY="-"
else
  if [[ -z ${SIGN_IDENTITY:-} ]]; then
    # The SHA-1 hash avoids encoding issues with non-ASCII certificate names.
    SIGN_IDENTITY=$(security find-identity -p codesigning -v | awk '/"Developer ID Application: / {print $2; exit}')
  fi
  [[ -n $SIGN_IDENTITY ]] || fail "No \"Developer ID Application\" certificate found (see setup in this script)."
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notarytool profile \"$NOTARY_PROFILE\" missing or invalid (see setup in this script)."
fi
if [[ $GITHUB == 1 ]]; then
  gh auth status >/dev/null 2>&1 || fail "GitHub CLI is not logged in."
  [[ -z $(git status --porcelain) ]] || fail "Working tree has uncommitted changes."
  git fetch -q origin
  [[ $(git rev-parse HEAD) == $(git rev-parse '@{u}') ]] || fail "HEAD differs from its upstream – push first."
  gh release view "$TAG" >/dev/null 2>&1 && fail "Release $TAG already exists on GitHub."
fi
if [[ $DRY_RUN == 1 ]]; then
  echo "Version $VERSION, ad-hoc signature (dry run)"
else
  echo "Version $VERSION, identity: $(security find-identity -p codesigning -v | grep -F "$SIGN_IDENTITY" | sed -nE 's/.*"(.+)".*/\1/p' | head -1)"
fi

# MARK: Build, test, sign

step "Running tests"
TEST_LOG=$(mktemp)
swift test >"$TEST_LOG" 2>&1 || { tail -30 "$TEST_LOG" >&2; fail "Tests failed."; }
grep -E "Test run with" "$TEST_LOG" | tail -1

step "Building and signing the app"
VERSION=$VERSION SIGN_IDENTITY=$SIGN_IDENTITY HARDENED=1 Scripts/bundle-app.sh >/dev/null
codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -1
codesign -d --verbose=2 "$APP" 2>&1 | grep -E "^(Authority|flags|Timestamp)" | head -4 || true

rm -rf "$OUT"
mkdir -p "$OUT"

notarize() { # <file>
  step "Notarizing $(basename $1) (this usually takes a few minutes)"
  local result
  result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  local state=$(print -r -- "$result" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
  local id=$(print -r -- "$result" | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
  if [[ $state != Accepted ]]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fail "Notarization of $(basename $1) failed: $state"
  fi
  echo "Accepted ($id)"
}

if [[ $DRY_RUN == 0 ]]; then
  # The app is notarized via a temporary ZIP so the ticket can be stapled to the app itself.
  ditto -c -k --keepParent "$APP" "$OUT/notarize-app.zip"
  notarize "$OUT/notarize-app.zip"
  rm "$OUT/notarize-app.zip"
  xcrun stapler staple -q "$APP"
fi

# MARK: Package

step "Creating ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

step "Creating DMG"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/PhoneMirror.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "PhoneMirror $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG"
codesign --force --sign "$SIGN_IDENTITY" $([[ $DRY_RUN == 0 ]] && echo --timestamp) "$DMG"
if [[ $DRY_RUN == 0 ]]; then
  notarize "$DMG"
  xcrun stapler staple -q "$DMG"
fi

(cd "$OUT" && shasum -a 256 "PhoneMirror-$VERSION.zip" "PhoneMirror-$VERSION.dmg" > SHA256SUMS.txt)

# MARK: Sparkle appcast

if [[ $DRY_RUN == 0 ]]; then
  step "Adding $TAG to appcast.xml"
  SIGN_UPDATE=$(find .build/artifacts -path "*Sparkle/bin/sign_update" | head -1)
  [[ -x "$SIGN_UPDATE" ]] || fail "Sparkle's sign_update not found (swift package resolve)."
  # Signs with the EdDSA key from the login keychain (created once with Sparkle's generate_keys).
  SPARKLE_SIGNATURE=$("$SIGN_UPDATE" "$ZIP")
  BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")
  python3 -I - "../appcast.xml" "$VERSION" "$BUILD" "$SPARKLE_SIGNATURE" <<'PY'
import sys, email.utils
path, version, build, signature = sys.argv[1:5]
base = "https://github.com/Mapl92/phonemirror/releases"
item = f"""    <item>
      <title>Version {version}</title>
      <pubDate>{email.utils.formatdate(localtime=False)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>{base}/tag/v{version}</sparkle:releaseNotesLink>
      <enclosure url="{base}/download/v{version}/PhoneMirror-{version}.zip" {signature} type="application/octet-stream"/>
    </item>
"""
text = open(path).read()
marker = "    <language>en</language>\n"
assert marker in text, "unexpected appcast.xml layout"
open(path, "w").write(text.replace(marker, marker + item, 1))
PY
fi

# MARK: Verify

step "Gatekeeper check"
if [[ $DRY_RUN == 0 ]]; then
  spctl --assess --type execute --verbose=2 "$APP" 2>&1 | head -2
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | head -2
else
  echo "Skipped (dry run: ad-hoc signature, not notarized)"
fi

# MARK: GitHub

if [[ $GITHUB == 1 ]]; then
  step "Creating draft release $TAG"
  NOTES="$OUT/notes.md"
  PREVIOUS=$(git describe --tags --abbrev=0 2>/dev/null || true)
  {
    echo "Signed with a Developer ID and notarized by Apple. Requires an iPhone with iOS 27 (Developer Mode,"
    echo "paired with your Mac) and Xcode 27 on macOS 27. See the README for setup."
    echo
    echo "**Download:** \`PhoneMirror-$VERSION.dmg\` (drag to Applications) or \`PhoneMirror-$VERSION.zip\`."
    echo
    echo "## Changes"
    if [[ -n $PREVIOUS ]]; then
      git log --no-merges --format='- %s' "$PREVIOUS..HEAD"
    else
      echo "- First release"
    fi
    echo
    echo "SHA-256 checksums are in \`SHA256SUMS.txt\`."
  } > "$NOTES"
  gh release create "$TAG" --draft --target "$(git rev-parse HEAD)" --title "PhoneMirror $VERSION" \
    --notes-file "$NOTES" "$ZIP" "$DMG" "$OUT/SHA256SUMS.txt"
  echo "Draft created – review and publish it on GitHub."
  echo "After publishing: commit and push appcast.xml so existing installations see the update."
fi

step "Done"
ls -lh "$OUT"
