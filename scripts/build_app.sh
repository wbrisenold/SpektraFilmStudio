#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The final .app must be linked on macOS with Xcode/Metal installed." >&2
  exit 2
fi

VERSION="${SPEKTRAFILM_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD_NUMBER="${SPEKTRAFILM_BUILD_NUMBER:-1}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid VERSION '$VERSION'. Expected a semver-like value such as 0.1.0 or 0.1.0-beta.1." >&2
  exit 4
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid build number '$BUILD_NUMBER'. It must contain digits only." >&2
  exit 5
fi

"$ROOT/scripts/bootstrap_native.sh"

rm -rf "$ROOT/dist"
mkdir -p "$ROOT/dist"

build_swift_arch() {
  local ARCH="$1"
  local SCRATCH="$ROOT/.build/swift-$ARCH"
  rm -rf "$SCRATCH"
  swift build -c release --arch "$ARCH" --scratch-path "$SCRATCH" >&2
  local BIN_ARCH
  BIN_ARCH="$(find "$SCRATCH" -type f -name SpektraFilmFast -perm +111 2>/dev/null | grep -v '/plugins/' | head -n 1 || true)"
  if [[ -z "$BIN_ARCH" ]]; then
    echo "Could not locate SwiftPM $ARCH release executable." >&2
    exit 3
  fi
  local FOUND_ARCHS
  FOUND_ARCHS="$(lipo -archs "$BIN_ARCH" 2>/dev/null || true)"
  if [[ "$FOUND_ARCHS" != *"$ARCH"* ]]; then
    echo "Expected $ARCH Swift executable, got: ${FOUND_ARCHS:-unknown}" >&2
    exit 6
  fi
  printf '%s\n' "$BIN_ARCH"
}

BIN_ARM64="$(build_swift_arch arm64)"
BIN_X86_64="$(build_swift_arch x86_64)"
UNIVERSAL_BIN="$ROOT/.build/SpektraFilmFast-universal"
lipo -create "$BIN_ARM64" "$BIN_X86_64" -output "$UNIVERSAL_BIN"
BIN="$UNIVERSAL_BIN"

ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
if [[ "$ARCHS" != *arm64* || "$ARCHS" != *x86_64* ]]; then
  echo "Expected Universal Swift executable, got architectures: ${ARCHS:-unknown}" >&2
  exit 6
fi

APP="$ROOT/dist/SpektraFilm.app"
CONTENTS="$APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/SpektraFilm"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/SpektraFilm.icns"
cp "$ROOT/Resources/SpektraFilm.metallib" "$CONTENTS/Resources/"
cp "$ROOT/Resources/SpektraHanatos2025Spectra.f32" "$CONTENTS/Resources/"
cp "$ROOT/Resources/SpektraOutputGamutCompression.f32" "$CONTENTS/Resources/"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>SpektraFilm</string>
  <key>CFBundleIdentifier</key><string>org.spektrafilm.fast</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>SpektraFilm</string>
  <key>CFBundleDisplayName</key><string>spektrafilm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleIconFile</key><string>SpektraFilm.icns</string>
  <key>CFBundleIconName</key><string>SpektraFilm</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict><key>CFBundleTypeName</key><string>SpektraFilm Project</string><key>CFBundleTypeRole</key><string>Editor</string><key>CFBundleTypeExtensions</key><array><string>spektrafilm</string></array></dict>
    <dict><key>CFBundleTypeName</key><string>SpektraFilm Preset</string><key>CFBundleTypeRole</key><string>Editor</string><key>CFBundleTypeExtensions</key><array><string>sfpreset</string></array></dict>
  </array>
</dict></plist>
PLIST

plutil -lint "$CONTENTS/Info.plist"
ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist")"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CONTENTS/Info.plist")"
[[ "$ACTUAL_VERSION" == "$VERSION" ]] || { echo "App version verification failed." >&2; exit 7; }
[[ "$ACTUAL_BUILD" == "$BUILD_NUMBER" ]] || { echo "App build-number verification failed." >&2; exit 8; }

SIGN_IDENTITY="${SPEKTRAFILM_CODESIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Using ad-hoc signing (development/CI build)." >&2
  codesign --force --sign - "$APP"
else
  echo "Signing with Developer ID identity: $SIGN_IDENTITY" >&2
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP="$ROOT/dist/SpektraFilm-${VERSION}-macOS-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(
  cd "$ROOT/dist"
  shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS.txt
)

cat > "$ROOT/dist/build-info.txt" <<INFO
version=${VERSION}
build_number=${BUILD_NUMBER}
architectures=${ARCHS}
native_core_commit=8f6651858f439a99b7202b4b8dea59e344dadf5d
minimum_macos=15.0
codesign_identity=${SIGN_IDENTITY}
INFO

echo
echo "Built: $APP"
echo "ZIP:   $ZIP"
echo "Version: $VERSION ($BUILD_NUMBER)"
echo "Architectures: $ARCHS"
file "$CONTENTS/MacOS/SpektraFilm"
