#!/bin/sh
# Builds Ghostlark for macOS, signs it with Developer ID (Xcode cloud-managed signing, so no local
# Developer ID certificate is needed), notarizes it with Apple and staples the ticket.
# Output: release/Ghostlark-mac.zip, which opens on any Mac without a Gatekeeper warning.
#
# One-time setup:
#   1. Xcode > Settings > Accounts: sign in with the Apple ID of the paid developer team.
#   2. xcrun notarytool store-credentials ghostlark --apple-id YOU@EXAMPLE.COM --team-id TEAMID
#      (asks for an app-specific password from https://account.apple.com)
set -e
cd "$(dirname "$0")/.."
TEAM="${TEAM_ID:-ZY74XX7D42}"
PROFILE="${NOTARY_PROFILE:-ghostlark}"
WORK="build/release-mac"
rm -rf "$WORK"; mkdir -p "$WORK" release dist

[ -x Ghostlark/Resources/bin/sing-box ] || scripts/fetch-core.sh
command -v xcodegen >/dev/null && xcodegen generate >/dev/null

xcodebuild -project Ghostlark.xcodeproj -scheme Ghostlark -configuration Release -derivedDataPath build \
  -archivePath "$WORK/Ghostlark.xcarchive" archive \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_IDENTITY="Apple Development" \
  -allowProvisioningUpdates | grep -E "error:|\*\* ARCHIVE"

cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$WORK/Ghostlark.xcarchive" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" -allowProvisioningUpdates | grep -E "error|\*\* EXPORT"

APP="$WORK/export/Ghostlark.app"
codesign --verify --deep --strict "$APP"
codesign -dvv "$APP/Contents/Resources/sing-box" 2>&1 | grep -q "Developer ID Application" \
  || { echo "embedded sing-box is not Developer ID signed"; exit 1; }

ditto -c -k --keepParent "$APP" "$WORK/notary.zip"
echo "Submitting to Apple for notarization..."
xcrun notarytool submit "$WORK/notary.zip" --keychain-profile "$PROFILE" --wait --timeout 60m
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

rm -f release/Ghostlark-mac.zip
ditto -c -k --keepParent "$APP" release/Ghostlark-mac.zip
rm -rf dist/Ghostlark.app && ditto "$APP" dist/Ghostlark.app
echo "Done: release/Ghostlark-mac.zip is signed, notarized and stapled."
