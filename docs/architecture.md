# Architecture & Decisions

- **Godot version:** pinned to 4.7.2-stable (`.godot-version`). Run via `scripts/godot.sh` (Linux `godot` on PATH, else the Windows console build under WSL, or `GODOT_BIN`).
- **Layout:** one repo, one Godot project at the root.
  - `game/shared/` — domain models, config (no networking, no persistence).
  - `game/server/` — dedicated headless server (`server_main.tscn`, `scripts/run_server.sh`).
  - `game/client/` — browser client (`client_main.tscn`, the project main scene).
  - `services/api/` — FastAPI (uv-managed); auth/persistence only, no combat logic.
  - `tests/` — GDScript headless runner (`tests/run_tests.gd`); `scripts/test.sh` runs Godot + pytest.
- **Guest mode:** enforced server-side in the API (`Settings.guests_enabled` is false outside `environment=local`).
- **Deviation:** a tiny in-repo test runner is used instead of GUT to avoid a vendored dependency; swap later if needed.
- **Open verification (Phase 2/5):** web export + WebSocket behaviour on 4.7.2; Supabase JWT validation approach (JWKS vs. legacy shared secret).

## Provisional values
All in `game/shared/config/balance.json` (AP thresholds, movement bonus, beats per round, timeouts, AI weights). They are placeholders, not confirmed design.

## Combat architecture (Phases 2–4)

- `game/combat/battle.gd` — the authoritative encounter: planning, Ready/commit (AP reservation), beat resolution, victory, per-recipient snapshots and event filtering. Pure logic; no timers, networking or persistence.
- `game/combat/beat_resolver.gd` — one beat: steps ordered by skill speed, ties by a server-generated priority shuffled once per beat; re-validation at execution; interruption points; reactions.
- `game/combat/plan_validator.gd`, `pathfinder.gd`, `visibility.gd`, `ai_planner.gd`, `encounter.gd` (prototype map + units).
- `game/server/server_app.gd` — WebSocket transport, identity, lobby, real-time pacing (planning timeout, beat cadence), disconnect grace period.
- `game/shared/net/gateway.gd` — autoload carrying RPCs; client→server calls only run on the server.
- `game/client/` — `net_client.gd` (auto-reconnect), `board/board_3d.gd` + `board/camera_rig.gd` + `board/unit_3d.gd` (3D board, orbit camera, unit scenes; art lives in `game/content/`, see docs/editor-guide.md), `client_main.gd` (UI), `bot_main.gd` (headless scripted player for e2e).

### Interpretations of the handoff (provisional, all flagged for review)
- **Beat model:** each active combatant performs one step per beat: a move step covers up to `tiles_per_ap` tiles (1 AP, plus surcharge per difficult tile); a skill stage is one beat. 8 beats per round (`balance.json`).
- **Reactions:** `Disrupt` is prepared (1 AP, no usage consumed), lasts 6 beats, triggers right after an enemy's first stage of a multi-stage skill within range 3 + LOS, consumes its usage then, adds 2 interruption points. Reaction effects never start skills, so reactions cannot chain.
- **Occupied tiles:** passing through any occupied tile is not allowed (stop at last valid tile).
- **Enemies at 0 HP are eliminated** (no downed/revival for AI units).
- **Tile-targeted attacks** hit only opposing combatants; no friendly fire.
- **Simultaneous wipe** = draw (no tie rule specified).
- **Fog:** hidden enemies are omitted from snapshots; events involving only hidden units are dropped; if a hidden unit acts on a visible one, it's shown as "Something unseen". Plans are never sent except to their owner.
- **Disconnects:** committed plans stand; a not-Ready player gets their current valid queue at the timeout. With nobody connected, timers freeze and the 5‑minute monotonic grace period runs; after it the instance is destroyed. After a finished battle the same party restarts after 10 s (prototype convenience).
- **Identity:** guests are accepted only when the server runs with `--env=local --allow-guests` (default env is `production`); reconnect uses a server-issued secret token, never a client-chosen id. Supabase auth replaces this in Phase 5.

### Not yet verified
- Web export + WebSocket in a real browser (no export templates installed here; `export_presets.cfg` is ready).
- WSS: the server supports `--tls-cert/--tls-key`; production will likely terminate TLS at a load balancer.

## Persistence (Phase 5, local Postgres)

- **Schema:** `services/api/migrations/0001_init.sql` — worlds (with `definition_version` and `state_revision`), world_members, characters (one *active* per player per world via a partial unique index; retired rows kept), combat_results (+ participants). RLS is enabled with no policies, so Supabase `anon`/`authenticated` roles can't read anything directly; only the API's privileged connection can.
- **Local Postgres:** tests and the e2e script use `pgserver` (an embedded Postgres 16 wheel), so no Docker or system Postgres is needed. For a persistent dev DB point `GAME_API_DATABASE_URL` at any Postgres; migrations run on API startup. Moving to Supabase = a different connection string (plus an optional FK to `auth.users`).
- **Auth:** `app/auth.py` accepts HS256 (legacy shared secret) or asymmetric (JWKS) Supabase tokens; the algorithm family comes from server config, never from the token header. `aud`/`exp`/`sub` required. Guest tokens are rejected unless `environment=local` and guests are enabled. **Verify against the real Supabase project's signing-key setting before Phase 7.**
- **Boundary:** the Godot server holds only a service key (`GAME_API_SERVER_KEY` env var). It forwards the client's token to `POST /internal/auth/session` (identity + world membership + active character) and commits results via `POST /internal/combat-results`. Gameplay code sees only `Persistence` (`game/server/persistence.gd`); `HttpPersistence` is the HTTP implementation.
- **Results:** XP rewards are decided by the Godot server (provisional values in `balance.json`); the API records them atomically with the result row, idempotent per `idempotency_key` (same payload → returns stored result; different payload → 409; any failure rolls everything back).
- **Not yet built:** world membership approval flow (members are inserted directly in tests/e2e), sign-in UI in the client (use `--token=` for now), shared-world revision bumps (nothing in Phase 5 changes shared world state), retirement blocking during travel/activities.

