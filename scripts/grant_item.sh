#!/usr/bin/env bash
# Dev/admin: give a character copies of an item (there are no shops or loot yet).
#   GAME_API_SERVER_KEY=... scripts/grant_item.sh <character_id> <item_id> <quantity> [max_stack]
# The key is read from the environment, never from the command line. API_URL defaults to http://localhost:8081.
# A character's id is in the character list of its world (GET /worlds/<id>/characters).
set -euo pipefail
if [[ $# -lt 3 || -z "${GAME_API_SERVER_KEY:-}" ]]; then
  sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 1
fi
char="$1"; item="$2"; qty="$3"; max="${4:-99}"
curl -fsS -X POST "${API_URL:-http://localhost:8081}/internal/characters/${char}/items" \
  -H "Content-Type: application/json" -H @<(printf 'Authorization: Bearer %s\n' "$GAME_API_SERVER_KEY") \
  -d "{\"item_id\":\"${item}\",\"quantity\":${qty},\"max_stack\":${max}}"
echo
