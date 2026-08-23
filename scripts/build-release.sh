#!/bin/bash
#
# build-release.sh — build a Release Done.md.app for internal distribution.
#
# Output:
#   dist/Done.md-{version}.app          — the unzipped app
#   dist/Done.md-{version}.zip          — quick-share archive
#   dist/Done.md-{version}.dmg          — drag-to-Applications installer
#   dist/Done.md-{version}.sha256.txt   — checksums for tester verification
#
# Two signing paths, chosen by --release:
#
#   (default, no flag) INTERNAL TEST BUILD — ad-hoc (`codesign --sign -`).
#     NOT Apple-notarized; testers right-click → 「打开」 the first time.
#     See docs/testers/INSTALL.md. Does NOT produce/update appcast.xml.
#
#   --release  PUBLIC RELEASE BUILD — Developer ID signed + Apple-notarized +
#     stapled, then runs Sparkle's generate_appcast to (re)build dist/appcast.xml
#     with an EdDSA signature per update. This is the path whose .zip Sparkle can
#     actually auto-INSTALL. Requires an Apple Developer Program membership.
#     See docs/notes/sparkle-release.md for the full release handbook.
#
# Prerequisites:
#   - Xcode (tested with 17.x)
#   - xcodegen (`brew install xcodegen`)
#   - Node.js (preBuildScripts builds the web bundle)
#   For --release additionally:
#   - A "Developer ID Application" certificate in the login keychain
#   - A notarytool credential profile (see docs/notes/sparkle-release.md §1),
#     name overridable via NOTARY_PROFILE (default "donemd-notary")
#   - The Sparkle EdDSA private key in the login keychain (created once by
#     generate_keys; see docs/notes/sparkle-release.md §0.1)
#
# Usage:
#   ./scripts/build-release.sh             # internal ad-hoc test build
#   ./scripts/build-release.sh --clean     # nuke dist/ + DerivedData first
#   ./scripts/build-release.sh --release   # public Developer ID + notarized + appcast
#
# Env overrides (for --release):
#   DEVELOPER_ID_APP  full identity string, e.g. "Developer ID Application: Your Name (TEAMID)".
#                     If unset, the script picks the sole Developer ID Application identity it finds.
#   NOTARY_PROFILE    notarytool keychain-profile name (default: donemd-notary)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CLEAN=0
RELEASE=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --release) RELEASE=1 ;;
    *) echo "unknown flag: $arg"; exit 1 ;;
  esac
done

NOTARY_PROFILE="${NOTARY_PROFILE:-donemd-notary}"

# Locate Sparkle's CLI tools (generate_appcast / sign_update). They ship with
# the SPM binary artifact and live under DerivedData. Only needed for --release.
find_sparkle_tool() {
  find ~/Library/Developer/Xcode/DerivedData/donemd-*/SourcePackages/artifacts/sparkle/Sparkle/bin \
    -name "$1" 2>/dev/null | head -1
}

# Pull version from project.yml without parsing YAML — single
# MARKETING_VERSION line, regex-grabbed.
VERSION="$(awk '/MARKETING_VERSION:/ { gsub(/"/, ""); print $2; exit }' project.yml)"
if [ -z "$VERSION" ]; then
  echo "error: could not extract MARKETING_VERSION from project.yml"
  exit 1
fi

DIST_DIR="dist"
APP_NAME="donemd"
EXPORT_NAME="Done.md-${VERSION}"
ARCHIVE_PATH="${DIST_DIR}/${EXPORT_NAME}.xcarchive"
EXPORT_DIR="${DIST_DIR}/${EXPORT_NAME}.export"
APP_PATH="${EXPORT_DIR}/${APP_NAME}.app"
APP_FINAL="${DIST_DIR}/${EXPORT_NAME}.app"
ZIP_FINAL="${DIST_DIR}/${EXPORT_NAME}.zip"
DMG_FINAL="${DIST_DIR}/${EXPORT_NAME}.dmg"
SUMS_FINAL="${DIST_DIR}/${EXPORT_NAME}.sha256.txt"

