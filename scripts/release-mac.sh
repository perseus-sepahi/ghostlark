#!/bin/sh
# Builds Ghostlark for macOS, signs it with your Developer ID, notarizes it with Apple and staples the ticket.
# Output: release/Ghostlark-mac.zip, which opens on any Mac without a Gatekeeper warning.
#
# One-time setup (see README "Signing the Mac app"):
#   1. Xcode > Settings > Accounts: add your Apple ID; Manage Certificates > + > Developer ID Application.
#   2. xcrun notarytool store-credentials ghostlark --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#      (it asks for an app-specific password from https://account.apple.com)
set -e
cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-ghostlark}"
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' certificate found. Create it in Xcode > Settings > Accounts > Manage Certificates."; exit 1; }
TEAM=$(echo "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
echo "Signing as: $IDENTITY"

[ -x Ghostlark/Resources/bin/sing-box ] || scripts/fetch-core.sh
command -v xcodegen >/dev/null && xcodegen generate >/dev/null
xcodebuild -project Ghostlark.xcodeproj -scheme Ghostlark -configuration Release -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" ENABLE_HARDENED_RUNTIME=YES clean build | grep -E "error:|\*\* BUILD"

APP=build/Build/Products/Release/Ghostlark.app
codesign --verify --deep --strict --verbose=2 "$APP"
mkdir -p release dist
rm -f release/Ghostlark-mac.zip
ditto -c -k --keepParent "$APP" release/Ghostlark-mac.zip

echo "Submitting to Apple for notarization (usually 1-10 minutes)..."
xcrun notarytool submit release/Ghostlark-mac.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

# Re-zip so the download carries the stapled ticket (works offline, first launch has no warning).
rm -f release/Ghostlark-mac.zip
ditto -c -k --keepParent "$APP" release/Ghostlark-mac.zip
rm -rf dist/Ghostlark.app && ditto "$APP" dist/Ghostlark.app
echo "Done: release/Ghostlark-mac.zip is signed, notarized and stapled."
