#!/bin/bash
# Archives Holt for iPhone and uploads it to App Store Connect, for TestFlight.
#
# Needs an App Store Connect API key with the App Manager role, in the environment:
#   ASC_KEY_PATH   path to the AuthKey_XXXXXXXXXX.p8 file
#   ASC_KEY_ID     its key id
#   ASC_ISSUER_ID  the issuer id, from Users and Access → Integrations
# The NOTARY_* names that scripts/dist.sh reads work too. Nothing secret lives in the repo.
#
# EXPORT_ONLY=1 builds build/testflight/Holt.ipa without uploading it.
set -euo pipefail
cd "$(dirname "$0")/.."

key="${ASC_KEY_PATH:-${NOTARY_KEY_PATH:-}}"
key_id="${ASC_KEY_ID:-${NOTARY_KEY_ID:-}}"
issuer="${ASC_ISSUER_ID:-${NOTARY_ISSUER_ID:-}}"
if [ -z "$key" ] || [ -z "$key_id" ] || [ -z "$issuer" ]; then
    echo "Set ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID to an App Store Connect API key." >&2
    exit 1
fi

# Every upload needs a higher build number than the last. A timestamp always is.
build="$(date -u +%Y%m%d).$((10#$(date -u +%H%M)))"
out=build/testflight
auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")

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
