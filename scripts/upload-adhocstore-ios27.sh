#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
XCODE_APP="${XCODE_APP:-/Applications/Xcode-beta.app}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/macrodex-xcode27-adhoc-build}"
OUT_DIR="${OUT_DIR:-/tmp/macrodex-adhoc-ipa-${BUILD_NUMBER}}"
APP_SLUG="${ADHOCSTORE_APP:-macrodex}"
NOTES="${NOTES:-Xcode 27 local build.}"

if [[ ! -d "$XCODE_APP" ]]; then
  echo "Missing Xcode beta at $XCODE_APP" >&2
  exit 1
fi

if ! command -v adhocstore >/dev/null 2>&1; then
  echo "Missing adhocstore CLI" >&2
  exit 1
fi

adhocstore whoami >/dev/null

export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"

xcodebuild \
  -project "$ROOT_DIR/Macrodex.xcodeproj" \
  -scheme Macrodex \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/Macrodex.app"
IPA_PATH="$OUT_DIR/Macrodex-iOS27-${BUILD_NUMBER}-unsigned.ipa"
SIGNED_IPA_PATH="$OUT_DIR/Macrodex-iOS27-${BUILD_NUMBER}-signed.ipa"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/Payload"
cp -R "$APP_PATH" "$OUT_DIR/Payload/"
(cd "$OUT_DIR" && /usr/bin/zip -qry "$IPA_PATH" Payload)

adhocstore upload \
  --ipa "$IPA_PATH" \
  --app "$APP_SLUG" \
  --sign \
  --require-reprovision \
  --signed-ipa-out "$SIGNED_IPA_PATH" \
  --notes "$NOTES"

adhocstore releases list --app "$APP_SLUG"
