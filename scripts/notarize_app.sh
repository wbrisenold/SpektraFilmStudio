#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${SPEKTRAFILM_VERSION:-$(tr -d '[:space:]' < VERSION)}"
APP="$ROOT/dist/SpektraFilmStudio.app"
ZIP="$ROOT/dist/SpektraFilmStudio-${VERSION}-macOS-intel.zip"

: "${APPLE_ID:?APPLE_ID is required for notarization}"
: "${APPLE_APP_SPECIFIC_PASSWORD:?APPLE_APP_SPECIFIC_PASSWORD is required for notarization}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required for notarization}"

codesign --verify --deep --strict --verbose=2 "$APP"
SIGN_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
echo "$SIGN_INFO" | grep -q 'Authority=Developer ID Application:' || {
  echo "Release app is not signed with Developer ID Application." >&2
  exit 2
}
echo "$SIGN_INFO" | grep -q 'runtime' || {
  echo "Release app is missing hardened runtime." >&2
  exit 2
}
TEMP_ZIP="$ROOT/dist/notarization-upload.zip"
rm -f "$TEMP_ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP_ZIP"

xcrun notarytool submit "$TEMP_ZIP" \
  --apple-id "$APPLE_ID" \
  --password "$APPLE_APP_SPECIFIC_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

rm -f "$TEMP_ZIP" "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(
  cd "$ROOT/dist"
  shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS.txt
)

echo "Notarized and stapled: $APP"
