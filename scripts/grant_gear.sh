#!/usr/bin/env bash
# Dev/admin: give a character one piece of gear (each call makes a separate piece).
#   GAME_API_SERVER_KEY=... scripts/grant_gear.sh <character_id> <gear_id>
# The key is read from the environment, never from the command line. API_URL defaults to http://localhost:8081.
# A character's id is in the character list of its world (GET /worlds/<id>/characters); gear ids are the file names in game/content/gear.
set -euo pipefail
if [[ $# -lt 2 || -z "${GAME_API_SERVER_KEY:-}" ]]; then
  sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 1
fi
curl -fsS -X POST "${API_URL:-http://localhost:8081}/internal/characters/${1}/gear" \
  -H "Content-Type: application/json" -H @<(printf 'Authorization: Bearer %s\n' "$GAME_API_SERVER_KEY") \
  -d "{\"gear_id\":\"${2}\"}"
echo
