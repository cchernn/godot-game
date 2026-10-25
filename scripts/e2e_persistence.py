"""End-to-end Phase 5 check: embedded Postgres + FastAPI + Godot server + scripted clients.

Verifies that clients authenticate with API-verified tokens, play a battle, and that the finished
result is committed exactly once (XP applied), and that bad tokens are refused.
Run: uv run --project services/api python scripts/e2e_persistence.py
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

API_PORT, GAME_PORT = 8765, 9183
SERVER_KEY, SECRET = "e2e-service-key", "e2e-secret-e2e-secret-e2e-secret-1"
tmp = pathlib.Path(tempfile.mkdtemp())
procs: list[subprocess.Popen] = []


def start(cmd, env=None, log="proc"):
    f = open(tmp / f"{log}.log", "w")
    p = subprocess.Popen(cmd, cwd=ROOT, env={**os.environ, **(env or {})}, stdout=f, stderr=subprocess.STDOUT)
    procs.append(p)
    return p


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

    users = [httpx.post(api + "/dev/guest").json() for _ in range(4)]  # 3 raid members + 1 outsider
    h = lambda u: {"Authorization": "Bearer " + u["access_token"]}  # noqa: E731
    world = httpx.post(api + "/worlds", json={"name": "E2E"}, headers=h(users[0])).json()
    for u in users[1:]:  # join through the real request/approval flow
        rid = httpx.post(f"{api}/worlds/{world['id']}/requests", headers=h(u)).json()["id"]
        assert httpx.post(f"{api}/worlds/{world['id']}/requests/{rid}/approve", headers=h(users[0])).status_code == 200
    chars = []
    for u, name, cls in zip(users, ["Aldric", "Brea", "Corin", "Outsider"], ["warrior", "ranger", "cleric", "rogue"]):
        r = httpx.post(f"{api}/worlds/{world['id']}/characters", json={"name": name, "class": cls}, headers=h(u))
        assert r.status_code == 201, r.text
        chars.append(r.json())

    # A major, one-time, world-changing activity: reveal the location, move the party there, form the roster.
    svc = {"Authorization": "Bearer " + SERVER_KEY}
    assert httpx.post(f"{api}/internal/worlds/{world['id']}/reveal", headers=svc,
                      json={"kind": "node", "target_id": "ashen_keep", "scope": "world"}).json()["revision"] == 1
    inst = httpx.post(f"{api}/worlds/{world['id']}/activities/ashen_keep_siege/instances", headers=h(users[0])).json()
    for u in users[1:3]:  # the party leader lets the others in
        rid = httpx.post(f"{api}/instances/{inst['id']}/requests", headers=h(u)).json()["id"]
        assert httpx.post(f"{api}/instances/{inst['id']}/requests/{rid}/approve", headers=h(users[0])).status_code == 200
    assert httpx.post(f"{api}/instances/{inst['id']}/start", headers=h(users[0])).json()["status"] == "active"

    start(["scripts/run_server.sh", f"--port={GAME_PORT}", "--seed=3", f"--api-url={api}",
           "--set=combat.beat_delay_ms=30", "--set=combat.planning_timeout_seconds=20"],
          env={"GAME_API_SERVER_KEY": SERVER_KEY}, log="server")
    time.sleep(4)
    outsider = start(["scripts/godot.sh", "--headless", "--path", ".", "res://game/client/bot_main.tscn", "--",
                      f"--url=ws://127.0.0.1:{GAME_PORT}", "--name=outsider", f"--token={users[3]['access_token']}", f"--world-id={world['id']}", f"--instance-id={inst['id']}"], log="outsider")
    bots = [start(["scripts/godot.sh", "--headless", "--path", ".", "res://game/client/bot_main.tscn", "--",
                   f"--url=ws://127.0.0.1:{GAME_PORT}", f"--name=ignored{i}", f"--token={u['access_token']}", f"--world-id={world['id']}", f"--instance-id={inst['id']}"], log=f"bot{i}")
            for i, u in enumerate(users[:3])]
    bad = start(["scripts/godot.sh", "--headless", "--path", ".", "res://game/client/bot_main.tscn", "--",
                 f"--url=ws://127.0.0.1:{GAME_PORT}", "--name=mallory", "--token=not.a.jwt", f"--world-id={world['id']}", f"--instance-id={inst['id']}"], log="bad")

    for b in bots:
        b.wait(timeout=150)
    deadline = time.time() + 30
    rows = 0
    while time.time() < deadline and rows == 0:
        with pool.connection() as c:
            rows = c.execute("select count(*) n from combat_results").fetchone()["n"]
        time.sleep(0.5)
    if rows != 1:
        fail(f"expected exactly 1 committed result, found {rows}")
    time.sleep(2)  # a duplicate commit would show up by now
    with pool.connection() as c:
        res = c.execute("select * from combat_results").fetchone()
        xps = {r["name"]: r["xp_awarded"] for r in c.execute(
            "select ch.name, p.xp_awarded from combat_result_participants p join characters ch on ch.id = p.character_id").fetchall()}
        kept = c.execute("select count(*) n from characters where xp <> 0").fetchone()["n"]
        n_part = c.execute("select count(*) n from combat_result_participants").fetchone()["n"]
    expected = 20 + (80 if res["outcome"] == "players_win" else 0)
    # The prototype template resets XP after every battle, so the award lives in the history and the characters sit at 0.
    if n_part != 3 or set(xps.values()) != {expected} or kept != 0:
        fail(f"unexpected persistence state: outcome={res['outcome']} participants={n_part} xp={xps}")
    bad_log = (tmp / "bad.log").read_text()
    if "rejected: Sign-in failed" not in bad_log:
        fail("bad token was not rejected:\n" + bad_log)
    srv = (tmp / "server.log").read_text()
    if "Aldric disconnected" not in srv:
        fail("server did not use persisted character names:\n" + srv)
    if "not on this party's roster" not in (tmp / "outsider.log").read_text():
        fail("a character outside the roster was admitted")
    time.sleep(1)
    with pool.connection() as c:
        istate = c.execute("select status from activity_instances where id=%s", (inst["id"],)).fetchone()["status"]
        revision = c.execute("select state_revision from worlds where id=%s", (world["id"],)).fetchone()["state_revision"]
        crypt = c.execute("select count(*) n from world_discoveries where target_id='sunken_crypt'").fetchone()["n"]
    win = res["outcome"] == "players_win"
    if (istate, revision, crypt) != (("finished", 2, 1) if win else ("cancelled", 1, 0)):
        fail(f"unexpected world state after {res['outcome']}: instance={istate} revision={revision} crypt={crypt}")
    print(f"E2E OK: instance={istate} revision={revision} crypt_revealed={crypt}; outcome={res['outcome']} xp={xps} (one committed result, bad token refused)")
finally:
    for p in procs:
        p.terminate()
    try:
        pg.cleanup()
    except Exception:
        pass
