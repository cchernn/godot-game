#!/usr/bin/env bash
# End-to-end check: starts a local server, connects 4 scripted guest clients (one drops its connection mid-resolution and reconnects,
# one drops while planning, one escapes in round 1 and watches to the end), and verifies the battle plays through to the end.
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=$(mktemp -d)
PORT=${PORT:-9181}
scripts/run_server.sh --port=$PORT --players=4 --seed=3 --set=combat.beat_delay_ms=30 --set=combat.planning_timeout_seconds=20 >"$OUT/server.log" 2>&1 &
SERVER=$!
sleep 4
for n in 1 2 3 4; do
  EXTRA=""; [[ $n == 2 ]] && EXTRA="--drop-at-round=1"
  [[ $n == 3 ]] && EXTRA="--drop-at-planning=2"
  [[ $n == 4 ]] && EXTRA="--escape-at-round=1"
  scripts/godot.sh --headless --path . res://game/client/bot_main.tscn -- --url=ws://127.0.0.1:$PORT --name=Bot$n $EXTRA >"$OUT/bot$n.log" 2>&1 &
  PIDS+=($!)
done
wait "${PIDS[@]}"
kill $SERVER 2>/dev/null; sleep 1
echo "logs in $OUT"
grep -h "FINISHED\|RESULT\|lobby\|welcomed\|dropping\|rejected\|TIMEOUT" "$OUT"/bot*.log
grep -q "FINISHED" "$OUT/bot1.log" && grep -q "RESULT" "$OUT/bot1.log" && grep -q "lobby:" "$OUT/bot1.log" && grep -q "welcomed #3" "$OUT/bot2.log" && grep -q "welcomed #3" "$OUT/bot3.log" && grep -q "Bot4.*escapes" "$OUT/bot1.log" && grep -q "RESULT" "$OUT/bot4.log" && echo "SMOKE OK" || { echo "SMOKE FAILED"; exit 1; }