if [ "$CLEAN" -eq 1 ]; then
  echo "==> clean: removing dist/ build scratch (preserving dist/releases/) and DerivedData"
  # dist/releases/ is the published Sparkle feed + every shipped update zip;
  # generate_appcast regenerates the multi-version appcast.xml from it, so
  # wiping it would sever auto-update history. Nuke only the build scratch.
  find "$DIST_DIR" -mindepth 1 -maxdepth 1 ! -name releases -exec rm -rf {} + 2>/dev/null || true
  rm -rf ~/Library/Developer/Xcode/DerivedData/donemd-*
fi

mkdir -p "$DIST_DIR"

# Always regenerate the .xcodeproj — project.yml is the source of truth
# (per CLAUDE.md / .gitignore comment) and a stale .xcodeproj on disk
# from a prior xcodegen run could miss freshly added files.
echo "==> xcodegen: regenerate donemd.xcodeproj"
xcodegen generate

# ExportOptions.plist for `xcodebuild -exportArchive`. We choose
# "developer-id" method even though we're not actually signing with
# Developer ID — Xcode's "mac-application" / "development" methods
# require an Apple Developer Team ID we don't have. Using "developer-id"
# with `signingStyle: manual` and an empty signing identity makes
# Xcode skip its own signing pass; we then ad-hoc sign post-export.
EXPORT_PLIST=$(mktemp)
cat > "$EXPORT_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>mac-application</string>
  <key>signingStyle</key>
  <string>manual</string>
</dict>
</plist>
EOF

echo "==> xcodebuild archive (Release)"
xcodebuild \
  -project donemd.xcodeproj \
  -scheme donemd \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  archive | tail -20

echo "==> xcodebuild exportArchive"
# `-exportArchive` with manual style + no team will refuse — work
# around by copying the .app out of the archive directly. The archive
# already contains a built-and-linked .app under
# Products/Applications/, which is what we want.
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"
cp -R "${ARCHIVE_PATH}/Products/Applications/${APP_NAME}.app" "$EXPORT_DIR/"

if [ "$RELEASE" -eq 1 ]; then
  # PUBLIC RELEASE: Developer ID signing. Sparkle verifies the archive's
  # code signature and Gatekeeper must accept the app for auto-INSTALL to
  # work, so ad-hoc is not enough here.
  echo "==> Developer ID codesign"
  if [ -z "${DEVELOPER_ID_APP:-}" ]; then
    # Pick the sole Developer ID Application identity if the caller didn't
    # pin one. Bail if there are zero or several (ambiguous → make it explicit).
    # Kept bash-3.2 compatible (macOS system /bin/bash) — no mapfile/readarray.
    IDS_RAW="$(security find-identity -v -p codesigning \
      | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p')"
    ID_COUNT=$(printf '%s\n' "$IDS_RAW" | grep -c . || true)
    if [ "$ID_COUNT" -eq 0 ]; then
      echo "error: no 'Developer ID Application' identity in keychain."
      echo "       Get one via Xcode → Settings → Accounts → Manage Certificates,"
      echo "       or set DEVELOPER_ID_APP explicitly. See docs/notes/sparkle-release.md §1."
      exit 1
    elif [ "$ID_COUNT" -gt 1 ]; then
      echo "error: multiple Developer ID Application identities found; set DEVELOPER_ID_APP to one of:"
      printf '       %s\n' "$IDS_RAW"
      exit 1
    fi
    DEVELOPER_ID_APP="$IDS_RAW"
  fi
  echo "    identity: ${DEVELOPER_ID_APP}"
  # Hardened runtime + timestamp are required for notarization. --deep signs
  # nested frameworks (Sparkle.framework, XPC services) with the same identity.
  codesign --force --deep --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APP" "$EXPORT_DIR/${APP_NAME}.app"
  codesign --verify --deep --strict --verbose=2 "$EXPORT_DIR/${APP_NAME}.app"

  # Notarize: zip → submit → wait → staple the ticket onto the .app so it
  # verifies offline. We staple the .app (not the zip) then re-zip below.
  echo "==> notarize (profile: ${NOTARY_PROFILE})"
  NOTARIZE_ZIP=$(mktemp -d)/notarize.zip
  ditto -c -k --keepParent "$EXPORT_DIR/${APP_NAME}.app" "$NOTARIZE_ZIP"
  xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> staple ticket"
  xcrun stapler staple "$EXPORT_DIR/${APP_NAME}.app"
  xcrun stapler validate "$EXPORT_DIR/${APP_NAME}.app"
  rm -f "$NOTARIZE_ZIP"
