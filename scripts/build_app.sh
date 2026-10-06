#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The final .app must be linked on macOS with Xcode/Metal installed." >&2
  exit 2
fi

for tool in xcrun swift lipo python3 git; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required build tool: $tool" >&2
    exit 8
  fi
done

# Intel-only builds should never retain old arm64 scratch trees. Removing them prevents
# stale architecture artifacts from being selected and recovers disk space from old builds.
rm -rf "$ROOT/.build/swift-arm64" "$ROOT/.build/native-arm64"

MIN_FREE_GB="${SPEKTRAFILM_MIN_FREE_GB:-8}"
if [[ ! "$MIN_FREE_GB" =~ ^[0-9]+$ ]]; then
  echo "SPEKTRAFILM_MIN_FREE_GB must be an integer." >&2
  exit 9
fi
AVAILABLE_KB="$(df -Pk "$ROOT" | awk 'NR==2 {print $4}')"
REQUIRED_KB=$((MIN_FREE_GB * 1024 * 1024))
if [[ -z "$AVAILABLE_KB" || "$AVAILABLE_KB" -lt "$REQUIRED_KB" ]]; then
  AVAILABLE_GB=$(( ${AVAILABLE_KB:-0} / 1024 / 1024 ))
  echo "Not enough free disk space for a safe release build: ${AVAILABLE_GB} GB free, ${MIN_FREE_GB} GB required." >&2
  echo "Remove old .build/dist data or lower SPEKTRAFILM_MIN_FREE_GB only if you know the build fits." >&2
  exit 10
fi

VERSION="${SPEKTRAFILM_VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
BUILD_NUMBER="${SPEKTRAFILM_BUILD_NUMBER:-1}"
CLEAN="${SPEKTRAFILM_CLEAN:-0}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Invalid VERSION '$VERSION'." >&2
  exit 4
fi
if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Invalid build number '$BUILD_NUMBER'." >&2
  exit 5
fi

if [[ "$CLEAN" == "1" ]]; then
  echo "Clean build requested." >&2
  rm -rf "$ROOT/.build/swift-x86_64" "$ROOT/.build/native-x86_64" "$ROOT/.build/native"
fi

python3 "$ROOT/scripts/qa_stage5.py"
"$ROOT/scripts/bootstrap_native.sh"

if [[ ! -f "$ROOT/Vendor/onnxruntime/lib/libonnxruntime.dylib" && ! -f "$ROOT/Vendor/onnxruntime/lib/libonnxruntime.1.30.0.dylib" ]]; then
  echo "Stage 3 AI runtime missing. Run ./PREPARE_STAGE3_AI_MODELS.command first." >&2
  exit 12
fi

NATIVE_LIB="$ROOT/.build/native/libSpektraFilmNativeCore.a"
NATIVE_ARCHS="$(lipo -archs "$NATIVE_LIB" 2>/dev/null || true)"
if [[ " $NATIVE_ARCHS " != *" x86_64 "* ]]; then
  echo "Native core architecture mismatch before Swift link. Expected x86_64, got: ${NATIVE_ARCHS:-unknown}" >&2
  exit 11
fi

SCRATCH="$ROOT/.build/swift-x86_64"
swift build -c release --arch x86_64 --scratch-path "$SCRATCH" >&2

BIN="$(find "$SCRATCH" -type f -name SpektraFilmStudio -perm +111 2>/dev/null | grep -v '/plugins/' | head -n 1 || true)"
if [[ -z "$BIN" ]]; then
  echo "Could not locate SwiftPM x86_64 release executable." >&2
  exit 3
fi

ARCHS="$(lipo -archs "$BIN" 2>/dev/null || true)"
if [[ "$ARCHS" != *x86_64* ]]; then
  echo "Expected x86_64 executable, got: ${ARCHS:-unknown}" >&2
  exit 6
fi

rm -rf "$ROOT/dist"
mkdir -p "$ROOT/dist"

APP="$ROOT/dist/SpektraFilmStudio.app"
CONTENTS="$APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks" "$CONTENTS/Resources/AIModels"
cp "$BIN" "$CONTENTS/MacOS/SpektraFilmStudio"
cp "$ROOT/Vendor/onnxruntime/lib/"libonnxruntime*.dylib "$CONTENTS/Frameworks/"
cp "$ROOT/Resources/AIModels/"*.onnx "$CONTENTS/Resources/AIModels/"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS/MacOS/SpektraFilmStudio" 2>/dev/null || true
strip -S "$CONTENTS/MacOS/SpektraFilmStudio" 2>/dev/null || true

cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/SpektraFilm.icns"
cp "$ROOT/Resources/SpektraFilm.metallib" "$CONTENTS/Resources/"
cp "$ROOT/Resources/SpektraHanatos2025Spectra.f32" "$CONTENTS/Resources/"
cp "$ROOT/Resources/SpektraOutputGamutCompression.f32" "$CONTENTS/Resources/"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>SpektraFilmStudio</string>
  <key>CFBundleIdentifier</key><string>org.spektrafilm.fast</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>SpektraFilm Studio</string>
  <key>CFBundleDisplayName</key><string>SpektraFilm Studio</string>
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

SIGN_IDENTITY="${SPEKTRAFILM_CODESIGN_IDENTITY:--}"
# Sign embedded dylibs first so the bundle's nested-code verification passes.
for dylib in "$CONTENTS"/Frameworks/libonnxruntime*.dylib; do
  [[ -e "$dylib" ]] && codesign --force --sign "$SIGN_IDENTITY" "$dylib"
done
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

ZIP="$ROOT/dist/SpektraFilmStudio-${VERSION}-macOS-intel.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(
  cd "$ROOT/dist"
  shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS.txt
)

cat > "$ROOT/dist/build-info.txt" <<INFO
version=${VERSION}
build_number=${BUILD_NUMBER}
architectures=x86_64
native_core_commit=8f6651858f439a99b7202b4b8dea59e344dadf5d
minimum_macos=15.0
incremental_build=$([[ "$CLEAN" == "1" ]] && echo no || echo yes)
codesign_identity=${SIGN_IDENTITY}
INFO

echo
echo "Built: $APP"
echo "ZIP:   $ZIP"
echo "Version: $VERSION ($BUILD_NUMBER)"
echo "Architecture: x86_64"
file "$CONTENTS/MacOS/SpektraFilmStudio"
