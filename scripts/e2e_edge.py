"""End-to-end checks of three awkward battle situations, against a throwaway database, API and battle server:
  A. a party member who never connects: the battle still starts, plays out and is stored with both characters;
  B. the battle server restarting in the middle of a battle: the players reconnect and the party's battle still ends once;
  D. a player escaping in round 1: they are stored as escaped, and the rest of the party still finishes.
Run: uv run --project services/api python scripts/e2e_edge.py"""
import os
import pathlib
import subprocess
import sys
import tempfile
import time

import httpx
import pgserver

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "services" / "api"))
from app.db import make_pool, migrate  # noqa: E402

API_PORT, GAME_PORT = 8767, 9185
SERVER_KEY, SECRET = "e2e-service-key", "e2e-secret-e2e-secret-e2e-secret-1"
tmp = pathlib.Path(tempfile.mkdtemp())
procs: list[subprocess.Popen] = []


def start(cmd, env=None, log="proc"):
    f = open(tmp / f"{log}.log", "w")
    p = subprocess.Popen(cmd, cwd=ROOT, env={**os.environ, **(env or {})}, stdout=f, stderr=subprocess.STDOUT)
    procs.append(p)
    return p


def bot(name, token, world, party, log, *extra):
    return start(["scripts/godot.sh", "--headless", "--path", ".", "res://game/client/bot_main.tscn", "--",
                  f"--url=ws://127.0.0.1:{GAME_PORT}", f"--name={name}", f"--token={token}", f"--world-id={world}",
                  f"--instance-id={party}", *extra], log=log)


def game_server(log):
    p = start(["scripts/run_server.sh", f"--port={GAME_PORT}", "--seed=3", f"--api-url=http://127.0.0.1:{API_PORT}",
               "--set=combat.beat_delay_ms=300", "--set=combat.planning_timeout_seconds=6", "--set=lobby.gather_seconds=4"],
              env={"GAME_API_SERVER_KEY": SERVER_KEY}, log=log)
    time.sleep(4)
    return p


def fail(msg):
    print("E2E EDGE FAILED:", msg)
    print("logs:", tmp)
    sys.exit(1)


