#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
(cd web && npm run check)
xcodegen generate
xcodebuild -project donemd.xcodeproj -scheme donemd -configuration Debug \
  -destination "platform=macOS" -derivedDataPath "${CHECK_DERIVED_DATA:-$PWD/dist/CheckDerivedData}" test
