# Unnamed — multiplayer tactical RPG prototype (Godot 4.7.2)

Designing layouts, tiles, units, animations or the camera in the Godot editor: see `docs/editor-guide.md`.

```
scripts/test.sh                      # Godot unit tests + FastAPI tests
scripts/smoke.sh                     # e2e: server + 3 scripted clients incl. reconnects
scripts/run_server.sh --players=2    # dedicated server (local env, guests on) on ws://127.0.0.1:9080
```
Play: run the server, then open the project in Godot 4.7.2 and press F5 (use *Debug → Customize Run Instances*
to launch several clients, optionally with args `--url=ws://127.0.0.1:9080 --name=Alice`).
The battle starts once `lobby.players_required` players join. Design notes: `docs/architecture.md`.

## Playing with a Supabase account (local)

1. Fill `services/api/.env` (see `.env.example`) and check `game/client/client_env.json`
   (project URL, publishable key, `world_id` the battle server is bound to).
2. `scripts/stack.sh init && scripts/stack.sh up` starts the API, battle server and web client in Docker (`PLAYERS=n` for the party size).
3. Open http://localhost:8080, or open the project in the Godot editor on Windows and press F5. Sign in, create a character once,
   then **Enter battle**. The client falls back to the guest connect screen if `client_env.json`
   is absent or `--url=` is passed.

`tests/account_flow_check.gd` is a live check of the sign-in flow (needs `ACCT_EMAIL`/`ACCT_PASSWORD`
and a running API); it is not part of `scripts/test.sh`.

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

`PLAYERS=3 scripts/stack.sh init` sets how many players start a battle (default 1).

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

Everything is plain http/ws on bare ports, so use throwaway test accounts. Players must be members of the world to
create a character (the join/approval screens are not built yet).

### Real servers (AWS etc.)
Each service goes on its own host with its own `deploy/<svc>/.env` (copy `.env.example`), a domain for HTTPS,
and `docker compose -f deploy/<svc>/compose.yaml up -d --build`. Steps, security groups and prebuilt-image
(ECR) workflow: `deploy/README.md`.
