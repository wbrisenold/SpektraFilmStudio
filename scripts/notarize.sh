#!/bin/bash
# Sign with Developer ID + hardened runtime, notarize with Apple, staple, verify.
#
#   ./scripts/notarize.sh --check   report what is missing, change nothing (default)
#   ./scripts/notarize.sh --run     do it
#
# Credentials are never stored here. Two supported ways to authenticate:
#
#   1. keychain profile (interactive setup, recommended for a human)
#        xcrun notarytool store-credentials spektra \
#          --apple-id you@example.com --team-id TEAMID
#        export NOTARY_PROFILE=spektra
#
#   2. App Store Connect API key (non-interactive, recommended for CI)
#        export NOTARY_KEY_ID=... NOTARY_ISSUER_ID=... NOTARY_KEY_PATH=/path/AuthKey_xxx.p8
#
# Signing identity comes from SPEKTRAFILM_SIGN_IDENTITY, or is auto-detected as the
# first "Developer ID Application: ..." identity in the keychain.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="dist/SpektraFilmStudio.app"
ENTITLEMENTS="scripts/SpektraFilm.entitlements"
ZIP_NAME="SpektraFilmStudio-${VERSION}-macOS-intel.zip"

MODE="--check"
[ "${1:-}" = "--run" ] && MODE="--run"

BLOCKERS=0
block() { printf '  BLOCKER  %s\n' "$1"; BLOCKERS=$((BLOCKERS + 1)); }
note()  { printf '  ok       %s\n' "$1"; }
warn()  { printf '  warning  %s\n' "$1"; }

# ---------------------------------------------------------------- preflight --

check_prereqs() {
  echo "== notarytool =="
  if xcrun notarytool --version >/dev/null 2>&1; then
    note "notarytool $(xcrun notarytool --version 2>&1 | awk '{print $NF}')"
  else
    block "notarytool unavailable. Install Xcode (Command Line Tools only is not enough for --notarytool file submission)."
  fi

  echo
  echo "== signing identity =="
  local identity
  identity="$(find_identity)"
  if [ -n "$identity" ]; then
    note "identity: $identity"
  else
    block "no Developer ID Application certificate in the keychain.
          Join the Apple Developer Program (https://developer.apple.com/programs/enroll/, \$99/yr),
          then create a Developer ID Application certificate in Xcode > Settings > Accounts,
          or install a .p12 with: security import cert.p12 -k ~/Library/Keychains/login.keychain-db"
  fi

  echo
  echo "== notary credentials =="
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    note "using keychain profile: $NOTARY_PROFILE"
  elif [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ] && [ -n "${NOTARY_KEY_PATH:-}" ]; then
    if [ -f "${NOTARY_KEY_PATH}" ]; then
      note "using API key $NOTARY_KEY_ID"
    else
      block "NOTARY_KEY_PATH does not exist: $NOTARY_KEY_PATH"
    fi
  else
    block "no credentials. Set NOTARY_PROFILE (after notarytool store-credentials),
          or NOTARY_KEY_ID + NOTARY_ISSUER_ID + NOTARY_KEY_PATH.
          See scripts/notarize.sh header."
  fi

  echo
  echo "== network =="
  if xcrun notarytool history --keychain-profile "${NOTARY_PROFILE:-__none__}" >/dev/null 2>&1 \
     || [ -n "${NOTARY_PROFILE:-}" ]; then
    note "reachable (Apple responded)"
  else
    warn "could not reach Apple's notary service. Needs network; notarization is a server-side review."
  fi
}

find_identity() {
  if [ -n "${SPEKTRAFILM_SIGN_IDENTITY:-}" ]; then
    security find-identity -v -p codesigning | awk -v want="$SPEKTRAFILM_SIGN_IDENTITY" \
      '$0 ~ want { sub(/^.*"/, "", $0); sub(/".*$/, "", $0); print; exit }'
  else
    security find-identity -v -p codesigning | awk '/Developer ID Application/ {
      sub(/^.*"/, "", $0); sub(/".*$/, "", $0); print; exit }'
  fi
}

notary_auth_args() {
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    printf '%s' "--keychain-profile $NOTARY_PROFILE"
  else
    printf '%s' "--key $NOTARY_KEY_PATH --key-id $NOTARY_KEY_ID --issuer $NOTARY_ISSUER_ID"
  fi
}

