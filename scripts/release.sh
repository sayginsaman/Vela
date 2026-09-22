#!/bin/zsh
# Build, sign with Developer ID, notarize, staple and package Vela as a disk image.
#
#   scripts/release.sh <version> [notary-keychain-profile]
#
# Prerequisites (one-time, done by the account owner):
#   0. Sparkle's EdDSA key in the login keychain (build/DerivedData/SourcePackages/artifacts/
#      sparkle/Sparkle/bin/generate_keys). Its public half lives in Config/Info.plist.
#   1. A "Developer ID Application" certificate in the login keychain
#      (Xcode › Settings › Accounts › Manage Certificates › + › Developer ID Application).
#   2. Notary credentials stored in the keychain, never in this repo:
#      xcrun notarytool store-credentials VelaNotary --apple-id <apple-id> --team-id <TEAMID>
#      (enter an app-specific password from account.apple.com when prompted)
set -euo pipefail

# Stapling fetches the ticket from Apple's CDN, which occasionally refuses connections right
# after a submission is accepted; retry a few times before giving up.
staple() {
  for attempt in 1 2 3 4 5; do
    if xcrun stapler staple "$1"; then return 0; fi
    echo "stapler failed (attempt $attempt), retrying in 20 s"
    sleep 20
  done
  return 1
}

VERSION=${1:?usage: scripts/release.sh <version> [profile]}
PROFILE=${2:-VelaNotary}
cd "$(dirname "$0")/.."

SPARKLE_PUBLIC_ED_KEY=$(build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -p 2>/dev/null | tail -1)
[[ -n "$SPARKLE_PUBLIC_ED_KEY" ]] || { echo "No Sparkle key in the keychain; run generate_keys once."; exit 1; }
IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate in the keychain."; exit 1; }
TEAM=$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')
echo "Signing as: $IDENTITY (team $TEAM)"

echo "▶ Building Release $VERSION"
xcodebuild -project Vela.xcodeproj -scheme Vela -configuration Release -derivedDataPath build/DerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" MARKETING_VERSION="$VERSION" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build > build/release-build.log 2>&1 || { grep -E "error:" build/release-build.log | sort -u; echo "Build failed; see build/release-build.log"; exit 1; }
grep -E "warning: .*sign|BUILD" build/release-build.log | sort -u || true

APP=build/DerivedData/Build/Products/Release/Vela.app
# Never sign and ship a stale bundle: the app on disk must be the version being released.
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[[ "$BUILT_VERSION" == "$VERSION" ]] || { echo "Built app is $BUILT_VERSION, expected $VERSION; aborting"; exit 1; }
# A Release app that has been launched gets macOS's app-bundle protection, and the next build
# cannot write into it. Launch copies for checks, never this bundle.

# Xcode re-signs only the outer Sparkle framework; its nested helpers keep Sparkle's own
# signature, which notarization rejects. Re-sign them inside-out with our identity, hardened
# runtime and a timestamp, keeping the XPC services' entitlements.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  echo "▶ Re-signing Sparkle helpers"
  V="$SPARKLE_FW/Versions/B"
  for xpc in "$V/XPCServices/Installer.xpc" "$V/XPCServices/Downloader.xpc"; do
    [[ -d "$xpc" ]] && codesign -f -s "$IDENTITY" -o runtime --timestamp --preserve-metadata=entitlements "$xpc"
  done
  codesign -f -s "$IDENTITY" -o runtime --timestamp "$V/Autoupdate"
  codesign -f -s "$IDENTITY" -o runtime --timestamp "$V/Updater.app"
  codesign -f -s "$IDENTITY" -o runtime --timestamp "$SPARKLE_FW"
  codesign -f -s "$IDENTITY" -o runtime --timestamp --entitlements Vela/Vela.entitlements "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
for nested in "$SPARKLE_FW/Versions/B/Autoupdate" "$SPARKLE_FW/Versions/B/Updater.app"; do
  details=$(codesign -dvv "$nested" 2>&1 || true)
  [[ "$details" == *"Authority=Developer ID Application"* ]] || { echo "$nested is not Developer ID signed"; exit 1; }
done
codesign -d --entitlements :- "$APP" | grep -q apple-events && echo "✓ Apple Events entitlement present"
# Plain `xcodebuild build` would add the debug get-task-allow entitlement, which notarization rejects.
codesign -d --entitlements :- "$APP" | grep -q get-task-allow && { echo "get-task-allow entitlement present; aborting"; exit 1; }

echo "▶ Notarizing the app"
rm -rf build/notarize && mkdir -p build/notarize
ditto -c -k --keepParent "$APP" build/notarize/Vela.zip
xcrun notarytool submit build/notarize/Vela.zip --keychain-profile "$PROFILE" --wait
staple "$APP"

echo "▶ Building the disk image"
rm -rf build/dmg && mkdir -p build/dmg/staging
cp -R "$APP" build/dmg/staging/
ln -s /Applications build/dmg/staging/Applications
DMG="build/dmg/Vela-$VERSION.dmg"
hdiutil create -volname "Vela" -srcfolder build/dmg/staging -ov -format UDZO -quiet "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"

echo "▶ Notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "✓ $DMG is signed, notarized and stapled"

echo "▶ Signing for in-app updates"
SPARKLE_BIN=$(ls -d build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1)
[[ -n "$SPARKLE_BIN" ]] || { echo "Sparkle tools not found; resolve packages first."; exit 1; }
ED_SIGNATURE=$("$SPARKLE_BIN/sign_update" -p "$DMG")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
scripts/appcast.py "$VERSION" "$BUILD_NUMBER" "$DMG" \
  "https://github.com/sayginsaman/Vela/releases/download/v$VERSION/Vela-$VERSION.dmg" "$ED_SIGNATURE"
echo "✓ appcast.xml updated — commit and push it after publishing the GitHub release"
