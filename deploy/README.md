# Deployment: one compose stack per service

Production layout, also used locally. Each service has its own compose file, its own Dockerfile/image and
its own env file holding only what it needs:

| Service | Compose file | Image (Dockerfile) | Env file | Secrets it holds |
|---|---|---|---|---|
| API | `deploy/api/compose.yaml` | `unnamed-api` (`api.Dockerfile`) | `deploy/api/.env` | database URL, service key, JWT settings |
| Battle server | `deploy/game/compose.yaml` | `unnamed-game` (`game.Dockerfile`) | `deploy/game/.env` | service key only |
| Web client | `deploy/web/compose.yaml` | `unnamed-web` (`web.Dockerfile`) | `deploy/web/.env` | none (public values) |

Each stack has a Caddy in front for HTTPS (the web image includes its own). Postgres and login are Supabase.
Needs on a machine: Docker with the Compose plugin. Godot, the web export templates, Python and Caddy are
fetched during image builds (the first web build downloads ~1.3 GB of export templates, then it is cached).

## Locally
```bash
scripts/stack.sh init     # writes deploy/*/.env from services/api/.env and game/client/client_env.json
scripts/stack.sh up       # build + start api, game, web   (up game  = just one)
scripts/stack.sh ps | logs game | restart game | down
```
Web http://localhost:8080, API http://localhost:8081, game server ws://localhost:8082.
The Godot editor client (F5) uses `game/client/client_env.json`, which points at the same local ports.
Locally the API's private port 8000 is bound to all interfaces so the game container can reach it through the
host; on a server bind it to the private IP (below).

### Letting other people test against your PC
`PUBLIC_HOST=<your public IP or domain> scripts/stack.sh init && scripts/stack.sh up` rebuilds with that host baked into the web
build (use the *public* address, not 192.168.x.x), allows its origin in CORS and sets the environment to `shared` (guests off).
Then forward TCP 8080, 8081 and 8082 on your router to your PC and allow them in the Windows firewall. Never forward 8000.
Everything is plain http/ws on bare ports, so use throwaway test accounts. Run `init` again without `PUBLIC_HOST` to go back to localhost.

## One machine under your own domain
For a single VM, `deploy/vm/` runs all three services behind one Caddy that owns ports 80 and 443 (the per-service stacks above each want those ports, so they
suit one host per service). Only Caddy publishes ports; the API's private port stays on the compose network, where the battle server reaches it.
1. **DNS:** three A records pointing at the machine's public IP, for example `game.example.com` (what players open), `api.example.com` and `play.example.com` (the battle server's `wss://`).
2. **Firewall:** allow 80 and 443 (TCP, and UDP 443 for HTTP/3) from anywhere and 22 from your IP. Nothing else.
3. **Supabase:** make a production project (separate from your test one). In Authentication, set the Site URL to `https://<WEB_HOST>`.
4. **Settings:** `cp deploy/vm/.env.example deploy/vm/.env` and fill it in (host names, Supabase values, a new `openssl rand -hex 32` service key).
5. **Start:** `docker compose -f deploy/vm/compose.yaml up -d --build` (the first web build downloads ~1.3 GB of export templates).
6. **Check:** `https://<API_HOST>/health` shows `"environment":"production","guests_enabled":false`; open `https://<WEB_HOST>` and sign in.
Update with `git pull` and the same `up -d --build`. The game server and the web client share a message protocol, so rebuild them together; recreating `game` ends battles in progress.
The images build for the machine's CPU. The Dockerfiles fetch the x86-64 Godot build, so an ARM machine (such as Oracle's free Ampere VMs) first needs those downloads switched to the arm64 build.

## How the services find each other
- **Browser -> API:** the API's public `https://` address. The API's `GAME_API_CORS_ORIGINS` must list the web client's origin.
- **Browser -> game server:** its public `wss://` address.
- **Both addresses are baked into the web image** (`API_URL`, `SERVER_URL` in `deploy/web/.env`); changing them means rebuilding it.
- **Game server -> API:** the API's *private* address (e.g. `http://10.0.1.20:8000`). `/internal/*` is blocked on the public
  domain, so the game server cannot use that. Set `API_PRIVATE_BIND` to the API host's private IP and allow port 8000 in the
  security group only from the game server's security group. Never open it to the internet.
- **Same secret on both sides:** `GAME_API_SERVER_API_KEY` (API) must equal `GAME_API_SERVER_KEY` (game server).

## On real servers
1. One host per service (or fewer, if you like), with Docker + Compose installed and the repo cloned (or prebuilt images, below).
2. A domain per public service, e.g. `api.example.com`, `game.example.com`, `play.example.com`, each A-record'd to its host.
3. Security groups: 80/443 from anywhere and 22 from your IP on each host; additionally 8000 on the API host from the game server only.
4. On each host: `cp deploy/<svc>/.env.example deploy/<svc>/.env`, fill it in
   (`SITE_ADDRESS=<domain>`, `HTTP_PORT=80`, `HTTPS_PORT=443`; API: `GAME_API_ENVIRONMENT=production`, a **new** service key), then
   `docker compose -f deploy/<svc>/compose.yaml up -d --build`. Caddy fetches and renews the HTTPS certificates itself.
5. Check `https://api.example.com/health` shows `"environment":"production","guests_enabled":false`.

Prebuilt images instead of building on each server: build and push `unnamed-api`, `unnamed-game` and `unnamed-web`
(e.g. to ECR), set `API_IMAGE` / `GAME_IMAGE` / `WEB_IMAGE` in the matching env file, then
`docker compose -f deploy/<svc>/compose.yaml pull && ... up -d`. Build the web image with the production `API_URL`/`SERVER_URL`.

Recreating `game` ends any battle in progress, so deploy it between sessions. **The game server and the web client
share a message protocol (`game/shared/net/gateway.gd`): when it changes, rebuild and redeploy `game` and `web` together.** Secrets live only in the per-service
`.env` files (gitignored, never copied into an image); on AWS they can later come from Secrets Manager / SSM instead.
