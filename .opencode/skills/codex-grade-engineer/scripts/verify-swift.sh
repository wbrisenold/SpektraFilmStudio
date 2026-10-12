#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP'
Verify a Swift package or Xcode macOS project WITHOUT guessing a scheme.

Usage:
  bash verify-swift.sh [--root DIR] [--dry-run] [--no-tests] [--lint]
  bash verify-swift.sh --project App.xcodeproj --scheme RealScheme [--root DIR]
  bash verify-swift.sh --workspace App.xcworkspace --scheme RealScheme [--root DIR]

Options:
  --root DIR           project root (defaults to current directory)
  --project PATH       Xcode .xcodeproj path (relative to --root, or absolute)
  --workspace PATH     Xcode .xcworkspace path (relative to --root, or absolute)
  --scheme NAME        actual shared Xcode scheme; required for Xcode route
  --configuration NAME Xcode Debug/Release (default Debug)
  --no-tests           build only; report tests as NOT RUN
  --lint               additionally run swiftlint if installed (absence => error)
  --dry-run            print commands without running them; NOT a validation
  --help               this text

For SwiftPM auto-detection, Package.swift must exist at --root.
Xcode testable schemes are expected for tests; use --no-tests otherwise.
Host OS/build environment and minimum deployment target must be checked separately.
HELP
}

ROOT="$PWD"
PROJECT=''
WORKSPACE=''
SCHEME=''
CONFIG='Debug'
DRY=0
TESTS=1
LINT=0

while (( $# > 0 )); do
  case "$1" in
    --root|--project|--workspace|--scheme|--configuration)
      if (( $# < 2 )); then echo "ERROR: Missing value for $1" >&2; exit 2; fi
      case "$1" in
        --root) ROOT="$2" ;;
        --project) PROJECT="$2" ;;
        --workspace) WORKSPACE="$2" ;;
        --scheme) SCHEME="$2" ;;
        --configuration) CONFIG="$2" ;;
      esac
      shift 2 ;;
    --no-tests) TESTS=0; shift ;;
    --dry-run) DRY=1; shift ;;
    --lint) LINT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$ROOT" ]]; then echo "ERROR: root directory not found: $ROOT" >&2; exit 2; fi
ROOT="$(cd "$ROOT" && pwd)"
cd "$ROOT"

if [[ -n "$PROJECT" && -n "$WORKSPACE" ]]; then
  echo 'ERROR: --project and --workspace are mutually exclusive.' >&2
  exit 2
fi

run_cmd() {
  printf '\nRUN:'
  printf ' %q' "$@"
  printf '\n'
  if (( DRY == 0 )); then "$@"; else echo 'NOT RUN (dry-run)'; fi
}

if [[ -n "$PROJECT" || -n "$WORKSPACE" ]]; then
  if [[ -z "$SCHEME" ]]; then echo 'ERROR: Xcode route requires --scheme from xcodebuild -list.' >&2; exit 2; fi
  if [[ -n "$PROJECT" ]]; then
    if [[ ! -d "$PROJECT" ]]; then echo "ERROR: no such .xcodeproj: $PROJECT" >&2; exit 2; fi
    XCODE_SELECTOR=(-project "$PROJECT")
  else
    if [[ ! -d "$WORKSPACE" ]]; then echo "ERROR: no such .xcworkspace: $WORKSPACE" >&2; exit 2; fi
    XCODE_SELECTOR=(-workspace "$WORKSPACE")
  fi
  if (( DRY == 0 )); then
    [[ "$(uname -s)" == 'Darwin' ]] || { echo 'ERROR: xcodebuild requires macOS.' >&2; exit 2; }
    command -v xcodebuild >/dev/null || { echo 'ERROR: xcodebuild not installed.' >&2; exit 2; }
    xcodebuild -version
  fi
  run_cmd xcodebuild "${XCODE_SELECTOR[@]}" -scheme "$SCHEME" -configuration "$CONFIG" -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
  if (( TESTS == 1 )); then
    run_cmd xcodebuild "${XCODE_SELECTOR[@]}" -scheme "$SCHEME" -configuration "$CONFIG" -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
  else
    echo 'Tests: NOT RUN (--no-tests)'
  fi
else
  if [[ ! -f Package.swift ]]; then
    echo 'ERROR: Package.swift not found. For Xcode apps, specify --project/--workspace and --scheme.' >&2
    exit 2
  fi
  if (( DRY == 0 )); then
    command -v swift >/dev/null || { echo 'ERROR: Swift toolchain is unavailable.' >&2; exit 2; }
    swift --version
  fi
  run_cmd swift build
  if (( TESTS == 1 )); then
    run_cmd swift test
  else
    echo 'Tests: NOT RUN (--no-tests)'
  fi
fi

if (( LINT == 1 )); then
  if (( DRY == 0 )); then
    command -v swiftlint >/dev/null || { echo 'ERROR: --lint requested but swiftlint unavailable.' >&2; exit 2; }
  fi
  run_cmd swiftlint lint --strict
else
  echo 'SwiftLint: NOT RUN (use --lint to request)'
fi

if command -v git >/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  run_cmd git diff --check
fi

if (( DRY == 1 )); then
  echo 'RESULT: NOT VERIFIED (dry-run only)'
else
  echo 'RESULT: All requested build/test/lint commands returned success.'
  echo 'NOTE: GUI correctness, oldest-macOS runtime, and production performance are NOT verified here.'
fi
