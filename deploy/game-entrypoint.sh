#!/bin/sh
# Builds the server's command line from environment variables (secrets never go in argv).
set -eu
: "${WORLD_ID:?WORLD_ID is required}"
: "${GAME_API_SERVER_KEY:?GAME_API_SERVER_KEY is required}"
set -- --port=9080 --env="${GAME_ENV:-production}" --players="${PLAYERS:-3}" \
    --api-url="${API_URL:-http://apisvc:8000}" --world-id="$WORLD_ID"
[ -n "${INSTANCE_ID:-}" ] && set -- "$@" --instance-id="$INSTANCE_ID"
# Guests are only meaningful when the environment is local; the server also enforces this.
[ "${ALLOW_GUESTS:-false}" = "true" ] && set -- "$@" --allow-guests
exec godot --headless --path /srv/game res://game/server/server_main.tscn -- "$@"
