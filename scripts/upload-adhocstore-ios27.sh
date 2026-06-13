#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
XCODE_APP="${XCODE_APP:-/Applications/Xcode-beta.app}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/macrodex-xcode27-adhoc-build}"
OUT_DIR="${OUT_DIR:-/tmp/macrodex-adhoc-ipa-${BUILD_NUMBER}}"
APP_SLUG="${ADHOCSTORE_APP:-macrodex}"
NOTES="${NOTES:-Xcode 27 local build.}"
CONFIG_PATH="${ADHOCSTORE_CONFIG:-$HOME/.adhocstore/config.json}"

urlencode() {
  printf '%s' "$1" | jq -sRr @uri
}

direct_upload_signed_ipa() {
  if [[ ! -f "$SIGNED_IPA_PATH" ]]; then
    echo "AdHocStore CLI upload failed and no signed IPA was produced at $SIGNED_IPA_PATH." >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "AdHocStore CLI upload failed and jq is required for the direct API fallback." >&2
    return 1
  fi

  local token base_url org_slug version size_bytes digest file_name release_notes upload_url
  token="${ADHOCSTORE_TOKEN:-$(jq -r '.token // empty' "$CONFIG_PATH")}"
  base_url="${ADHOCSTORE_URL:-$(jq -r '.baseUrl // "https://appstore.djdev.me"' "$CONFIG_PATH")}"
  org_slug="${ADHOCSTORE_ORG:-$(jq -r '.organization.slug // .organization.id // empty' "$CONFIG_PATH")}"
  version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Info.plist")"
  size_bytes="$(stat -f '%z' "$SIGNED_IPA_PATH")"
  digest="$(shasum -a 256 "$SIGNED_IPA_PATH" | awk '{print $1}')"
  file_name="$(urlencode "$(basename "$SIGNED_IPA_PATH")")"
  release_notes="$(urlencode "$NOTES")"

  if [[ -z "$token" || -z "$org_slug" ]]; then
    echo "AdHocStore direct upload fallback needs a token and organization in $CONFIG_PATH." >&2
    return 1
  fi

  upload_url="${base_url%/}/api/v1/orgs/${org_slug}/apps/${APP_SLUG}/builds?fileName=${file_name}&version=$(urlencode "$version")&buildNumber=$(urlencode "$BUILD_NUMBER")&channelSlug=dev&releaseNotes=${release_notes}&sizeBytes=${size_bytes}"

  echo "AdHocStore CLI upload failed after signing; falling back to direct API upload for $(basename "$SIGNED_IPA_PATH")."
  curl --http1.1 --fail-with-body --silent --show-error \
    -X POST "$upload_url" \
    -H "Authorization: Bearer ${token}" \
    -H "x-adhocstore-org: ${org_slug}" \
    -H "content-type: application/octet-stream" \
    -H "content-length: ${size_bytes}" \
    -H "x-adhocstore-sha256: ${digest}" \
    --data-binary "@${SIGNED_IPA_PATH}"
  echo
}

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

set +e
adhocstore upload \
  --ipa "$IPA_PATH" \
  --app "$APP_SLUG" \
  --sign \
  --require-reprovision \
  --signed-ipa-out "$SIGNED_IPA_PATH" \
  --notes "$NOTES" 2>&1 | tee "$OUT_DIR/adhocstore-upload.log"
UPLOAD_STATUS=${PIPESTATUS[0]}
set -e

if [[ "$UPLOAD_STATUS" -ne 0 ]]; then
  if grep -q "fetch failed" "$OUT_DIR/adhocstore-upload.log"; then
    direct_upload_signed_ipa
  else
    exit "$UPLOAD_STATUS"
  fi
fi

adhocstore releases list --app "$APP_SLUG"
