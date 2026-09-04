#!/bin/zsh
# Build, sign with Developer ID, notarize, staple and package Vela as a disk image.
#
#   scripts/release.sh <version> [notary-keychain-profile]
#
# Prerequisites (one-time, done by the account owner):
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application).
#   2. Notary credentials stored in the keychain, never in this repo:
#      xcrun notarytool store-credentials VelaNotary --apple-id <apple-id> --team-id <TEAMID>
#      (enter an app-specific password from account.apple.com when prompted)
set -euo pipefail

VERSION=${1:?usage: scripts/release.sh <version> [profile]}
PROFILE=${2:-VelaNotary}
cd "$(dirname "$0")/.."

IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate in the keychain."; exit 1; }
TEAM=$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')
echo "Signing as: $IDENTITY (team $TEAM)"

echo "▶ Building Release $VERSION"
xcodebuild -project Vela.xcodeproj -scheme Vela -configuration Release -derivedDataPath build/DerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" MARKETING_VERSION="$VERSION" \
  build | grep -E "error:|warning: .*sign|BUILD" || true

APP=build/DerivedData/Build/Products/Release/Vela.app
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements :- "$APP" | grep -q apple-events && echo "✓ Apple Events entitlement present"

echo "▶ Notarizing the app"
rm -rf build/notarize && mkdir -p build/notarize
ditto -c -k --keepParent "$APP" build/notarize/Vela.zip
xcrun notarytool submit build/notarize/Vela.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"

echo "▶ Building the disk image"
rm -rf build/dmg && mkdir -p build/dmg/staging
cp -R "$APP" build/dmg/staging/
ln -s /Applications build/dmg/staging/Applications
DMG="build/dmg/Vela-$VERSION.dmg"
hdiutil create -volname "Vela" -srcfolder build/dmg/staging -ov -format UDZO -quiet "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "▶ Notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "✓ $DMG is signed, notarized and stapled"
