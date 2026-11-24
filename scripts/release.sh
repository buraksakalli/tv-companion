#!/usr/bin/env bash
# Builds a signed, notarized, stapled DMG in ./dist.
#
#   TEAM_ID=XXXXXXXXXX NOTARY_PROFILE=tvcompanion-notary scripts/release.sh
#   scripts/release.sh --unsigned     # local packaging test only; Gatekeeper will block it on other Macs
#
# One-time setup for signed releases:
#   1. Xcode → Settings → Accounts → Manage Certificates → + → "Developer ID Application"
#   2. xcrun notarytool store-credentials tvcompanion-notary --apple-id <id> --team-id <team>
#      (uses an app-specific password; it is stored in your Keychain, not in this repo)
set -euo pipefail
cd "$(dirname "$0")/.."

UNSIGNED=0
[[ "${1:-}" == "--unsigned" ]] && UNSIGNED=1

VERSION=$(awk -F'"' '/CFBundleShortVersionString/ {print $2}' project.yml)
DERIVED=build/release
APP="$DERIVED/Build/Products/Release/TVCompanion.app"
DIST=dist
DMG="$DIST/TVCompanion-$VERSION.dmg"

if [[ $UNSIGNED == 0 ]]; then
  : "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"
  : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
  security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || { echo "No 'Developer ID Application' certificate in the keychain." >&2; exit 1; }
  SIGN_ARGS=(CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID"
             CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS="--timestamp")
else
  SIGN_ARGS=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

echo "==> Building TV Companion $VERSION"
xcodegen generate >/dev/null
rm -rf "$DERIVED"
xcodebuild -project TVCompanion.xcodeproj -scheme TVCompanion -configuration Release \
  -derivedDataPath "$DERIVED" "${SIGN_ARGS[@]}" build -quiet
codesign --verify --deep --strict "$APP"

echo "==> Packaging $DMG"
mkdir -p "$DIST"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "TV Companion" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [[ $UNSIGNED == 0 ]]; then
  codesign --sign "Developer ID Application" --timestamp "$DMG"
  echo "==> Notarizing (this can take a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "==> Done: $DMG"
