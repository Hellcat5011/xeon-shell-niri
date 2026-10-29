#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# paste-emoji.sh — Wayland emoji clipboard copy and context-aware paste (niri)
#
# Usage: paste-emoji.sh <emoji> [target_window_id|none] [target_app_id] [paste|copy-only]
#
# niri has no "send a key to window X" dispatcher, so the paste keystroke is
# injected with wtype (virtual-keyboard protocol) into whichever window has
# focus. To keep that safe, the script first waits until the target window
# (identified by niri's numeric window id) has regained focus after the picker
# closed, and refuses to paste anywhere else.
#
# Requires: wl-copy (wl-clipboard), jq, niri, and either wtype (preferred) or
# ydotool (+ running ydotoold) for the paste keystroke.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

EMOJI="${1:-}"
TARGET_ID="${2:-}"
TARGET_CLASS="${3:-}"
PASTE_MODE="${4:-paste}"

if [ -z "$EMOJI" ]; then
    echo "Usage: $0 <emoji> [target_window_id|none] [target_app_id] [paste|copy-only]" >&2
    exit 1
fi

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/quickshell-emoji"
mkdir -p "$STATE_DIR"
LOG_FILE="$STATE_DIR/paste.log"

log_msg() {
    # Rotate log if it exceeds 50 KB to keep disk usage minimal
    if [ -f "$LOG_FILE" ] && [ "$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 50000 ]; then
        tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') [paste-emoji] $*" >> "$LOG_FILE"
}

# 1. Always copy to Wayland clipboard (redirect output so background pipes close cleanly)
# Create lock file so the clipboard watcher skips this self-initiated copy
LOCK_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/qs-clipboard-self.lock"
touch "$LOCK_FILE"
printf '%s' "$EMOJI" | wl-copy >/dev/null 2>&1

# If copy-only requested, exit immediately
if [ "$PASTE_MODE" = "copy-only" ]; then
    log_msg "Copied '$EMOJI' to clipboard (copy-only mode requested)"
    exit 0
fi

# Case A2: Explicit sentinel 'none' passed by QML when window capture succeeded
# but found no focused window (empty workspace/desktop). Copy only, never fall back.
if [ "$TARGET_ID" = "none" ]; then
    log_msg "Copied '$EMOJI' to clipboard; skipped paste (source=qml no-target, no focused window)"
    exit 0
fi

# Helper: read one field of the focused window from niri ("" when nothing is focused).
#   get_active_field id      → numeric window id
#   get_active_field app_id  → application id (e.g. "foot", "org.gnome.Nautilus")
get_active_field() {
    local field="$1"
    (niri msg --json focused-window 2>/dev/null || echo 'null') \
        | jq -r --arg f "$field" '(.[$f] // empty) | tostring' 2>/dev/null | head -n 1 || true
}

# Track target source: qml vs fallback
TARGET_SOURCE="qml"
if [ -z "$TARGET_ID" ] || [ "$TARGET_ID" = "null" ]; then
    TARGET_SOURCE="fallback"
    TARGET_ID="$(get_active_field id)"
    TARGET_CLASS="$(get_active_field app_id)"
fi

# If still no target window (empty workspace/desktop after fallback), do not attempt paste
if [ -z "$TARGET_ID" ]; then
    log_msg "Copied '$EMOJI' to clipboard; skipped paste (source=$TARGET_SOURCE, no focused target window)"
    exit 0
fi

# 2. Blocklist check (case-insensitive substring match)
# Avoid accidental paste in file managers or file browsers where Ctrl+V duplicates files
CLASS_LOWER=$(echo "$TARGET_CLASS" | tr '[:upper:]' '[:lower:]')
BLOCKLIST_REGEX="nautilus|thunar|org\.kde\.dolphin|pcmanfm|nemo"
if [[ "$CLASS_LOWER" =~ $BLOCKLIST_REGEX ]]; then
    log_msg "Copied '$EMOJI' to clipboard; skipped paste (source=$TARGET_SOURCE, app_id '$TARGET_CLASS' matched blocklist)"
    exit 0
fi

# 3. Floor delay & Focus restoration polling
# Environment Variables:
#   FOCUS_FLOOR_DELAY_MS (or FOCUS_RESTORE_DELAY_MS alias):
#     Small delay before beginning focused-window polling. Allows niri
#     time to unmap the layer-shell overlay surface and restore seat keyboard focus.
#   FOCUS_POLL_MAX_MS:
#     Maximum duration in milliseconds to poll for the target window to regain focus.
RAW_FLOOR="${FOCUS_FLOOR_DELAY_MS:-${FOCUS_RESTORE_DELAY_MS:-40}}"
if [[ "$RAW_FLOOR" =~ ^[0-9]+$ ]]; then
    FLOOR_DELAY_MS="$RAW_FLOOR"
else
    log_msg "WARNING: Invalid floor delay '$RAW_FLOOR'; falling back to default 40ms"
    FLOOR_DELAY_MS=40
fi

RAW_MAX="${FOCUS_POLL_MAX_MS:-300}"
if [[ "$RAW_MAX" =~ ^[0-9]+$ ]]; then
    MAX_MS="$RAW_MAX"
else
    log_msg "WARNING: Invalid max poll duration '$RAW_MAX'; falling back to default 300ms"
    MAX_MS=300
fi

if [ "$FLOOR_DELAY_MS" -gt 0 ]; then
    sleep "$(awk -v ms="$FLOOR_DELAY_MS" 'BEGIN { printf "%.3f", ms / 1000 }')"
fi

POLL_INTERVAL="0.015"
ELAPSED=0
REGAINED=0
CURRENT_ID=""
START_TIME_MS=$(date +%s%3N)

while [ "$ELAPSED" -lt "$MAX_MS" ]; do
    CURRENT_ID="$(get_active_field id)"
    if [ -n "$CURRENT_ID" ] && [ "$CURRENT_ID" = "$TARGET_ID" ]; then
        REGAINED=1
        break
    fi
    sleep "$POLL_INTERVAL"
    ELAPSED=$((ELAPSED + 15))
done

END_TIME_MS=$(date +%s%3N)
TOTAL_POLL_MS=$(( (END_TIME_MS - START_TIME_MS) + FLOOR_DELAY_MS ))

if [ "$REGAINED" -ne 1 ]; then
    log_msg "Copied '$EMOJI' to clipboard; skipped paste: target window $TARGET_ID never regained focus within ${MAX_MS}ms (source=$TARGET_SOURCE, last focused: '$CURRENT_ID', poll=${TOTAL_POLL_MS}ms)"
    exit 0
fi

# 4. Determine correct paste shortcut (Terminal vs Standard GUI)
TERMINAL_REGEX="ghostty|kitty|foot|alacritty|wezterm|xterm|rxvt|konsole|gnome-terminal|ptyxis|tilix|terminator"
if [[ "$CLASS_LOWER" =~ $TERMINAL_REGEX ]]; then
    # Terminal paste from clipboard uses Ctrl+Shift+V
    SHORTCUT="CTRL+SHIFT+V"
else
    # Standard GUI app / text editor paste uses Ctrl+V
    SHORTCUT="CTRL+V"
fi

# 5. Inject the keystroke into the (verified) focused window.
#    wtype: virtual-keyboard protocol, no daemon needed.
#    ydotool: fallback, needs ydotoold running and /dev/uinput access.
send_paste() {
    if command -v wtype >/dev/null 2>&1; then
        if [ "$SHORTCUT" = "CTRL+SHIFT+V" ]; then
            wtype -M ctrl -M shift v -m shift -m ctrl
        else
            wtype -M ctrl v -m ctrl
        fi
    elif command -v ydotool >/dev/null 2>&1; then
        # Linux input event codes: LEFTCTRL=29, LEFTSHIFT=42, V=47
        if [ "$SHORTCUT" = "CTRL+SHIFT+V" ]; then
            ydotool key 29:1 42:1 47:1 47:0 42:0 29:0
        else
            ydotool key 29:1 47:1 47:0 29:0
        fi
    else
        echo "neither wtype nor ydotool is installed" >&2
        return 127
    fi
}

if ! SEND_OUTPUT="$(send_paste 2>&1)"; then
    log_msg "ERROR: paste keystroke failed for window $TARGET_ID (shortcut=$SHORTCUT, source=$TARGET_SOURCE, poll=${TOTAL_POLL_MS}ms): $SEND_OUTPUT"
    exit 1
fi

log_msg "Successfully pasted '$EMOJI' into window $TARGET_ID ($TARGET_CLASS) via $SHORTCUT (source=$TARGET_SOURCE, poll=${TOTAL_POLL_MS}ms)"
