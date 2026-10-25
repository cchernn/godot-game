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
- **Disconnects:** committed plans stand; a not-Ready player gets their current valid queue at the timeout. With nobody connected, timers freeze and the 5‑minute monotonic grace period runs; after it the party's battle is abandoned and the API cancels the party.
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
- **Membership:** request → host approve/reject; approval grants access only (no character). Host may remove members (never the host); removal sets `status='removed'`, keeping all data; reapproval restores the same row and character. The host can also list members (`GET /worlds/{id}/members`), rename the world (`POST .../rename`) and delete it for good (`POST .../delete` with `confirm_name` equal to the world's name; refused with 409 while an activity is running). Deletion removes members, characters, parties, discoveries and combat history, and cannot be undone. The World management screen has all of these. `GET /worlds/{id}/info` gives the host read-only facts (template and version, created date, member, character, live-party and battle counts).
- **Activities:** each node has a board (the overview lists activities at discovered nodes). Starting requires membership, a character and a discovered node; physical presence (`characters.node_id`) is required only when the template sets `rules.require_location`. A second concurrent major instance is prevented by a partial unique index (atomic reservation, tested under concurrency); minor activities may run in several parties at once. Roster: join requests decided by the leader, leader-only start/cancel, capacity per activity, locked after start, no voluntary leaving after start, leader handover (see Parties below).
- **Completion:** `POST /internal/instances/{id}/complete` (service key) atomically marks the instance finished, claims the one-time activity (first completion wins), applies `on_complete` reveals and bumps the revision once. Replays return the stored outcome. The Godot server admits only rostered characters of an active party, completes the instance on victory and cancels it otherwise.
- **Not built:** the campaign clock (travel is instant), host succession/expiry (depends on who is connected, so it belongs to the Godot session layer), ending a removed member's live session immediately (the API only blocks the next verification), retirement blocking during travel/activities, template migrations.

## Parties and the battle lifecycle
A **party** is a leader, a roster and a place on the map (`parties`, `party_members`). Every character is always in exactly one party: a lone character is a
party of one, made when the character is created (or on first use for older characters). An **activity run** (`activity_instances`, with a `party_id`) is the
party playing one activity; the battle server runs it, and when it ends the party is idle again at the same node. The API owns all of it.
- **Joining a party:** `POST /parties/{id}/requests`; the **leader** approves or rejects (`/parties/{id}/requests/{rid}/approve|reject`), the player can cancel
  (`/requests/cancel`). Joining only works from the party's own node, for a character who is on their own (leave a group first), while the party is idle
  and under `max_party_size`. Approval moves the character out of their party of one and withdraws their other pending asks. There is no direct join.
- **Leaving:** `POST /parties/{id}/leave` puts you in a new party of one; if the leader leaves, the longest-standing member leads on; an emptied party closes.
  A lone character cannot leave. The leader can also hand over (`POST /parties/{id}/leader`). None of this is possible mid-activity.
- **Travel:** `POST /parties/{id}/travel {node_id}` (leader only, idle party) moves the party and every member along a discovered route to a neighbouring
  node. It is instant for now: the routes' `travel_days` are stored but unused until the campaign clock exists.
- **Starting an activity:** `POST /parties/{id}/start {activity_id}` (leader only) creates the run as `active` with the party's roster. The party must be at the
  activity's node when the template rule `require_location` is on (it is), the node must be discovered, and the party must fit `max_players`. Several parties may
  run the same activity at once (the one-live-major-instance-per-world reservation stays). Members' overworld screens notice the run on their next refresh and
  connect to the battle server. `max_party_size` is a template rule (PROVISIONAL, 4).
- **Listing:** `GET /worlds/{id}/parties` returns every party with its roster, node, current run and the caller's relation to it (leader / member / pending /
  none) and whether it is `here` (at the caller's node); `GET /worlds/{id}/parties/me` is the caller's own, `GET /parties/{id}` one of them.
- **The battle server** is told the world and the party in `c_hello`. The API (`/internal/auth/session` with `instance_id`) checks the character is on the
  roster of an *active* run and returns the run and its activity's `encounter` id; the server loads `game/content/encounters/<id>.tres`, seats the
  whole roster in roster order, and starts when everyone has arrived or after `lobby.gather_seconds` (a late or absent member keeps their seat and can still
  join in, like a dropped player). Rooms are keyed by party; two parties never see each other. Guest play (local development) is one anonymous room that
  starts at `lobby.players_required`.
- **Reconnecting:** a party's seat belongs to the character, so a closed tab can return from the hub (**Return to battle**) while the party is active. If the
  server restarted and lost the room, the next arrival builds a fresh room and battle for the same roster. If nobody comes back within the grace period the
  server cancels the party.
- **The end:** the server sends `s_result` ({outcome, rounds, xp, you, saved}) at once (saved=false) and again after the API stored the result (saved=true), and
  completes the instance on victory (applying world changes) or cancels it otherwise. Players press Continue (disconnecting); when the last one leaves, the room
  is dropped. A player who reconnects to the result screen is sent the result again. After `RESULT_HOLD_MS` (120 s) any stragglers are removed.
- **Activities say what to run:** each activity in the world template names an `encounter` (a file in `game/content/encounters`) and a `max_players`.
  `tests/unit/test_stats.gd` checks every activity's encounter exists and has enough seats.
- Joining a world: `GET /worlds/{id}/membership` returns the user's standing (member / pending / rejected / removed / none) and whether they are the
  host; non-members request access, the host approves or rejects. Requests carry the requester's email (display label only).

## Battle screen

A strip of cards under the board (`game/content/ui/unit_card.tscn`) shows the player's party (you first) and the enemies in sight: name, class, HP bar,
and for allies their AP (and AP reserved after Ready) and whether they are Planning or Ready. The snapshot gives allies each other's AP and Ready state, never
their skills or plans; hidden enemies get no card.

While planning, picking a skill shades what it can reach (blue: tiles a walk can reach with the AP you have left, or a skill's range with line of sight) and
marks the units it can target (green). Hovering a tile says what a walk there costs ("3 tile(s), 4 AP: 2 more than you have") or why a target is not valid
(out of range, no line of sight, an ally). Each queued action shows the beats it takes (a walk is ceil(tiles / tiles per AP) beats, a skill one per stage),
with "Beats used: n of 8" under the queue. This lives in `game/client/targeting_preview.gd` (pure functions, unit-tested); the shading materials are
`game/content/board/materials/range.tres` and `valid.tres`, set on the board scene. It is a preview only: the server validates every plan.

While a round resolves the server sends each beat's events one beat delay (700 ms) apart; the log groups them under "Round n · Beat b" headers and adds a
"Last round: 3 hit, 1 miss" recap line when the next round starts. The status line counts the planning time down and turns amber and then red
(`timer_warn_seconds` 30 and `timer_urgent_seconds` 10, exported on the client scene, PROVISIONAL). Tiles your team cannot see stay fogged on the board;
hovering one says so, and events about an unseen enemy are tinted purple in the log.

## Characters

- One active character per player per world. `GET /worlds/{id}/characters` lists every character in the world (active, then retired) with its
  owner, which is the owner's join label (their email) or `Host` / a short id; `GET /worlds/{id}/characters/me/battles` is the caller's last 5 battles.
- The Character page (`character_screen.tscn`, tabs: Overview, Battles, Characters) reads stats and skills from the class resource in
  `game/content/stats/classes`, so editing the resource changes the page. Retiring needs the character's name typed and is refused (409) while the
  character is in a running activity; retiring takes them out of their party; the retired character stays in the world's "Fallen" list and the player can create a new one.
- Levels do not move yet (all level 1). The prototype template sets the world rule `reset_xp_after_battle` (PROVISIONAL, testing aid): the award is
  recorded in the battle history, then the character's XP goes back to 0. Remove the rule from the template to keep XP.
- A party leader can hand the party to another member while it is idle (`POST /parties/{id}/leader`).

## Worlds and rooms
- After sign-in the client always shows a world picker (`GET /worlds/available`: every world, its player count and the caller's standing; no member identities).
  Opening a world runs the membership flow (member -> the world hub, otherwise request to join). The hub (parties, character, world management for the host,
  settings) is the main menu; a player without a character is sent to the character creator from there.
- The battle server is not bound to a world. `--world-id` optionally restricts a server to one world. `scripts/e2e_worlds.py` runs two parties in two worlds at
  once on one server.

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
and talks to `AccountFlow` through its signals (`entered(server, token, name, world, party)`, `backed_out`, `token_refreshed`) and `show_lobby` / `return_to_menu`. Adding a screen means a new
scene + script, one instance in `account_flow.tscn`, one entry in `_screens`, and the signal connections (worked example in docs/guide/01-login-screen.md).

The screens: `sign_in`, `world_picker`, `join` (ask to join a world), `world_hub` (the main menu), `character` (view), `character_creator`, `overworld`
(the map and your party), `world_management` (the host's join requests), `settings` and `lobby` (waiting on the battle server for the party to arrive).
`overworld` and `join` refresh themselves on a `Timer` while visible.

The **overworld** (`overworld_screen.tscn`) has the map on the left (`MapCanvas`: a button per discovered node, a line per discovered route) and a side panel:
your party (roster, leader tools, join requests, Leave), the place you picked (its activities, Start, Travel) and the other parties standing at your node (Ask
to join). The leader travels the party and starts activities; the rest watch, and are taken into the battle when it starts. Node positions are not in the
world template (that is game data); they live in `game/content/overworld/map_layout.tres` (a `MapLayout`, fractions of the map area). Nodes missing from it are
spread around a ring, so a new template node always shows up. Why a button is disabled is written under it (`OverworldScreen.travel_problem` / `start_problem`).
