# Provisional values

Nothing here is confirmed design. Every value is a placeholder that must stay changeable without touching mechanics code. This is the one list;
if you add a placeholder anywhere, add it here.

## Combat (`game/shared/config/balance.json`)

| Value | Now | Meaning |
|---|---|---|
| `ap.base_capacity`, `max_capacity`, `dexterity_thresholds` | 3, 5, [10, 16] | Action points per round |
| `movement.*` | 1 tile per AP, bonus at Dexterity 12 / 18, difficult terrain +1 | How far an AP moves a character |
| `combat.beats_per_round` | 8 | Beats in a round |
| `combat.planning_timeout_seconds` | 90 | Planning time before the server commits plans |
| `combat.beat_delay_ms` | 700 | Pause between beats |
| `combat.base_hit_chance`, `crit_*`, `side_multiplier`, `rear_multiplier`, `accuracy_per_point` | 0.9, 5% x1.5, x1.25, x1.5, 0.02 | Hit and damage rules |
| `combat.sight_range`, `max_step_height`, `revive_hp_fraction` | 8, 1, 0.2 | Fog of war, climbing, revive |
| `ai.weights` | see file | How enemies choose actions |
| `instance.disconnect_grace_seconds` | 300 | A battle nobody is connected to is cancelled after this |
| `lobby.players_required`, `gather_seconds` | 2, 30 | Guest lobby size, and how long a party battle waits for late arrivals |
| `rewards.xp_participation`, `xp_victory_bonus` | 20, 80 | XP per battle |

Client-side, on the scene root (`client_main.tscn`): `timer_warn_seconds` 30 and `timer_urgent_seconds` 10 (countdown colours), `escape_confirm_seconds` 4.
Unit stats and skills are `.tres` resources under `game/content/` and are all provisional too.

## Rules of the world (`services/api/templates/prototype@1.json`, `rules`)

| Rule | Now | Meaning |
|---|---|---|
| `discovery_scope` | `character` | Each character discovers places for themselves |
| `require_location` | `true` | A party must be at an activity's place to start it |
| `max_party_size` | 4 | PROVISIONAL |
| `reset_xp_after_battle` | `true` | PROVISIONAL testing aid: the award is recorded in the history but the character starts the next battle at 0 XP |

## Rules written in code, not yet configurable

- **Travel is instant.** `travel_days` on routes is stored but unused until there is a campaign clock.
- **Escape always succeeds and costs nothing** (`Battle.escape`). It could later get a chance, a cost, or a cooldown. An escaped character gets participation XP but
  not the victory bonus (`ServerApp._xp_for`). If nobody is left standing and anyone escaped, the outcome is `escaped`, even when the others died.
- **Presence window:** 30 seconds (`GAME_API_PRESENCE_SECONDS`); the client sends a heartbeat every 10 seconds (`PresenceTimer` in `account_flow.tscn`).
  A player returning after the window leaves an idle party whose other members are offline; idle parties whose members are all offline are disbanded when
  the world's parties are listed. A character with no heartbeat on record counts as online.
- **One login per account:** a login holds the account for 30 seconds after its last API call or heartbeat (`GAME_API_SESSION_SECONDS`); another login is refused (HTTP 423,
  "signed in on another device") until then, or until the holder signs out. Nothing takes a live login over. A closed tab frees the account after the window.
- **Shield (Phase 1):** lasts until the end of the round, does not stack, armor applies before it; Defend gives a shield of 4 (`game/content/skills/defend.tres`). Heals and shields never miss. Defend is on every class for now.
- **Statuses (Phase 2):** durations count turns; a status applied mid-turn counts the rest of that turn as its first turn; each-turn effects run at the start of a turn
  (so a status applied mid-turn first ticks next turn), once per stack; stat changes apply at once, but AP capacity only refreshes at the start of the next round;
  a stunned unit loses the rest of its queue and cannot react; an Apply Status after a damage effect only lands if the damage connected. No statuses ship yet.
- **Areas (Phase 3):** a cone is 1, 3, 5... tiles wide per row; a line or cone runs along the dominant axis toward the aim (the user's facing if aimed at their own tile);
  walls stop an area by default (`requires_los`); a radius is checked from its centre, a line or cone from the user. No area skills ship yet.
- **Party joining:** only a lone character, only at the party's node, only while the party is idle; the leader decides.
- **Classes** (`services/api/app/rules.py`) and their client mirror are placeholders.
- **Simultaneous wipe** is a draw.
