#!/usr/bin/env bash
set -euo pipefail
command -v python3 >/dev/null || { echo 'Install python3.' >&2; exit 2; }
command -v rclone >/dev/null || { echo 'Install rclone >=1.69 (iCloud Drive backend required).' >&2; exit 2; }
python3 --version
rclone version | head -2
rclone version | head -1 | grep -Eq 'rclone v1\.(6[9]|[7-9][0-9])|rclone v[2-9]\.' || {
  echo 'rclone version may lack iCloud Drive; install a current official release.' >&2; exit 2;
}
[[ $(uname -s) == Linux ]] || echo 'Warning: Oracle transfer host was designed for Linux.' >&2
if [[ -n "${RCLONE_CONFIG:-}" ]]; then
  echo "Custom rclone config path configured."
fi
rclone lsd 'icloud:' >/dev/null || { echo 'iCloud backend unavailable. Run rclone config, connect service=drive, authenticate with 2FA.' >&2; exit 3; }
echo 'Oracle transfer host and iCloud rclone backend appear reachable. Run the pilot next.'
