# Unnamed — multiplayer tactical RPG prototype (Godot 4.7.2)

Designing layouts, tiles, units, animations or the camera in the Godot editor: see `docs/editor-guide.md`. A guided tour of how this game's screens
are built (for someone past the Godot basics): `docs/guide/01-login-screen.md`.

```
scripts/test.sh                      # Godot unit tests + FastAPI tests
scripts/smoke.sh                     # e2e: server + 3 scripted clients incl. reconnects
scripts/run_server.sh --players=2    # dedicated server (local env, guests on) on ws://127.0.0.1:9080
```
Play: run the server, then open the project in Godot 4.7.2 and press F5 (use *Debug → Customize Run Instances*
to launch several clients, optionally with args `--url=ws://127.0.0.1:9080 --name=Alice`).
(Guest play only: the battle starts once `lobby.players_required` guests join. Signed-in play runs parties; see below.) Design notes: `docs/architecture.md`.

## Playing with a Supabase account (local)

1. Fill `services/api/.env` (see `.env.example`) and check `game/client/client_env.json`
   (project URL, publishable key).
2. `scripts/stack.sh init && scripts/stack.sh up` starts the API, battle server and web client in Docker.
3. Open http://localhost:8080, or open the project in the Godot editor on Windows and press F5. Sign in, pick a world and create a character once,
   then open **Parties** from the world hub. The client falls back to the guest connect screen if `client_env.json`
   is absent or `--url=` is passed.

`tests/account_flow_check.gd` is a live check of the sign-in flow (needs `ACCT_EMAIL`/`ACCT_PASSWORD`
and a running API); it is not part of `scripts/test.sh`.

## The player flow
Open the page -> sign in or create an account (Supabase; new accounts confirm by email) -> **choose a world** from the list (every
world is listed with your standing in it, even when there is only one) -> if you are not in it yet, **Request to
join** and wait for the host (the host sees a pending count on **World management** in the hub and approves or rejects) -> create a
character once -> you land on the **world hub** (Parties, Character, World management for the host, Settings) -> **Parties**: start a party for an
activity (you lead it) or ask a leader to let you into one -> **party lobby** (the leader approves requests and presses **Start battle**) -> the battle server
gathers the party -> plan and ready each round -> result screen (victory/defeat, XP) -> **Continue** back to the hub. A closed tab can come back to a battle in
progress from the hub (**Return to battle**). Screens: `docs/editor-guide.md`; a real-browser test of this flow: `tests/browser/README.md`.
One battle server hosts every party in every world, one room per party.

## Deployment

Three services, each with its own Dockerfile, compose file and env file under `deploy/` (full detail and
the real-server checklist in `deploy/README.md`). Needs Docker with the Compose plugin; nothing else.

| Service | Local address | Compose stack |
|---|---|---|
| Web client | http://localhost:8080 | `deploy/web/` |
| API | http://localhost:8081 | `deploy/api/` |
| Battle server | ws://localhost:8082 | `deploy/game/` |

Commands (run from the repo root):

```bash
scripts/stack.sh init            # write deploy/*/.env from services/api/.env + game/client/client_env.json
scripts/stack.sh up              # build and start api, game, web (in that order)
scripts/stack.sh up web          # (re)deploy a single service: api | game | web
scripts/stack.sh ps              # status
scripts/stack.sh logs game       # follow a service's log
scripts/stack.sh down            # stop everything (or: down web)
```

### Own testing (localhost)
`scripts/stack.sh init && scripts/stack.sh up`, then open http://localhost:8080 (or press F5 in the Godot editor).
Nobody else can connect to `localhost`.

### Letting others test against your PC
1. `PUBLIC_HOST=<your public IP> scripts/stack.sh init` (use the *public* IP, not 192.168.x.x). This bakes
   `http://<ip>:8081` and `ws://<ip>:8082` into the web build, allows `http://<ip>:8080` in the API's CORS list,
   and sets the environment to `shared` (guests off).
2. `scripts/stack.sh up`
3. Router: forward TCP **8080, 8081, 8082** to this PC. Windows firewall: allow those inbound. **Do not forward 8000**
   (the game server's private link to the API).
4. Check `curl http://localhost:8081/health` shows `"environment":"shared","guests_enabled":false`, then open
   `http://<public IP>:8080` from outside your network (phone on mobile data).
5. If your IP changes, repeat steps 1-2. To go back to localhost, run `init` without `PUBLIC_HOST` and `up` again.

Everything is plain http/ws on bare ports, so use throwaway test accounts. Players must be members of the world (host-approved)
to create a character.

### Real servers (AWS etc.)
Each service goes on its own host with its own `deploy/<svc>/.env` (copy `.env.example`), a domain for HTTPS,
and `docker compose -f deploy/<svc>/compose.yaml up -d --build`. Steps, security groups and prebuilt-image
(ECR) workflow: `deploy/README.md`.
