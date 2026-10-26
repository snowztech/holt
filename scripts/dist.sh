#!/usr/bin/env bash
# Builds a signed, notarized build/Holt-<version>.dmg that opens on any Apple Silicon Mac without warnings.
# Needs a Developer ID Application certificate and a notarytool keychain profile
# (the same one Farol uses works: `xcrun notarytool store-credentials farol`).
# NOTARIZE=0 signs without notarizing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
profile="${NOTARY_PROFILE:-farol}"
identity="${DEVELOPER_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)}"
[ -n "$identity" ] || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }

make -C "$root" mac
app="$root/build/Holt.app"
version=$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString)
dmg="$root/build/Holt-$version.dmg"
zip="$root/build/Holt-$version.zip"

# Hardened runtime and a secure timestamp are what notarization requires.
codesign --force --timestamp --options runtime --sign "$identity" "$app"
codesign --verify --strict --deep "$app"
echo "signed with $identity"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$profile" --wait
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

# The app first, so its ticket is stapled before it goes into the disk image.
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
notarize "$zip"
xcrun stapler staple "$app"
rm -f "$zip"

make_dmg
notarize "$dmg"
xcrun stapler staple "$dmg"

spctl --assess --type execute --verbose "$app"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
echo "built $dmg (signed and notarized)"
