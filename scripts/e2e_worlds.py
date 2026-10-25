"""End-to-end check that ONE battle server hosts several worlds at once without mixing them.

Two worlds, one party of two players each, play battles simultaneously on a single server that is not bound to
a world. Checks: each party's battle commits its own result with only its own players; a member of the world who
is not on the party's roster is refused; a non-member of the world is refused; a garbled world or party id is refused.
Run: uv run --project services/api python scripts/e2e_worlds.py
"""
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

API_PORT, GAME_PORT = 8766, 9184
SERVER_KEY, SECRET = "e2e-service-key", "e2e-secret-e2e-secret-e2e-secret-1"
tmp = pathlib.Path(tempfile.mkdtemp())
procs: list[subprocess.Popen] = []


def start(cmd, env=None, log="proc"):
    f = open(tmp / f"{log}.log", "w")
    p = subprocess.Popen(cmd, cwd=ROOT, env={**os.environ, **(env or {})}, stdout=f, stderr=subprocess.STDOUT)
    procs.append(p)
    return p


def bot(name, token, world, party, log):
    return start(["scripts/godot.sh", "--headless", "--path", ".", "res://game/client/bot_main.tscn", "--",
                  f"--url=ws://127.0.0.1:{GAME_PORT}", f"--name={name}", f"--token={token}", f"--world-id={world}",
                  f"--instance-id={party}"], log=log)


def fail(msg):
    print("E2E FAILED:", msg)
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
    users = {n: httpx.post(api + "/dev/guest").json() for n in ["a1", "a2", "a3", "b1", "b2"]}
    worlds = {w: httpx.post(api + "/worlds", json={"name": f"World {w}"}, headers=h(users[f"{w}1"])).json() for w in "ab"}
    for n in ("a2", "a3", "b2"):  # the other players join their world through request + approval
        wid = worlds[n[0]]["id"]
        rid = httpx.post(f"{api}/worlds/{wid}/requests", headers=h(users[n])).json()["id"]
        assert httpx.post(f"{api}/worlds/{wid}/requests/{rid}/approve", headers=h(users[f"{n[0]}1"])).status_code == 200
    names = {"a1": "Aldric", "a2": "Aria", "a3": "Arden", "b1": "Bran", "b2": "Brea"}
    for n, u in users.items():
        r = httpx.post(f"{api}/worlds/{worlds[n[0]]['id']}/characters", headers=h(u),
                       json={"name": names[n], "class": "warrior"})
        assert r.status_code == 201, r.text
    listing = {w["name"]: w for w in httpx.get(api + "/worlds/available", headers=h(users["a1"])).json()}
    assert listing["World a"]["status"] == "member" and listing["World b"]["status"] == "none", listing

    # Each world's host starts a party; the second player asks to join and is let in; the host starts it.
    parties = {}
    for w in "ab":
        wid = worlds[w]["id"]
        iid = httpx.post(f"{api}/worlds/{wid}/activities/training_skirmish/instances", headers=h(users[f"{w}1"])).json()["id"]
        rid = httpx.post(f"{api}/instances/{iid}/requests", headers=h(users[f"{w}2"])).json()["id"]
        assert httpx.post(f"{api}/instances/{iid}/requests/{rid}/approve", headers=h(users[f"{w}1"])).status_code == 200
        assert httpx.post(f"{api}/instances/{iid}/start", headers=h(users[f"{w}1"])).status_code == 200
        parties[w] = iid
    listing = httpx.get(f"{api}/worlds/{worlds['a']['id']}/parties", headers=h(users["a3"])).json()
    assert [(p["status"], len(p["members"]), p["relation"]) for p in listing] == [("active", 2, "none")], listing

    # One server, no --world-id: it serves any party in any world, each in its own room.
    start(["scripts/run_server.sh", f"--port={GAME_PORT}", "--seed=3", f"--api-url={api}",
           "--set=combat.beat_delay_ms=30", "--set=combat.planning_timeout_seconds=20"],
          env={"GAME_API_SERVER_KEY": SERVER_KEY}, log="server")
    time.sleep(4)
    A, B = worlds["a"]["id"], worlds["b"]["id"]
    PA, PB = parties["a"], parties["b"]
    wrong = bot("trespasser", users["a1"]["access_token"], B, PB, "wrong")      # a member of A, not of B
    off_roster = bot("off", users["a3"]["access_token"], A, PA, "off")         # in world A, not in A's party
    nowhere = bot("nowhere", users["a1"]["access_token"], "not-a-world", PA, "nowhere")
    noparty = bot("noparty", users["a1"]["access_token"], A, "nope", "noparty")
    bots = [bot("x1", users["a1"]["access_token"], A, PA, "a1"), bot("x2", users["b1"]["access_token"], B, PB, "b1"),
            bot("x3", users["a2"]["access_token"], A, PA, "a2"), bot("x4", users["b2"]["access_token"], B, PB, "b2")]
    for b in bots:
        b.wait(timeout=180)

    deadline = time.time() + 30
    rows = 0
    while time.time() < deadline and rows < 2:
        with pool.connection() as c:
            rows = c.execute("select count(*) n from combat_results").fetchone()["n"]
        time.sleep(0.5)
    time.sleep(2)  # a duplicate or stray commit would show up by now
    with pool.connection() as c:
        results = c.execute("select id, world_id from combat_results").fetchall()
        parts = c.execute("select r.world_id, ch.name, ch.world_id as char_world, p.xp_awarded as xp from combat_result_participants p "
                          "join combat_results r on r.id = p.result_id join characters ch on ch.id = p.character_id").fetchall()
    if len(results) != 2 or {str(r["world_id"]) for r in results} != {A, B}:
        fail(f"expected one result per world, got {[(str(r['world_id'])) for r in results]}")
    by_world = {}
    for p in parts:
        if str(p["world_id"]) != str(p["char_world"]):
            fail(f"a participant from another world was mixed in: {p}")
        by_world.setdefault(str(p["world_id"]), set()).add(p["name"])
    if by_world != {A: {"Aldric", "Aria"}, B: {"Bran", "Brea"}}:
        fail(f"wrong participants per world: {by_world}")
    if any(p["xp"] <= 0 for p in parts):
        fail("xp was not applied")
    if "rejected: Sign-in failed" not in (tmp / "wrong.log").read_text():
        fail("a non-member was admitted to the world:\n" + (tmp / "wrong.log").read_text())
    if "not on this party's roster" not in (tmp / "off.log").read_text():
        fail("a world member who is not on the roster was admitted:\n" + (tmp / "off.log").read_text())
    if "rejected: Choose a world first" not in (tmp / "nowhere.log").read_text():
        fail("a garbled world id was not refused:\n" + (tmp / "nowhere.log").read_text())
    if "rejected: Choose a party first" not in (tmp / "noparty.log").read_text():
        fail("a garbled party id was not refused:\n" + (tmp / "noparty.log").read_text())
    srv = (tmp / "server.log").read_text()
    if "worlds=any" not in srv or srv.count("battle started with 2 players") != 2:
        fail("server did not run two separate battles:\n" + srv)
    print(f"E2E WORLDS OK: two simultaneous battles on one server, results {sorted(by_world.items())}")
finally:
    for p in procs:
        p.terminate()
    try:
        pg.cleanup()
    except Exception:
        pass
