# Provisional values

Nothing here is confirmed design. Every value is a placeholder that must stay changeable without touching mechanics code. This is the one list;
if you add a placeholder anywhere, add it here.

## Combat (`game/shared/config/balance.json`)

| Value | Now | Meaning |
|---|---|---|
| `ap.base_capacity`, `max_capacity`, `dexterity_thresholds` | 3, 5, [6, 10] | Action points per round |
| `stats.*` (`attribute_cap` 10, `hp_base` 14, `hp_per_vitality` 3, `power_per_might` 1, `accuracy_baseline` 4 / `_per_dexterity` 1, `evasion_baseline` 5 / `_per_agility` 1) | see file | How the four attributes (0-10 for a player: class base plus earned grants; gear and statuses go on top) become HP, damage, accuracy and evasion |
| Context actions | cost AP like skills; reach 1 (Manhattan); state per battle only; blocking objects block walking but not sight; picked-up items capped by the item's `max_stack` in battle and 99 when saved | Map objects (Phase 6) |
| Levels and XP | none | There is no experience and there are no levels. Attributes grow slowly and only through Attribute Grants (event flags set by activities, items or story events); skills through Skill Unlocks (an event flag or an attribute value). The database keeps `characters.level`, `xp`, `allocated`, `learned_skills` and `combat_result_participants.xp_awarded` but nothing reads or writes them |
| Class attributes and the absence of armor | see class `.tres`: warrior 3/4/3/8, hunter 2/7/6/4, mage 3/6/4/3 (might/dex/agi/vit) | Armor is gear-only (gear comes later) |
| `movement.*` | 1 tile per AP, bonus at Agility 6 / 10, difficult terrain +1 | How far an AP moves a character |
| `combat.beats_per_round` | 8 | Beats in a round |
| `combat.planning_timeout_seconds` | 90 | Planning time before the server commits plans |
| `combat.beat_delay_ms` | 700 | Pause between beats |
| `combat.base_hit_chance`, `crit_*`, `side_multiplier`, `rear_multiplier`, `accuracy_per_point` | 0.9, 5% x1.5, x1.25, x1.5, 0.02 | Hit and damage rules |
| `combat.sight_range`, `max_step_height`, `revive_hp_fraction` | 8, 1, 0.2 | Fog of war, climbing, revive |
| `ai.weights` | see file | How enemies choose actions |
| `instance.disconnect_grace_seconds` | 300 | A battle nobody is connected to is cancelled after this |
| `event.revive_hp_percent`, `event.step_pause_ms` | 25, 3000 | An event's characters start each battle with at least this percent of their maximum hit points; how long the party sees a battle's end before the next step |
| `lobby.players_required`, `gather_seconds` | 2, 30 | Guest lobby size, and how long a party battle waits for late arrivals |

Client-side, on the scene root (`client_main.tscn`): `timer_warn_seconds` 30 and `timer_urgent_seconds` 10 (countdown colours), `escape_confirm_seconds` 4.
Unit stats and skills are `.tres` resources under `game/content/` and are all provisional too.

## Rules of the world (`services/api/templates/prototype@1.json`, `rules`)

| Rule | Now | Meaning |
|---|---|---|
| `discovery_scope` | `character` | Each character discovers places for themselves |
| `require_location` | `true` | A party must be at an activity's place to start it |
| `max_party_size` | 4 | PROVISIONAL |

## Rules written in code, not yet configurable

- **Travel is instant.** `travel_days` on routes is stored but unused until there is a campaign clock.
- **Escape always succeeds and costs nothing** (`Battle.escape`). It could later get a chance, a cost, or a cooldown. If nobody is left standing and anyone escaped, the outcome is `escaped`, even when the others died.
- **Presence window:** 30 seconds (`GAME_API_PRESENCE_SECONDS`); the client sends a heartbeat every 10 seconds (`PresenceTimer` in `account_flow.tscn`).
  A player returning after the window leaves an idle party whose other members are offline; idle parties whose members are all offline are disbanded when
  the world's parties are listed. A character with no heartbeat on record counts as online.