Checks: `uv run --project services/api pytest` (16 API tests, real Postgres), `uv run --project services/api python scripts/e2e_persistence.py` (API + Godot server + 3 bots + a bad-token bot).

## World foundation (Phase 6)

- **Templates** (`services/api/templates/<id>@<version>.json`, validated by `app/templates.py`): immutable versioned blueprints (nodes, routes, activities, rules). A world pins `(template_id, definition_version)` at creation and is initialized exactly once: initial visibility and one-time-activity state are copied into rows. Editing/adding a template version never touches existing worlds; moving a world to a new version would need an explicit migration (not built). Content is placeholder.
- **Graph & discovery:** routes are first-class with stable ids; several routes may join the same nodes. Discovery has two scopes, `character` and `world`, chosen per discovery event; a character sees default-visible ∪ world-scope ∪ their own discoveries.
- **Revision:** `worlds.state_revision` increases by exactly 1 in each successful transaction that changes shared world state (world-scope reveal that was new, completion of a one-time activity or a completion that reveals something new). Character-scope discoveries, no-op reveals, replays and failed transactions do not advance it.
- **Membership:** request → host approve/reject; approval grants access only (no character). Host may remove members (never the host); removal sets `status='removed'`, keeping all data; reapproval restores the same row and character.
- **Activities:** each node has a board (the overview lists activities at discovered nodes). Starting requires membership, a character, a discovered node and physical presence (`characters.node_id`). Duplicate instances and a second concurrent major instance are prevented by partial unique indexes (atomic reservation, tested under concurrency). Roster: leader-only start/cancel, capacity per activity, locked after start, no voluntary leaving after start.
- **Completion:** `POST /internal/instances/{id}/complete` (service key) atomically marks the instance finished, claims the one-time activity (first completion wins), applies `on_complete` reveals and bumps the revision once. Replays return the stored outcome. The Godot server (`--instance-id=`) admits only rostered characters, completes the instance on victory and cancels it otherwise.
- **Not built (needs presence/travel):** travel and the campaign clock, host succession/expiry (depends on who is connected, so it belongs to the Godot session layer), ending a removed member's live session immediately (the API only blocks the next verification), retirement blocking during travel/activities, template migrations.

## Player flow and battle lifecycle (server)
- The server keeps one party at a time. Players arriving in the lobby get `s_lobby` ({players, needed}); the battle starts when the party is full.
- When a battle ends the server sends `s_result` ({outcome, rounds, xp, you, saved}) at once (saved=false) and again after the API stored the
  result (saved=true). There is no automatic replay: players press Continue (disconnecting), and when the last one leaves the server resets to an
  empty lobby. A player who reconnects to the result screen is sent the result again. After `RESULT_HOLD_MS` (120 s) any stragglers are removed.
- Joining a world: `GET /worlds/{id}/membership` returns the user's standing (member / pending / rejected / removed / none) and whether they are the
  host; non-members request access, the host approves or rejects. Requests carry the requester's email (display label only).

## Worlds and rooms
- After sign-in the client always shows a world picker (`GET /worlds/available`: every world, its player count and the caller's standing; no member identities).
  Opening a world runs the membership flow (member -> character, otherwise request to join).
- The battle server is not bound to a world. Each client names the world it is entering in `c_hello`; the server has the API confirm membership and the
  character in that world, then places the player in that world's room (own lobby, battle, clocks, result). Rooms never mix players.
  `--world-id` (or an activity instance's world) optionally restricts a server to one world. `scripts/e2e_worlds.py` runs two worlds at once on one server.

## Stats and encounters as resources
Unit stats are `UnitTemplate` resources (`game/content/stats`), and an `EncounterDef` resource (`game/content/encounters/prototype.tres`) names the map, the party
classes and the enemy roster. `Encounter.build` validates them (unknown skills, duplicates) and creates the combatants; spawn tiles come from the map's
markers. `tools/generate_stats.gd` produced the first files from the numbers that used to be in `encounter.gd`, and `tests/unit/test_stats.gd` pins them to
those original numbers. 

## Skills as resources
Each skill is a `SkillDef` resource (`game/content/skills`, with `SkillStage` sub-resources) listed in `skill_set.tres`; units reference the resources directly.
`SkillDef` still exposes `stages` (array of dictionaries), `reaction` and `total_ap()`, so the battle rules did not change. `SkillDb.load_file()` returns deep copies
(tests mutate speed/stability). `tools/generate_skills.gd` converted the former `skills.json`; `tests/unit/test_skills.gd` pins every value to it.
Only `config/balance.json` remains a JSON tuning file.

## Client screens: signals up, calls down
Before a battle the client shows one screen at a time. Each screen (`game/client/screens/*.tscn`, e.g. `SignInScreen`, `WorldPickerScreen`,
`CharacterCreator`) is a self-contained scene that only displays things and announces what the player did through signals; it never touches the network.
`AccountFlow` (`game/client/account_flow.gd`) is the coordinator: it owns the Supabase session, every call to the API and the routing, listens to the
screens' signals, and calls methods on the screens to tell them what to show. `ClientMain` owns the connection to the battle server and the battle UI,
and talks to `AccountFlow` through its signals (`entered`, `backed_out`, `token_refreshed`) and `show_lobby` / `return_to_menu`. Adding a screen means a new
scene + script, one instance in `account_flow.tscn`, one entry in `_screens`, and the signal connections (worked example in docs/guide/01-login-screen.md).
