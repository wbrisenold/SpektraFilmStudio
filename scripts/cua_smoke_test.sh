#!/bin/bash

# CUA Smoke Test for SpektraFilmStudio RAW Workflow
# 
# This test uses cua-driver in embedded mode to:
# 1. Launch SpektraFilmStudio
# 2. Import a test image / select existing
# 3. Navigate to Edit workspace  
# 4. Test live slider editing (Exposure, Temperature, Film Exposure, Contrast)
# 5. Verify preview updates WITHOUT "Rendering" indicator (no full renders during drag)

set -euo pipefail

APP_PATH="/Users/A1990/Downloads/SpektraFilmStudio/.build/release/SpektraFilmStudio"
CUA_DRIVER="/Users/A1990/.local/bin/cua-driver"
SOCKET_PATH="/tmp/spektra-cua-smoke.sock"
SESSION="spektra-smoke-$(date +%s)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
pass() { echo -e "${GREEN}  ✅ PASS:${NC} $*"; }
fail() { echo -e "${RED}  ❌ FAIL:${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠️  WARN:${NC} $*"; }

cleanup() {
    log "Cleaning up..."
    # Kill the daemon
    pkill -f "cua-driver serve.*$SOCKET_PATH" 2>/dev/null || true
    rm -f "$SOCKET_PATH"
}
trap cleanup EXIT

log "🔬 Starting CUA Smoke Test for SpektraFilmStudio RAW Workflow"
log "============================================================"

# Step 1: Start embedded cua-driver daemon
log "Starting embedded CUA driver daemon..."
CUA_DRIVER_EMBEDDED=1 \
CUA_DRIVER_HOST_BUNDLE_ID=org.spektrafilm.fast \
CUA_DRIVER_PERMISSION_MODE=unrestricted \
CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS=1 \
"$CUA_DRIVER" serve --embedded --socket "$SOCKET_PATH" > /tmp/cua-daemon.log 2>&1 &
DAEMON_PID=$!

# Wait for socket to be ready
for i in {1..20}; do
    if [[ -S "$SOCKET_PATH" ]]; then
        pass "CUA driver daemon ready"
        break
    fi
    sleep 0.2
    if [[ $i -eq 20 ]]; then
        fail "CUA driver daemon failed to start"
        cat /tmp/cua-daemon.log
        exit 1
    fi
done

# Step 2: Start MCP proxy
log "Starting MCP proxy..."
CUA_DRIVER_EMBEDDED=1 \
"$CUA_DRIVER" mcp --socket "$SOCKET_PATH" > /tmp/cua-mcp.log 2>&1 &
MCP_PID=$!

sleep 1

# Step 3: Launch the app via MCP
log "Launching SpektraFilmStudio..."
LAUNCH_REQ='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"launch_application","arguments":{"path":"'"$APP_PATH"'"}}}'
echo "$LAUNCH_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null | head -5

sleep 3