else
  # INTERNAL TEST: ad-hoc sign with macOS's built-in `codesign` — gives the
  # .app a stable signature that survives mac-to-mac transit (without one,
  # Gatekeeper on macOS 14+ refuses to launch at all). Ad-hoc is NOT
  # notarized; testers see the right-click + 「打开」 prompt the first time.
  echo "==> ad-hoc codesign"
  codesign --force --deep --sign - "$EXPORT_DIR/${APP_NAME}.app"
  codesign --verify --deep --strict --verbose=2 "$EXPORT_DIR/${APP_NAME}.app" || true
fi

# Move the .app into its final per-version filename so multiple
# preview builds can sit side-by-side.
rm -rf "$APP_FINAL"
cp -R "$EXPORT_DIR/${APP_NAME}.app" "$APP_FINAL"

# Bake the tester onboarding doc into both .zip and .dmg so the
# first thing testers see when they open the package is "how to
# install + how to open + known limits". docs/testers/INSTALL.md is
# the source of truth; we copy it under the marketing-friendly name
# "安装说明.md" so it's obvious in Chinese Finder.
TESTER_README_SRC="docs/testers/INSTALL.md"
TESTER_README_NAME="安装说明.md"
if [ ! -f "$TESTER_README_SRC" ]; then
  echo "error: $TESTER_README_SRC not found — should be tracked in repo"
  exit 1
fi

# .zip = the Sparkle update artifact. Sparkle's generate_appcast AND its
# in-app updater both require the .app at the archive ROOT: a wrapper
# folder makes generate_appcast reject it ("No supported items … only
# .app bundles are supported") and breaks the auto-install swap on the
# client. So we archive the .app directly — `--keepParent` keeps
# `donemd.app` itself as the single top-level entry, the exact shape of
# the notarize zip above and what Sparkle expects. ditto (not zip(1))
# preserves the bundle's resource forks + symlinks + signature intact.
# Tester-friendly packaging (README + drag-install) lives in the .dmg
# below — that's the tester channel; the .zip is purely for updates.
echo "==> ditto: build .zip (Sparkle update artifact — donemd.app at root)"
# Stage the bundle back under its real name ${APP_NAME}.app (donemd.app), NOT
# the per-version filename APP_FINAL carries (Done.md-1.0.0.app). The update
# zip's bundle must match the installed app's name so Sparkle's in-place swap
# is unambiguous. --keepParent then makes donemd.app the single root entry —
# what generate_appcast and the updater both require.
ZIP_STAGING=$(mktemp -d)
cp -R "$APP_FINAL" "$ZIP_STAGING/${APP_NAME}.app"
rm -f "$ZIP_FINAL"
ditto -c -k --keepParent "$ZIP_STAGING/${APP_NAME}.app" "$ZIP_FINAL"
rm -rf "$ZIP_STAGING"

# .dmg: hdiutil with `-format UDZO` (compressed read-only). Layout
# inside the dmg:
#   - donemd.app          (the app bundle)
#   - 安装说明.md         (tester onboarding — opens in Finder Quick Look on space)
#   - Applications        (symlink target for drag-install)
# Phase 4 公开发布前升级 dmg styling (custom background + volume
# icon + auto-arranged window) 一并做.
echo "==> hdiutil: build .dmg"
DMG_STAGING=$(mktemp -d)
cp -R "$APP_FINAL" "$DMG_STAGING/${APP_NAME}.app"
cp "$TESTER_README_SRC" "$DMG_STAGING/${TESTER_README_NAME}"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG_FINAL"
hdiutil create \
  -volname "Done.md ${VERSION}" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_FINAL"
