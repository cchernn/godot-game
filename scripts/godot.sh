#!/usr/bin/env bash
# Runs the pinned Godot version. Override with GODOT_BIN.
# Default: Linux `godot` on PATH, falling back to the Windows console build under WSL.
set -euo pipefail
if [[ -n "${GODOT_BIN:-}" ]]; then exec "$GODOT_BIN" "$@"; fi
if command -v godot >/dev/null 2>&1; then exec godot "$@"; fi
WIN="/mnt/c/Program Files (x86)/Godot/Godot_v4.7.2-stable_win64_console.exe"
# The Windows build does not inherit WSL env vars unless listed in WSLENV.
if [[ -x "$WIN" ]]; then export WSLENV="${WSLENV:+$WSLENV:}GAME_API_SERVER_KEY:GAME_ENV"; exec "$WIN" "$@"; fi
echo "Godot 4.7.2 not found; set GODOT_BIN" >&2; exit 127