try:
    pg = pgserver.get_server(tmp / "pg")
    uri = pg.get_uri()
    pool = make_pool(uri)
    migrate(pool)
    start(["uv", "run", "--project", "services/api", "uvicorn", "app.main:app", "--app-dir", "services/api", "--port", str(API_PORT)],
          env={"GAME_API_DATABASE_URL": uri, "GAME_API_ENVIRONMENT": "local", "GAME_API_ALLOW_GUESTS": "true",
               "GAME_API_JWT_SECRET": SECRET, "GAME_API_SERVER_API_KEY": SERVER_KEY}, log="api")
    api = f"http://127.0.0.1:{API_PORT}"
    for _ in range(60):
        try:
            if httpx.get(api + "/health").status_code == 200:
                break
        except httpx.HTTPError:
            time.sleep(0.5)
    else:
        fail("API did not start")

    h = lambda u: {"Authorization": "Bearer " + u["access_token"]}  # noqa: E731

    def party_of_two(label):
        """A world with a host (the leader) and a second player in the leader's party, and the run already started."""
        lead, mate = (httpx.post(api + "/dev/guest").json() for _ in range(2))
        w = httpx.post(api + "/worlds", json={"name": f"World {label}"}, headers=h(lead)).json()
        rid = httpx.post(f"{api}/worlds/{w['id']}/requests", headers=h(mate)).json()["id"]
        assert httpx.post(f"{api}/worlds/{w['id']}/requests/{rid}/approve", headers=h(lead)).status_code == 200
        for u, n in ((lead, f"{label}Lead"), (mate, f"{label}Mate")):
            assert httpx.post(f"{api}/worlds/{w['id']}/characters", headers=h(u), json={"name": n, "class": "warrior"}).status_code == 201
        pid = httpx.get(f"{api}/worlds/{w['id']}/parties/me", headers=h(lead)).json()["id"]
        req = httpx.post(f"{api}/parties/{pid}/requests", headers=h(mate)).json()["id"]
        assert httpx.post(f"{api}/parties/{pid}/requests/{req}/approve", headers=h(lead)).status_code == 200
        run = httpx.post(f"{api}/parties/{pid}/start", json={"activity_id": "training_skirmish"}, headers=h(lead))
        assert run.status_code == 201, run.text
        return {"w": w["id"], "run": run.json()["id"], "lead": lead, "mate": mate}

    def stored(world):
        with pool.connection() as c:
            results = c.execute("select id, outcome from combat_results where world_id=%s", (world,)).fetchall()
            parts = c.execute("select ch.name, p.outcome from combat_result_participants p "
                              "join combat_results r on r.id = p.result_id join characters ch on ch.id = p.character_id "
                              "where r.world_id=%s", (world,)).fetchall()
            run = c.execute("select status from activity_instances where world_id=%s", (world,)).fetchone()["status"]
        return results, {p["name"]: p["outcome"] for p in parts}, run

    def wait_stored(world, seconds=60):
        end = time.time() + seconds
        while time.time() < end:
            results, parts, run = stored(world)
            if results and run != "active":
                return results, parts, run
            time.sleep(0.5)
        fail(f"no stored result for world {world}")

    A, B, D = party_of_two("A"), party_of_two("B"), party_of_two("D")
    srv = game_server("server1")

    # A + D together: A's mate never connects; D's mate escapes in round 1.
    bots = [bot("a-lead", A["lead"]["access_token"], A["w"], A["run"], "a_lead"),
            bot("d-lead", D["lead"]["access_token"], D["w"], D["run"], "d_lead"),
            bot("d-mate", D["mate"]["access_token"], D["w"], D["run"], "d_mate", "--escape-at-round=1")]
    for b in bots:
        b.wait(timeout=180)
    results, parts, run = wait_stored(A["w"])
    if len(results) != 1 or set(parts) != {"ALead", "AMate"}:
        fail(f"A: expected one result with both characters, got {results} {parts}")
    results, parts, run = wait_stored(D["w"])
    if len(results) != 1 or parts.get("DMate") != "escaped":
        fail(f"D: the escapee should be stored as escaped, got {parts}")
    if "DLead" not in parts:
        fail(f"D: the leader was not stored: {parts}")
    d_log = (tmp / "d_lead.log").read_text()
    if "DMate escapes!" not in d_log:
        fail("D: the party did not see the escape in its log")

    # B: the battle server dies mid-battle and comes back; both players reconnect and the party's battle still ends once.
    b_bots = [bot("b-lead", B["lead"]["access_token"], B["w"], B["run"], "b_lead"),
              bot("b-mate", B["mate"]["access_token"], B["w"], B["run"], "b_mate")]
    time.sleep(12)  # the battle is under way (two players arrived, rounds are being played)
    if "battle started with 2 players" not in (tmp / "server1.log").read_text():
        fail("B: the battle had not started before the restart:\n" + (tmp / "server1.log").read_text()[-1500:])
    srv.terminate()
    srv.wait(timeout=15)
    time.sleep(2)
    if stored(B["w"])[0]:
        fail("B: a result was stored before the restart; the test cannot show recovery")
    game_server("server2")
    for b in b_bots:
        b.wait(timeout=180)
    results, parts, run = wait_stored(B["w"])
    if len(results) != 1 or set(parts) != {"BLead", "BMate"}:
        fail(f"B: expected exactly one result with both characters after the restart, got {results} {parts}")
    if "battle started with 2 players" not in (tmp / "server2.log").read_text():
        fail("B: the restarted server did not run the battle again")
    print("E2E EDGE OK: absent member stored (%s), escapee stored as %s, battle survived a server restart (%s)" % (
        sorted(stored(A["w"])[1]), stored(D["w"])[1]["DMate"], stored(B["w"])[2]))
finally:
    for p in procs:
        p.terminate()
    try:
        pg.cleanup()
    except Exception:
        pass
