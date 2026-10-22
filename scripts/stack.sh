#!/usr/bin/env bash
# Runs the production layout locally: three independent compose projects (api, game, web).
#   scripts/stack.sh init            write deploy/*/.env from services/api/.env + client_env.json (PLAYERS=n)
#   scripts/stack.sh up [svc...]     build and start (default: all, in dependency order)
#   scripts/stack.sh down [svc...]   stop and remove
#   scripts/stack.sh ps | logs <svc> | restart <svc>
# Web http://localhost:8080  API http://localhost:8081  Game ws://localhost:8082
set -euo pipefail
cd "$(dirname "$0")/.."
cmd="${1:-}"; shift || true
all=(api game web)
svcs=("${@:-${all[@]}}")
compose() { local s=$1; shift; docker compose -f "deploy/$s/compose.yaml" "$@"; }
need_env() { for s in "${svcs[@]}"; do [[ -f deploy/$s/.env ]] || { echo "deploy/$s/.env missing: run scripts/stack.sh init"; exit 1; }; done; }
case "$cmd" in
  init)    exec python3 scripts/local_env.py ;;
  up)      need_env; for s in "${svcs[@]}"; do compose "$s" up -d --build; done ;;
  down)    for s in "${svcs[@]}"; do compose "$s" down; done ;;
  restart) for s in "${svcs[@]}"; do compose "$s" restart; done ;;
  ps)      for s in "${svcs[@]}"; do compose "$s" ps; done ;;
  logs)    compose "${1:?usage: stack.sh logs <api|game|web>}" logs -f --tail=100 ;;
  *)       sed -n 2,9p "$0"; exit 1 ;;
esac
