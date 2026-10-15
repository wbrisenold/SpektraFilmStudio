#!/usr/bin/env bash
# CUA-driven workflow: launch SpektraFilmStudio, navigate to Edit, capture crash.
# Usage: ./scripts/cua_edit_page_test.sh [path-to-app]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/dist/SpektraFilmStudio.app}"
CUA=/Users/A1990/.local/bin/cua-driver
SHOT_DIR=/tmp/cua_shots
mkdir -p "$SHOT_DIR"

step() { printf '\n=== %s ===\n' "$1"; }
shot() { $CUA call get_desktop_state --args "{\"max_image_dimension\": 1600}" > "$SHOT_DIR/$1.json" 2>&1; echo "  screenshot -> $SHOT_DIR/$1.json"; }

step "0. Clean crash reports"
rm -f ~/Library/Logs/DiagnosticReports/SpektraFilmStudio* 2>/dev/null || true

step "1. Launch app"
$CUA call launch_app --args "{\"app\": \"$APP\"}" 2>&1 | head -3
sleep 4

step "2. Screenshot: library page"
shot "01_library"

step "3. Get accessibility tree (find Edit controls)"
$CUA call get_accessibility_tree 2>&1 | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for w in d.get('windows', [])[:10]:
        print(f\"  {w.get('owner','?'):30s} {w.get('title','')[:50]:50s} {w.get('bounds',{})}\")
except Exception as e:
    print('  parse error:', e)
"

step "4. Select first photo (double-click top-left thumbnail area)"
# The library grid starts ~x=200, y=150 in a 1600x1000 window; adjust to actual window.
$CUA call double_click --args '{"x": 300, "y": 250}' 2>&1 | head -2
sleep 2
shot "02_after_photo_select"

step "5. Navigate to Edit workspace (press '3' or click Edit tab)"
# Try keyboard shortcut first; fall back to clicking the Edit tab by AX tree.
$CUA call press_key --args '{"key": "3"}' 2>&1 | head -2
sleep 2
shot "03_after_edit_nav"

step "6. If still on library, click Edit tab via accessibility tree"
$CUA call get_accessibility_tree 2>&1 | python3 -c "
import sys, json
d = json.load(sys.stdin)
# Find the Edit tab button
for el in d.get('elements', []):
    label = el.get('label', el.get('title', ''))
    if 'edit' in label.lower() or 'develop' in label.lower():
        print(f\"  found: {el.get('element_token','')} label={label} bounds={el.get('bounds',{})}\")
" 2>/dev/null || echo "  (AX tree parse skipped)"

step "7. Wait and screenshot the edit page"
sleep 3
shot "04_edit_page"

step "8. Check for crash"
CRASH=$(ls -t ~/Library/Logs/DiagnosticReports/SpektraFilmStudio* 2>/dev/null | head -1)
if [ -n "$CRASH" ]; then
    echo "  CRASH DETECTED: $CRASH"
    echo "  --- crash reason ---"
    grep -A2 "Termination Reason\|Exception Type\|Application Specific" "$CRASH" 2>/dev/null | head -12
    echo "  --- last 5 frames ---"
    grep -E "^[0-9]+ " "$CRASH" 2>/dev/null | tail -8
else
    echo "  no crash report found"
fi

step "9. Done. Screenshots in $SHOT_DIR"
ls -la "$SHOT_DIR"
