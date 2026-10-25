"""Lists the parties in a world (where they stand, and what they are playing), as the host or tester account, for
checking the real-browser test between runs. A running activity that nobody is connected to is cancelled by the game
server after its grace period. Uses only the public client config and the player-facing API.
  uv run --project services/api python tests/browser/parties.py <email> <password>"""
import json
import pathlib
import sys

import httpx

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
env = json.loads((ROOT / "game/client/client_env.json").read_text())
email, password = sys.argv[1], sys.argv[2]
api = "http://localhost:8081"
tok = httpx.post(f"{env['supabase_url']}/auth/v1/token?grant_type=password",
                 headers={"apikey": env["supabase_publishable_key"]}, json={"email": email, "password": password}).json()["access_token"]
h = {"Authorization": f"Bearer {tok}"}
for w in httpx.get(f"{api}/worlds", headers=h).json():
    for p in httpx.get(f"{api}/worlds/{w['id']}/parties", headers=h).json():
        run = p["instance"]
        print(w["name"], p["id"], p["node_name"], run["activity_name"] if run else "idle", p["relation"], [m["name"] for m in p["members"]])