# ------------------------------------------------------------------- checks --

check_artifact() {
  echo "== built artifact =="
  if [ -d "$APP" ]; then
    note "found $APP (version $VERSION)"
  else
    block "$APP does not exist. Build first: SPEKTRAFILM_CLEAN=1 ./BUILD_ON_MAC.command"
    return
  fi

  echo
  echo "== nested code (everything executable must be signed) =="
  # A .app with a Frameworks/ dir, XPCServices, or Plugins has nested code that
  # codesign signs only with --deep. Nested unsigned code is the usual cause of a
  # notarization rejection, so surface it explicitly.
  local nested
  nested="$(find "$APP/Contents" -mindepth 2 -type d \( -name Frameworks -o -name XPCServices -o -name Plugins -o -name Helper \) 2>/dev/null || true)"
  if [ -n "$nested" ]; then
    warn "nested code directories present; --deep will sign them:"
    printf '           %s\n' $nested
  else
    note "no nested code (single binary) -- nothing for --deep to miss"
  fi

  echo
  echo "== entitlements =="
  # Count real keys, not lines: PlistBuddy prints an empty dict as two lines
  # ("Dict {" / "}"), which reads as 2 entries when there are none.
  local keys
  keys="$(plutil -convert json -o - "$ENTITLEMENTS" 2>/dev/null | /usr/bin/python3 -c \
    'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || echo INVALID)"
  case "$keys" in
    INVALID) block "$ENTITLEMENTS is not a valid plist" ;;
    0) note "$ENTITLEMENTS is an empty, valid plist (expected: app needs no entitlements)" ;;
    *) note "$ENTITLEMENTS declares $keys key(s) -- each needs a justification at review:"; plutil -p "$ENTITLEMENTS" | sed 's/^/           /' ;;
  esac

  echo
  echo "== architecture =="
  local arch
  arch="$(lipo -archs "$APP/Contents/MacOS/SpektraFilmStudio" 2>/dev/null || echo unknown)"
  note "built arch: $arch"
  if [ "$arch" != "x86_64" ]; then
    warn "expected x86_64 for this release line; got '$arch'"
  fi
}

# ---------------------------------------------------------------------- run --

do_sign() {
  local identity="$1"
  echo "== signing with Developer ID + hardened runtime =="
  # --options runtime  : required for notarization
  # --timestamp        : required for Developer ID; proves the signature was valid
  #                      at signing time and survives cert expiry
  # --entitlements     : empty on purpose, see the file for the reasoning
  codesign --force --sign "$identity" \
           --options runtime \
           --timestamp \
           --entitlements "$ENTITLEMENTS" \
           "$APP"

  # Fail loudly if the hardened runtime flag did not stick. Notarization will
  # reject the upload otherwise, and the rejection comes back asynchronously.
  # codesign prints e.g. "CodeDirectory v=20500 ... flags=0x10002(adhoc,runtime) ..."
  # -- note there is no "key: value" colon on that line, so match the flags token
  # itself rather than splitting on a delimiter.
  local flags
  flags="$(codesign -dv --verbose=4 "$APP" 2>&1 | grep -oE 'flags=0x[0-9a-f]+\([^)]*\)' | head -1 || true)"
  if [ -z "$flags" ]; then
    echo "  ERROR: could not read CodeDirectory flags from codesign output"; exit 1
  fi
  case "$flags" in
    *runtime*) note "hardened runtime enabled ($flags)" ;;
    *) echo "  ERROR: hardened runtime flag missing ($flags)"; echo "  Notarization will reject this upload."; exit 1 ;;
  esac

  echo
  echo "== verifying signature before upload =="
  codesign --verify --deep --strict --verbose=2 "$APP"
  note "codesign --verify --deep --strict passed"
}

do_notarize() {
  # notarytool accepts .zip/.dmg/.pkg, NOT a bare .app, so the app must be zipped
  # for submission. After stapling we rebuild the distributable zip from the
  # stapled bundle.
  local submit_zip="dist/.notary-submit-$VERSION.zip"
  echo "== packaging for submission =="
  rm -f "$submit_zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$submit_zip"
  note "submission archive: $(du -h "$submit_zip" | cut -f1)"

  echo
  echo "== submitting to Apple (this takes minutes; they review it) =="
  # shellcheck disable=SC2046
  xcrun notarytool submit "$submit_zip" $(notary_auth_args) --wait --output-format json > /tmp/notary-result.json
  local status
  status="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open("/tmp/notary-result.json")).get("status","UNKNOWN"))' 2>/dev/null || echo UNKNOWN)"
  echo "  notarytool status: $status"
  if [ "$status" != "Accepted" ]; then
    echo
    echo "  Submission was NOT accepted. Apple returns this asynchronously, so the"
    echo "  reason is in the result rather than the exit code:"
    /usr/bin/python3 - <<'PY' 2>/dev/null || cat /tmp/notary-result.json
import json
d = json.load(open("/tmp/notary-result.json"))
for i in d.get("issues") or []:
    if i.get("severity") in ("error", "warning"):
        print(f"  [{i['severity']}] {i.get('code')}: {i.get('message')}")
        if i.get("docUrl"):
            print(f"          {i['docUrl']}")
PY
    exit 1
  fi

  echo
  echo "== stapling ticket =="
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"

  echo
  echo "== rebuilding distributable zip from the stapled bundle =="
  rm -f "dist/$ZIP_NAME"
  ( cd dist && ditto -c -k --sequesterRsrc --keepParent SpektraFilmStudio.app "$ZIP_NAME" )
  rm -f "$submit_zip"
  note "rebuilt dist/$ZIP_NAME"
}

do_verify() {
  echo "== Gatekeeper assessment =="
  # Check that assessments are actually enabled first. With them disabled spctl
  # reports "accepted" with an override and has assessed nothing at all.
  if ! spctl --status 2>/dev/null | grep -qi "assessments enabled"; then
    warn "Gatekeeper assessments are DISABLED on this machine (spctl --status).
          The check below will not be meaningful. Check on a clean Mac or enable
          assessments before trusting it."
  fi

  local out
  out="$(spctl -a -vvv -t exec "$APP" 2>&1 || true)"
  printf '  %s\n' "$out"
  if printf '%s' "$out" | grep -q "notarized"; then
    note "Gatekeeper: notarized Developer ID"
  else
    echo "  ERROR: Gatekeeper did not report notarized"; exit 1
  fi

  echo
  echo "== rebuilding SHA256SUMS.txt =="
  ( cd dist && shasum -a 256 "$ZIP_NAME" > SHA256SUMS.txt )
  cat "dist/SHA256SUMS.txt" | sed 's/^/  /'

  echo
  echo "== authority check =="
  codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "^Authority|^TeamIdentifier" | sed 's/^/  /'
}

# -------------------------------------------------------------------- main ---

echo "SpektraFilm Studio notarization  (version $VERSION, mode $MODE)"
echo

if [ "$MODE" = "--check" ]; then
  check_prereqs
  check_artifact
  echo
  if [ "$BLOCKERS" -gt 0 ]; then
    echo "$BLOCKERS blocker(s). Notarization is not possible until these are resolved:"
    echo "  1. Enrol in the Apple Developer Program (\$99/yr): https://developer.apple.com/programs/enroll/"
    echo "  2. Create a Developer ID Application certificate (Xcode > Settings > Accounts)."
    echo "  3. Store notarytool credentials, then export NOTARY_PROFILE=..."
    echo
    echo "Everything else is already in place. Re-run --check until this is clean,"
    echo "then ./scripts/notarize.sh --run"
    exit 1
  fi
  echo "All clear. Run: ./scripts/notarize.sh --run"
  exit 0
fi

# --run
check_prereqs
check_artifact
echo
[ "$BLOCKERS" -gt 0 ] && { echo "Fix the blockers above first (or run --check)."; exit 1; }

IDENTITY="$(find_identity)"
[ -n "$IDENTITY" ] || { echo "Could not resolve a Developer ID identity."; exit 1; }

do_sign "$IDENTITY"
do_notarize
do_verify

echo
echo "Notarized and stapled: $APP"
echo "Next: publish dist/$ZIP_NAME and dist/SHA256SUMS.txt per RELEASING.md,"
echo "and drop the Gatekeeper workaround from the release notes."