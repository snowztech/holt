#!/usr/bin/env bash
# Builds a signed, notarized build/Holt-<version>.dmg that opens on any Apple Silicon Mac without warnings.
# Needs a Developer ID Application certificate and a notarytool keychain profile
# (the same one Farol uses works: `xcrun notarytool store-credentials farol`).
# CI passes an App Store Connect API key instead: NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID.
# VERSION=0.2.0 stamps that version into the app. NOTARIZE=0 signs without notarizing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
profile="${NOTARY_PROFILE:-farol}"
identity="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[ -n "$identity" ] || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }

make -C "$root" mac
app="$root/build/Holt.app"
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$app/Contents/Info.plist"
fi
version=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)

# Only these builds update themselves. A `make run` build has no feed, so it never
# offers to replace itself with the latest release.
/usr/libexec/PlistBuddy \
    -c "Add :SUFeedURL string https://github.com/snowztech/holt/releases/latest/download/appcast.xml" \
    -c "Add :SUPublicEDKey string kgq6lf9jvmq+Pvnoq6SiyXP06xUrnEUZiFiLDYtXCKY=" \
    -c "Add :SUEnableAutomaticChecks bool true" \
    "$app/Contents/Info.plist"
dmg="$root/build/Holt-$version.dmg"
zip="$root/build/Holt-$version.zip"

# Hardened runtime and a secure timestamp are what notarization requires.
# Inside out: Sparkle's own programs first, then the framework, then the app.
sign() {
    codesign --force --timestamp --options runtime --sign "$identity" "$1"
}
sparkle="$app/Contents/Frameworks/Sparkle.framework"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign "$app"
codesign --verify --strict --deep "$app"
echo "signed with $identity"

notarize() {
    if [ -n "${NOTARY_KEY_PATH:-}" ]; then
        xcrun notarytool submit "$1" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
    else
        xcrun notarytool submit "$1" --keychain-profile "$profile" --wait
    fi
}

# The disk image: the app next to a link to /Applications, to drag it across.
make_dmg() {
    local staging
    staging=$(mktemp -d)
    cp -R "$app" "$staging/"
    ln -s /Applications "$staging/Applications"
    rm -f "$dmg"
    hdiutil create -quiet -volname Holt -srcfolder "$staging" -ov -format UDZO "$dmg"
    rm -rf "$staging"
    codesign --force --timestamp --sign "$identity" "$dmg"
}

if [ "${NOTARIZE:-1}" = "0" ]; then
    make_dmg
    echo "built $dmg (signed, not notarized)"
    exit 0
fi

# The app first, so its ticket is stapled before it goes into the zip and the disk image.
# The zip is what Sparkle downloads to update.
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
notarize "$zip"
xcrun stapler staple "$app"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"

make_dmg
notarize "$dmg"
xcrun stapler staple "$dmg"

spctl --assess --type execute --verbose "$app"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "built $zip and $dmg (signed and notarized)"
