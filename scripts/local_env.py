#!/usr/bin/env python3
"""Writes deploy/{api,game,web}/.env for running the production layout locally.

Reads the settings you already maintain (services/api/.env and game/client/client_env.json) so
secrets are entered once. Local ports: web 8080, API 8081, game server 8082; the API's private
port 8000 is how the game server reaches it (production: bind it to the host's private IP).
PLAYERS=n sets the party size that starts a battle (default 1).
PUBLIC_HOST=<public ip or domain> prepares a build other people can reach: the web build points at that
host instead of localhost, CORS allows its origin, and the environment becomes "shared" (guests off).
"""
import json
import os
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
api_env_path = root / "services/api/.env"
if not api_env_path.exists():
    sys.exit("services/api/.env is missing (copy services/api/.env.example and fill it in)")

api: dict[str, str] = {}
for line in api_env_path.read_text().splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        api[k] = v.split("  #")[0].strip()
client = json.loads((root / "game/client/client_env.json").read_text())

WEB, API, GAME = 8080, 8081, 8082
public = os.environ.get("PUBLIC_HOST", "").strip()
host = public or "localhost"
web_origin = f"http://{host}:{WEB}"
environment = "shared" if public else api.get("GAME_API_ENVIRONMENT", "local")


def write(name: str, lines: list[str]) -> None:
    p = root / "deploy" / name / ".env"
    p.write_text("\n".join(lines) + "\n")
    p.chmod(0o600)
    print("wrote", p.relative_to(root))


write("api", [
    "SITE_ADDRESS=:80", f"HTTP_PORT={API}", f"HTTPS_PORT={API + 362}",
    "API_PRIVATE_BIND=0.0.0.0", "API_PRIVATE_PORT=8000",  # local only: the game container reaches it via the host
    *[f"{k}={v}" for k, v in api.items()
      if k.startswith("GAME_API_") and k not in ("GAME_API_ALLOW_GUESTS", "GAME_API_ENVIRONMENT")],
    f"GAME_API_ENVIRONMENT={environment}", "GAME_API_ALLOW_GUESTS=false",
    f'GAME_API_CORS_ORIGINS=["{web_origin}"]',
])
write("game", [
    "SITE_ADDRESS=:80", f"HTTP_PORT={GAME}", f"HTTPS_PORT={GAME + 362}",
    "API_URL=http://host.docker.internal:8000",
    f"GAME_API_SERVER_KEY={api['GAME_API_SERVER_API_KEY']}",
    f"GAME_ENV={environment}",
    f"PLAYERS={os.environ.get('PLAYERS', '1')}",
])
write("web", [
    "SITE_ADDRESS=:80", f"HTTP_PORT={WEB}", f"HTTPS_PORT={WEB + 362}",
    f"SUPABASE_URL={client['supabase_url']}", f"SUPABASE_PUBLISHABLE_KEY={client['supabase_publishable_key']}",
    f"API_URL=http://{host}:{API}", f"SERVER_URL=ws://{host}:{GAME}",
])
if public:
    print(f"\nPublic build for {public}. Forward TCP {WEB}, {API} and {GAME} on your router to this PC and allow them "
          f"in the Windows firewall (never {8000}). Testers open http://{public}:{WEB}")
