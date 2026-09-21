#!/bin/bash
# Developer ID release using the Apple account already signed in to Xcode.
# No app-specific password or exported private key is needed.
# Run again with --resume after Apple's asynchronous notarization completes.
set -euo pipefail
cd "$(dirname "$0")/.."

RESUME=0
case "${1:-}" in
  '') ;;
  --resume) RESUME=1 ;;
  *) echo 'usage: build-release-xcode.sh [--resume]' >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || exit 2

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple team ID}"
: "${DEVELOPER_ID_APP:?Set DEVELOPER_ID_APP to the certificate SHA-1 from security find-identity}"
VERSION=$(awk '/MARKETING_VERSION:/ {gsub(/"/, ""); print $2; exit}' project.yml)
BUILD=$(awk '/CURRENT_PROJECT_VERSION:/ {gsub(/"/, ""); print $2; exit}' project.yml)
DIST_DIR="${DIST_DIR:-$PWD/dist}"
DERIVED_DATA="${DERIVED_DATA:-$DIST_DIR/DerivedData}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$DIST_DIR/Done.md-$VERSION.xcarchive}"
EXPORT_PATH="$DIST_DIR/notarized-$VERSION"
APP="$EXPORT_PATH/马上做完.app"
mkdir -p "$DIST_DIR"

if [ "$RESUME" -eq 0 ]; then
  if [ -e "$ARCHIVE_PATH" ]; then
    echo "Archive already exists: $ARCHIVE_PATH. Use --resume for a submitted build." >&2
    exit 1
  fi
  bash scripts/check.sh
  xcodegen generate
  xcodebuild -project donemd.xcodeproj -scheme donemd -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED_DATA" \
    -archivePath "$ARCHIVE_PATH" CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" CODE_SIGN_IDENTITY="$DEVELOPER_ID_APP" archive
  EXPORT_OPTIONS="$DIST_DIR/ExportOptions.plist"
  /usr/libexec/PlistBuddy -c Clear "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c 'Add :method string developer-id' "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c 'Add :destination string upload' "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c 'Add :signingStyle string manual' "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c "Add :teamID string $DEVELOPMENT_TEAM" "$EXPORT_OPTIONS"
  /usr/libexec/PlistBuddy -c "Add :signingCertificate string $DEVELOPER_ID_APP" "$EXPORT_OPTIONS"
  xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" -exportPath "$DIST_DIR/upload-$VERSION" \
    -allowProvisioningUpdates
fi

if ! xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH"; then
  echo 'If Apple is still processing, wait and run this command again with --resume.' >&2
  echo 'If Apple rejected the build, inspect the notarization log in Xcode Organizer.' >&2
  exit 1
fi

# Refuse to package an old archive under a new version, or change update keys.
ACTUAL_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
ACTUAL_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
[ "$VERSION/$BUILD" = "$ACTUAL_VERSION/$ACTUAL_BUILD" ] || { echo 'Archive version differs from project.yml' >&2; exit 1; }
SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")
[ "$("$SPARKLE_BIN/generate_keys" -p)" = "$PUBLIC_KEY" ] || { echo 'Sparkle signing key does not match the app' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

RELEASES="$DIST_DIR/releases"
mkdir -p "$RELEASES"
ZIP="$RELEASES/Done.md-$VERSION.zip"
# Keep the app at the archive root, with the installed bundle name.
ditto -c -k --keepParent "$APP" "$ZIP"
"$SPARKLE_BIN/generate_appcast" --versions "$BUILD" \
  --download-url-prefix "https://github.com/shampooli61/donemd/releases/download/v$VERSION/" "$RELEASES"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/马上做完.app"
ln -s /Applications "$STAGING/Applications"
printf '%s\n' '# 马上做完（Done.md）' '' '将「马上做完.app」拖入 Applications，然后从应用程序打开。' \
  '' '后续可从应用菜单选择「检查更新…」。' > "$STAGING/安装说明.md"
hdiutil create -volname "Done.md $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DIST_DIR/Done.md-$VERSION.dmg"
(
  cd "$RELEASES"
  shasum -a 256 "Done.md-$VERSION.zip"
  cd "$DIST_DIR"
  shasum -a 256 "Done.md-$VERSION.dmg"
) > "$DIST_DIR/Done.md-$VERSION.sha256.txt"
echo "Ready: $ZIP, $DIST_DIR/Done.md-$VERSION.dmg, $RELEASES/appcast.xml"
echo 'Publish the binaries to the matching GitHub Release, then publish appcast.xml to GitHub Pages.'
