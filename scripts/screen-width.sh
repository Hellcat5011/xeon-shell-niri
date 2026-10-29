#!/usr/bin/env bash
# screen-width.sh — print the pixel width of the focused niri output.
#
# Used to size wallpaper thumbnails / the lockscreen wallpaper. Falls back to
# the widest enabled output if no output is focused, and prints nothing
# (exit 0) if niri is unreachable, so callers can apply their own default:
#     SCREEN_W="$(screen-width.sh)"; SCREEN_W="${SCREEN_W:-1920}"
#
# Note: `niri msg outputs` is an unordered map, so "the first output" is not a
# meaningful choice; the focused one (else the widest) is.
w="$(niri msg --json focused-output 2>/dev/null \
    | jq -r 'select(. != null and .current_mode != null) | .modes[.current_mode].width // empty' 2>/dev/null)" || w=""
if [ -z "$w" ]; then
    w="$(niri msg --json outputs 2>/dev/null \
        | jq -r '[.[] | select(.current_mode != null) | .modes[.current_mode].width] | max // empty' 2>/dev/null)" || w=""
fi
printf '%s' "$w"
exit 0