rm -rf "$DMG_STAGING"

# Checksums for tester verification — they can `shasum -a 256 -c
# Done.md-{version}.sha256.txt` to confirm the file you sent is what
# landed on their machine.
echo "==> sha256 checksums"
(
  cd "$DIST_DIR"
  shasum -a 256 \
    "${EXPORT_NAME}.zip" \
    "${EXPORT_NAME}.dmg" \
    > "${EXPORT_NAME}.sha256.txt"
)

if [ "$RELEASE" -eq 1 ]; then
  # Generate/refresh the Sparkle appcast. generate_appcast scans a directory
  # of update archives (.zip), reads each app's version out of its Info.plist,
  # EdDSA-signs every archive with the private key from the login keychain,
  # and writes/updates appcast.xml in that same directory.
  #
  # It scans dist/releases/ ONLY — never dist/ itself. dist/ is build scratch
  # and has historically accumulated non-release zips (old previews, phase
  # builds); scanning it would sign those stale bundles into the live feed and
  # surface ancient versions as available updates. dist/releases/ is the
  # curated set: exactly the zips actually shipped, one per published tag.
  # Copying the current .zip in and regenerating preserves prior <item>s
  # (each keeps its own tag's URL) and adds this version, so the feed stays a
  # correct multi-version history. --download-url-prefix points the NEW
  # <enclosure url> at this tag's GitHub Releases download; no hand-editing.
  echo "==> generate appcast (Sparkle)"
  GEN_APPCAST="$(find_sparkle_tool generate_appcast)"
  if [ -z "$GEN_APPCAST" ]; then
    echo "error: generate_appcast not found under DerivedData."
    echo "       Build once so SPM downloads Sparkle's binary artifact, then retry."
    echo "       See docs/notes/sparkle-release.md §5."
    exit 1
  fi
  RELEASES_DIR="${DIST_DIR}/releases"
  mkdir -p "$RELEASES_DIR"
  cp "$ZIP_FINAL" "$RELEASES_DIR/"
  RELEASE_URL_PREFIX="https://github.com/shampooli61/donemd/releases/download/v${VERSION}/"
  "$GEN_APPCAST" \
    --download-url-prefix "$RELEASE_URL_PREFIX" \
    "$RELEASES_DIR"
  echo "    → ${RELEASES_DIR}/appcast.xml (scans dist/releases/ only; enclosure URLs prefixed with ${RELEASE_URL_PREFIX})"
fi

# Cleanup intermediates — keep .zip + .dmg + .sha256.txt as the
# distribution artifacts. .app is removed because the .zip and .dmg
# both contain a copy and keeping a third raw .app on disk wastes
# ~10 MB per build. (appcast.xml, if generated, is kept.)
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" "$EXPORT_PLIST" "$APP_FINAL"

echo
echo "==> done"
echo "    版本：${VERSION}"
echo "    输出："
ls -lh "$DIST_DIR"/${EXPORT_NAME}.{zip,dmg,sha256.txt} 2>/dev/null | awk '{print "      " $9, "(" $5 ")"}'
if [ "$RELEASE" -eq 1 ]; then
  echo "      ${DIST_DIR}/releases/appcast.xml"
  echo
  echo "发布（见 docs/notes/sparkle-release.md §2.3）："
  echo "  1. 把 ${ZIP_FINAL} 传到 GitHub Releases，tag = v${VERSION}"
  echo "  2. 把 ${DIST_DIR}/releases/appcast.xml 传到 GitHub Pages (https://shampooli61.github.io/donemd/appcast.xml)"
  echo "  3. 老用户点「检查更新」即可收到 v${VERSION}"
else
  echo
  echo "把 ${DMG_FINAL} 发给测试者；同时附上 docs/testers/INSTALL.md。"
  echo "（这是自签名内测包，不进 appcast、不能自动更新；正式发布用 --release）"
fi