- **One login per account:** a login holds the account for 30 seconds after its last API call or heartbeat (`GAME_API_SESSION_SECONDS`); another login is refused (HTTP 423,
  "signed in on another device") until then, or until the holder signs out. Nothing takes a live login over. A closed tab frees the account after the window.
- **Shield:** a shield lasts the round or only one beat (the effect's *Lasts*), does not stack within a length, armor applies before it; a one-beat shield soaks damage before a round shield. Defend gives a one-beat shield of 4 (`defend.tres`, forced once per turn), Shield Wall a round shield of 8 (`shield_wall.tres`). Heals and shields never miss. Defend is on every class for now.
- **Once per turn:** a skill's frequency is Auto by default: once per turn when it costs more than 1 AP, otherwise repeatable (Move, items and context actions are unlimited).
- **Class skills (all numbers and costs provisional):** Warrior: Power Strike (2 AP, 12), Shield Wall (1 AP, shield 8, forced once per turn). Hunter: Maim Shot (2 AP, draw then shoot, range 5, 4 damage, 3 interrupt points, 50% to maim for 2 turns: no attacks or skills), Lob Shot (2 AP, tile, range 9, no line of sight needed, 8 damage). Mage: Fireball (3 AP, two charge beats then a star of 5 tiles, range 5, 14 damage), Ice Floor (2 AP, charge then a line of 3 tiles toward the aimed tile, range 4, applies Frozen). Frozen (`statuses/frozen.tres`): rooted for 1 turn, a placeholder for what freezing should do; areas hit friend and foe alike, so the ice also freezes allies in the line. Disrupt, Revive and Bolt stay as files (Bolt is the cultist's) but no class uses them.
- **Statuses (Phase 2):** durations count turns; a status applied mid-turn counts the rest of that turn as its first turn; each-turn effects run at the start of a turn
  (so a status applied mid-turn first ticks next turn), once per stack; stat changes apply at once, but AP capacity only refreshes at the start of the next round;
  a stunned unit loses the rest of its queue and cannot react; an Apply Status after a damage effect only lands if the damage connected. No statuses ship yet.
- **Areas (Phase 3):** a cone is 1, 3, 5... tiles wide per row; a line or cone runs along the dominant axis toward the aim (the user's facing if aimed at their own tile);
  walls stop an area by default (`requires_los`); a radius is checked from its centre, a line or cone from the user. No area skills ship yet.
- **Items (Phase 4):** `items.battle_slots` = 4 kinds per battle; no cooldown (an item can be used as often as there are copies, AP and beats); a copy is used up when the
  action begins (not when skipped) and only saved if the battle ends with a result; using more than the character carries refuses the result; enemies carry nothing; the only way to get items
  is the dev script. No items ship yet.
- **Party joining:** only a lone character, only at the party's node, only while the party is idle; the leader decides.
- **Classes** (`services/api/app/rules.py`) and their client mirror are placeholders.
- **Simultaneous wipe** is a draw.

- **Gear (provisional):** two weapon slots, one armor slot, one accessory slot (none yet). Armor is a flat reduction per hit (min 1 damage) and adds up over gear. Warrior: iron longsword (Slash 1 AP, 7 damage, melee), wooden shield (armor 1), iron chainmail (armor 3). Hunter: bow (Shoot 2 AP, draw then shoot, range 5, 8 damage), iron dagger (Stab 1 AP, 5 damage, melee), leather armor (armor 1). Mage: wooden staff (Bash 1 AP, 4 damage, melee), garb (armor 0). A player's Attack list is what their weapons grant; with no weapon they fall back to the plain Attack (`skill_set.tres`, Unarmed). Loadouts are the class's starting gear for now; characters changing gear comes later.

- **Gold and rewards (provisional):** one purse of gold per character. Each encounter pays its own `gold` (EncounterDef; prototype 25) to every player still in the fight when it is won, the same amount for everyone; escaped characters and losses earn nothing. A run's authored `rewards` (flags, items) go to the same characters, who also get the activity's completion record. Gold has no use yet (no shops).
