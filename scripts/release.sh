#!/bin/zsh
# Builds a Developer ID signed, notarized and stapled installer package in dist/,
# then prints the Sparkle values for the appcast entry.
# Usage: NOTARY_PROFILE=<notarytool keychain profile> scripts/release.sh [--skip-notarize]
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="LAR9U97K23"
BUNDLE_ID="com.sherrodsoftware.BoxingDay"
PROJECT="Boxing Day.xcodeproj"
SCHEME="Boxing Day"
APP_BUNDLE="Boxing Day.app"
PKG_NAME="BoxingDay"
SPARKLE="Contents/Frameworks/Sparkle.framework"
SPARKLE_ACCOUNT="Sherrod Software"
INSTALLER_IDENTITY="Developer ID Installer: JOHN WILLIAM SHERROD (${TEAM_ID})"
NOTARY_PROFILE="${NOTARY_PROFILE:-notary}"
SKIP_NOTARIZE=false
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=true

WORK="build/release"
DERIVED="${WORK}/DerivedData"
ARCHIVE="${WORK}/${PKG_NAME}.xcarchive"
EXPORT="${WORK}/export"
rm -rf "$WORK"
mkdir -p "$WORK" dist

echo "==> Running tests"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO test -quiet

echo "==> Archiving"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$DERIVED" -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates archive -quiet

echo "==> Exporting with Developer ID"
cat > "${WORK}/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
    -exportOptionsPlist "${WORK}/ExportOptions.plist" -allowProvisioningUpdates -quiet

APP="${EXPORT}/${APP_BUNDLE}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP}/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "${APP}/Contents/Info.plist")
PKG="dist/${PKG_NAME}-${VERSION}.pkg"

echo "==> Checking signatures"
codesign --verify --deep --strict "$APP"
# Sparkle installs updates from inside its framework, so it must be re-signed by
# this team with the hardened runtime, like the app, or notarization fails.
[[ -d "${APP}/${SPARKLE}" ]] || { echo "Missing ${SPARKLE}"; exit 1; }
for item in "$APP" "${APP}/${SPARKLE}"; do
    details=$(codesign -dv --verbose=2 "$item" 2>&1)
    grep -q "TeamIdentifier=${TEAM_ID}" <<< "$details" || { echo "${item} isn't signed by ${TEAM_ID}"; exit 1; }
    grep -q "Authority=Developer ID Application" <<< "$details" || { echo "${item} isn't signed with Developer ID"; exit 1; }
    grep -q "(runtime)" <<< "$details" || { echo "${item} doesn't use the hardened runtime"; exit 1; }
done
for key in SUFeedURL SUPublicEDKey; do
    /usr/libexec/PlistBuddy -c "Print ${key}" "${APP}/Contents/Info.plist" >/dev/null \
        || { echo "Info.plist is missing ${key}"; exit 1; }
done

echo "==> Building ${PKG} (version ${VERSION}, build ${BUILD})"
ROOT="${WORK}/root"
mkdir -p "$ROOT"
ditto --noextattr --noqtn "$APP" "${ROOT}/${APP_BUNDLE}"
codesign --verify --deep --strict "${ROOT}/${APP_BUNDLE}"
COMPONENTS="${WORK}/components.plist"
pkgbuild --analyze --root "$ROOT" "$COMPONENTS" >/dev/null
/usr/libexec/PlistBuddy -c "Delete :0:BundleIsRelocatable" "$COMPONENTS" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$COMPONENTS"
rm -f "$PKG"
pkgbuild --root "$ROOT" --component-plist "$COMPONENTS" --install-location /Applications \
    --identifier "$BUNDLE_ID" --version "$VERSION" --sign "$INSTALLER_IDENTITY" "$PKG"

if $SKIP_NOTARIZE; then
    echo "==> Skipping notarization: ${PKG} is signed but not notarized"
    exit 0
fi

echo "==> Notarizing (this usually takes a few minutes)"
xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$PKG"

echo "==> Checking"
spctl -a -vv -t install "$PKG"

# Sign only the final, stapled package: stapling changes the file, and the
# appcast signature must match the exact file uploaded to the GitHub release.
echo "==> Sparkle appcast values"
SIGN_UPDATE="${DERIVED}/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$PKG"
echo "sparkle:version=\"${BUILD}\" sparkle:shortVersionString=\"${VERSION}\""
shasum -a 256 "$PKG"
echo "Done: ${PKG}"
