#!/bin/bash
# Archives Holt for iPhone and uploads it to App Store Connect, for TestFlight.
#
# Signs and uploads as the Apple account signed in to Xcode, or with an App Store Connect
# API key when these are set. The key needs the Admin role, which cloud signing requires.
#   ASC_KEY_PATH   path to the AuthKey_XXXXXXXXXX.p8 file
#   ASC_KEY_ID     its key id
#   ASC_ISSUER_ID  the issuer id, from Users and Access → Integrations
# The NOTARY_* names that scripts/dist.sh reads work too. Put the exports in a `.env` at the
# repo root, which git ignores, and this script loads it. Nothing secret lives in the repo.
#
# EXPORT_ONLY=1 builds build/testflight/Holt.ipa without uploading it.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] && . ./.env

key="${ASC_KEY_PATH:-${NOTARY_KEY_PATH:-}}"
key_id="${ASC_KEY_ID:-${NOTARY_KEY_ID:-}}"
issuer="${ASC_ISSUER_ID:-${NOTARY_ISSUER_ID:-}}"
auth=(-allowProvisioningUpdates)
if [ -n "$key" ] && [ -n "$key_id" ] && [ -n "$issuer" ]; then
    auth+=(-authenticationKeyPath "$key" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")
fi

# Every upload needs a higher build number than the last. A timestamp always is.
build="$(date -u +%Y%m%d).$((10#$(date -u +%H%M)))"
out=build/testflight

make core-ios
(cd apple/ios && xcodegen generate --quiet)
rm -rf "$out"
mkdir -p "$out"

xcodebuild -project apple/ios/Holt.xcodeproj -scheme Holt -configuration Release \
    -destination generic/platform=iOS -archivePath "$out/Holt.xcarchive" \
    CURRENT_PROJECT_VERSION="$build" "${auth[@]}" -quiet archive

destination=upload
[ -n "${EXPORT_ONLY:-}" ] && destination=export
cat >"$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>$destination</string>
    <key>teamID</key><string>X935Q2B2RF</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

xcodebuild -exportArchive -archivePath "$out/Holt.xcarchive" -exportPath "$out" \
    -exportOptionsPlist "$out/ExportOptions.plist" "${auth[@]}" -quiet

if [ "$destination" = upload ]; then
    echo "Uploaded build $build. It shows up in TestFlight once Apple processes it, usually within 15 minutes."
else
    echo "Built $out/Holt.ipa, build $build."
fi