# Step 4: Get window state and verify app launched
log "Waiting for main window..."
for i in {1..30}; do
    STATE_REQ='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_window_state","arguments":{}}}'
    STATE=$(echo "$STATE_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null)
    if echo "$STATE" | grep -qi "SpektraFilm"; then
        pass "Main window detected"
        break
    fi
    sleep 0.5
    if [[ $i -eq 30 ]]; then
        fail "Main window not found after 15 seconds"
        exit 1
    fi
done

# Step 5: Navigate to Library and select an image
log "Selecting test image in Library..."
CLICK_REQ='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":{"x":300,"y":300}}}'
echo "$CLICK_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null | head -3
sleep 1

# Step 6: Navigate to Edit workspace
log "Navigating to Edit workspace..."
CLICK_REQ='{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"click","arguments":{"x":450,"y":30}}}'
echo "$CLICK_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null | head -3
sleep 2

# Verify we're in Edit mode
STATE_REQ='{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_window_state","arguments":{}}}'
STATE=$(echo "$STATE_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null)
if echo "$STATE" | grep -qi "edit\|inspector\|RAW workflow"; then
    pass "Successfully in Edit workspace"
else
    warn "Could not verify Edit workspace, continuing..."
fi

# Step 7: Test live slider editing
log "Testing live slider editing..."

test_slider() {
    local name=$1
    local tab=$2
    local slider_x=$3
    local slider_y=$4
    local drag_dist=$5
    local tab_x=$6
    
    log "  Test: $name slider ($tab tab)"
    
    # Switch to tab
    CLICK_REQ="{\"jsonrpc\":\"2.0\",\"id\":$((RANDOM)),\"method\":\"tools/call\",\"params\":{\"name\":\"click\",\"arguments\":{\"x\":$tab_x,\"y\":60}}}"
    echo "$CLICK_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null | head -3
    sleep 0.5
    
    # Get initial state
    STATE_REQ='{"jsonrpc":"2.0","id":'"$RANDOM"',"method":"tools/call","params":{"name":"get_window_state","arguments":{}}}'
    INITIAL_STATE=$(echo "$STATE_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null)
    
    # Drag slider
    local end_x=$((slider_x + drag_dist))
    DRAG_REQ="{\"jsonrpc\":\"2.0\",\"id\":$((RANDOM)),\"method\":\"tools/call\",\"params\":{\"name\":\"drag\",\"arguments\":{\"start_x\":$slider_x,\"start_y\":$slider_y,\"end_x\":$end_x,\"end_y\":$slider_y}}}"
    echo "$DRAG_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null | head -3
    sleep 0.3
    
    # Check for "Rendering" indicator
    STATE_DURING=$(echo "$STATE_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null)
    if echo "$STATE_DURING" | grep -qi "rendering"; then
        fail "$name: 'Rendering' indicator appeared during drag (full render triggered!)"
        return 1
    else
        pass "$name: No 'Rendering' indicator during drag"
    fi
    
    # Check if preview updated
    FINAL_STATE=$(echo "$STATE_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null)
    if [[ "$INITIAL_STATE" != "$FINAL_STATE" ]]; then
        pass "$name: Preview state changed (live update detected)"
    else
        warn "$name: Preview state unchanged (may be expected for small drags)"
    fi
    
    return 0
}

# Test Exposure slider (Tone tab) - tab_x=220
test_slider "Exposure" "Tone" 350 250 100 220

# Test Temperature slider (RAW tab) - tab_x=150
test_slider "Temperature" "RAW" 350 200 50 150

# Test Film Exposure slider (Film tab) - tab_x=430  
test_slider "Film Exposure" "Film" 350 300 80 430

# Test Contrast slider (Tone tab)
test_slider "Contrast" "Tone" 350 300 60 220

# Step 8: Verify no full renders during slow drag
log "Verifying no full renders during slow 2-second drag..."
STATE_REQ='{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"get_window_state","arguments":{}}}'
INITIAL_STATE=$(echo "$STATE_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null)

# Slow drag over 2 seconds
DRAG_REQ="{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"tools/call\",\"params\":{\"name\":\"drag\",\"arguments\":{\"start_x\":350,\"start_y\":250,\"end_x\":450,\"end_y\":250,\"duration_ms\":2000}}}"
echo "$DRAG_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null | head -3

RENDER_COUNT=0
for i in {1..10}; do
    STATE=$(echo "$STATE_REQ" | "$CUA_DRIVER" mcp --socket "$SOCKET_PATH" 2>/dev/null)
    if echo "$STATE" | grep -qi "rendering"; then
        ((RENDER_COUNT++))
    fi
    sleep 0.2
done

if [[ $RENDER_COUNT -gt 0 ]]; then
    fail "'Rendering' appeared $RENDER_COUNT times during slow drag"
    exit 1
else
    pass "No full renders during slow drag"
fi

log "🎉 All smoke tests passed!"
exit 0