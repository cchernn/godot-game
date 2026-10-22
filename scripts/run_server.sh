#!/usr/bin/env bash
# Starts the dedicated headless game server. Extra args are passed after `--`.
set -euo pipefail
cd "$(dirname "$0")/.."
# Dev defaults: local env with guests. Override by passing --env=... (production ignores guests).
exec scripts/godot.sh --headless --path . res://game/server/server_main.tscn -- --env=local --allow-guests "$@"
