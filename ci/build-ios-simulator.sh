#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

xcodebuild \
  -project "$ROOT_DIR/Macrodex.xcodeproj" \
  -scheme Macrodex \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  build \
  -derivedDataPath "$ROOT_DIR/.local-ci/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES
