#!/bin/bash
set -u
cd "$(dirname "$0")"

clear
echo "SpektraFilm Intel local macOS build"
echo "No GitHub repository or GitHub Actions required."
echo

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This build must be run on macOS."
  read -n 1 -s -r -p "Press any key to close..."
  exit 2
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "Xcode / Xcode Command Line Tools are required."
  echo "Install Xcode 26, open it once, then run this file again."
  read -n 1 -s -r -p "Press any key to close..."
  exit 3
fi

./scripts/build_app.sh
STATUS=$?
echo
if [[ $STATUS -eq 0 ]]; then
  echo "Build complete. Opening dist/SpektraFilm.app location..."
  open dist
else
  echo "Build failed with status $STATUS."
fi
echo
read -n 1 -s -r -p "Press any key to close..."
exit $STATUS
