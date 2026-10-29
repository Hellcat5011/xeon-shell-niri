#!/usr/bin/env bash
# niri-focus-info.sh — report the focused window and focused output in one call.
#
# Prints a single line of JSON:
#   {"window": <niri focused-window object | null>, "output": <niri focused-output object | null>}
#
# Used by EmojiPicker.qml to remember which window should receive the paste and
# which monitor the picker should open on. Never fails: if niri isn't reachable
# both fields are null.
win="$(niri msg --json focused-window 2>/dev/null)" || win=""
out="$(niri msg --json focused-output 2>/dev/null)" || out=""
printf '{"window":%s,"output":%s}\n' "${win:-null}" "${out:-null}"
