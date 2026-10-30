"""End-to-end play of the first full event with scripted bots: a fresh local database, the real API and game server.

A party of four plays the hub story ("The Elder's request", which reveals Lost Woods), travels to the woods and plays
"The Emerald Serpent" (five stories and four battles, with hit points carried over). Checks what the API recorded.
The bots are simple (walk up and strike), so the party may lose a battle; the event then restarts, which this run also covers.
Run: uv run --project services/api python scripts/e2e_event.py [--minutes=15] [--hp-base=N]
(--hp-base raises every unit's base HP for the run, so the scripted bots can survive to the later battles)
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

API_PORT, GAME_PORT = 8767, 9185
SERVER_KEY, SECRET = "e2e-service-key", "e2e-secret-e2e-secret-e2e-secret-1"
SEED = next((a for a in sys.argv[1:] if a.startswith("--seed=")), "")  # unset: every battle gets its own seed, so a retry is not the same fight
HP_BASE = next((a.split("=")[1] for a in sys.argv[1:] if a.startswith("--hp-base=")), "")
MINUTES = next((int(a.split("=")[1]) for a in sys.argv[1:] if a.startswith("--minutes=")), 15)
tmp = pathlib.Path(tempfile.mkdtemp())
procs: list[subprocess.Popen] = []


def start(cmd, env=None, log="proc"):
    f = open(tmp / f"{log}.log", "w")
    p = subprocess.Popen(cmd, cwd=ROOT, env={**os.environ, **(env or {})}, stdout=f, stderr=subprocess.STDOUT)
    procs.append(p)
    return p


def bot(name, token, world, party, log, timeout):
    return start(["scripts/godot.sh", "--headless", "--path", ".", "res://game/client/bot_main.tscn", "--",
                  f"--url=ws://127.0.0.1:{GAME_PORT}", f"--name={name}", f"--token={token}", f"--world-id={world}",
                  f"--instance-id={party}", "--event", f"--timeout={timeout}", "--story-choice=1"], log=log)


def fail(msg):
    print("E2E FAILED:", msg)
    print("logs:", tmp)
    sys.exit(1)


def play(label, api, world, party, users, minutes):
    bots = [bot(f"{label}{i}", u["access_token"], world, party, f"{label}{i}", minutes * 60) for i, u in enumerate(users)]
    deadline = time.time() + minutes * 60 + 30
    for b in bots:
        try:
            b.wait(timeout=max(1, deadline - time.time()))
        except subprocess.TimeoutExpired:
            fail(f"{label}: the bots did not finish in {minutes} minutes")
    codes = [b.returncode for b in bots]
    if any(c != 0 for c in codes):
        fail(f"{label}: bot exit codes {codes}")


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
    users = [httpx.post(api + "/dev/guest").json() for _ in range(4)]
    world = httpx.post(api + "/worlds", json={"name": "Lost Woods run"}, headers=h(users[0])).json()["id"]
    for u in users[1:]:
        rid = httpx.post(f"{api}/worlds/{world}/requests", headers=h(u)).json()["id"]
        assert httpx.post(f"{api}/worlds/{world}/requests/{rid}/approve", headers=h(users[0])).status_code == 200
    chars = []
    for u, (name, cls) in zip(users, [("Aldric", "warrior"), ("Hana", "hunter"), ("Mira", "mage"), ("Bram", "warrior")]):
        r = httpx.post(f"{api}/worlds/{world}/characters", headers=h(u), json={"name": name, "class": cls})
        assert r.status_code == 201, r.text
        chars.append(r.json())
    pid = httpx.get(f"{api}/worlds/{world}/parties/me", headers=h(users[0])).json()["id"]
    for u in users[1:]:
        rid = httpx.post(f"{api}/parties/{pid}/requests", headers=h(u)).json()["id"]
        assert httpx.post(f"{api}/parties/{pid}/requests/{rid}/approve", headers=h(users[0])).status_code == 200

    start(["scripts/run_server.sh", f"--port={GAME_PORT}", f"--api-url={api}"] + ([SEED] if SEED else []) + ["--set=combat.beat_delay_ms=30",
           "--set=combat.planning_timeout_seconds=20", "--set=event.step_pause_ms=400"] + ([f"--set=stats.hp_base={HP_BASE}"] if HP_BASE else []), env={"GAME_API_SERVER_KEY": SERVER_KEY}, log="server")
    time.sleep(4)

    # 1. the hub story
    started = httpx.post(f"{api}/parties/{pid}/start", json={"activity_id": "elder_rumor"}, headers=h(users[0]))
    assert started.status_code == 201, started.text
    play("hub", api, world, started.json()["id"], users, 3)
    ov = httpx.get(f"{api}/worlds/{world}/overview", headers=h(users[0])).json()
    if "lost_woods" not in {n["id"] for n in ov["nodes"]}:
        fail("the hub story did not reveal Lost Woods")
    print("hub story played: Lost Woods revealed")

    # 2. the event
    assert httpx.post(f"{api}/parties/{pid}/travel", json={"node_id": "lost_woods"}, headers=h(users[0])).status_code == 200
    started = httpx.post(f"{api}/parties/{pid}/start", json={"activity_id": "emerald_serpent"}, headers=h(users[0]))
    assert started.status_code == 201, started.text
    iid = started.json()["id"]
    play("ev", api, world, iid, users, MINUTES)

    srv = (tmp / "server.log").read_text()
    with pool.connection() as c:
        inst = c.execute("select status from activity_instances where id=%s", (iid,)).fetchone()["status"]
        pays = c.execute("select step_key, count(*) n from event_step_pays where instance_id=%s group by step_key order by step_key", (iid,)).fetchall()
        done = c.execute("select count(*) n from activity_completions where activity_id='emerald_serpent'").fetchone()["n"]
        folks = c.execute("select name, gold, flags from characters order by name").fetchall()
        gear = c.execute("select c.name, g.source, count(*) n from character_gear g join characters c on c.id = g.character_id "
                         "group by c.name, g.source order by c.name, g.source").fetchall()
    restarts = srv.count("finished: outcome 2")  # battles the party lost on the way
    print("server events:", [l for l in srv.splitlines() if "event" in l][-12:])
    print("instance:", inst, "| step payouts:", [(p["step_key"], p["n"]) for p in pays], "| completions:", done)
    print("characters:", [(f["name"], f["gold"], f["flags"]) for f in folks])
    print("gear by source:", [(g["name"], g["source"], g["n"]) for g in gear])
    if "event completed" in srv:
        if inst != "finished" or done < 1:
            fail("the event completed but the API did not record it")
        print(f"E2E EVENT OK: the party finished The Emerald Serpent ({restarts} setbacks on the way)")
    else:
        print("E2E EVENT RAN, but the party did not win this time (logs:", tmp, ")")
        sys.exit(2)
finally:
    for p in procs:
        p.terminate()
    try:
        pg.cleanup()
    except Exception:
        pass
