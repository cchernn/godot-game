# Plan: the combat framework (effects, statuses, areas, items, progression)

Status: **Phases 1, 2 and 3 (committed) and 4 (implemented, not committed yet) are done; the rest is planned.** Work happens one phase at a time; each phase is tested, documented and committed on its own (when the owner says so).
Scope of this plan is the **framework only** (foundational changes). Specific skills, statuses, class content and items are discussed after all phases; where a phase needs an example it is a
**test fixture**, not shipped content. The scope is: the data model, the rules, the editor workflow and the UI hooks. Real class and skill design is done afterwards
in the Godot editor. Every number below is PROVISIONAL, lives in data (`.tres` or `balance.json`) and is listed in `docs/provisional-values.md` when it lands.

## Rules decided with the owner

- **Targeting modes** (per skill):
  - `CHARACTER` (target-based): the skill follows the chosen combatant. Range and line of sight are checked when the skill executes, so a target that moved but is
    still in range is still hit; if it moved out of range the skill is skipped ("out of range"). Planning always picks a single target.
  - `TILE` (tile-based): the skill hits whatever stands on the tile when it executes, or nothing ("strikes empty ground"). Tile skills are meant to hit harder to
    offset that risk (done in skill data, not code).
  - Order within a beat is by skill speed, as today.
- **No ally/foe distinction anywhere.** Any skill can target any present combatant, including the caster. Healing an enemy heals it; an area that covers an ally hits
  the ally. Rules that depend on state still apply (revive needs a downed target; heal does nothing to a downed one).
- **Basic actions** (the action bar): **Move, Attack, Defend, Item, Retreat, Context.**
  - Attack opens the unit's attack skills (the skills in its template). Defend is a default action for every class for now.
  - Retreat is the existing Escape, kept as is (instant, always succeeds, no AP), only relabelled.
  - Item (Phase 4) and Context (Phase 6, later) are shown but disabled until then. Context = situation/tile actions, e.g. "Open" when next to a chest (Fire Emblem style).
- **Shield vs Defend:** Shield is an *effect* (a pool of points that absorbs damage before HP). Defend is the *action* every unit has; what it does is data. It starts
  as a small shield (Phase 1); what it finally does is decided in the content discussion after the phases.
- **Statuses count turns (rounds), not beats**, and apply across the whole turn. **Stun is a status** (by turn), not an interruption. **Interrupt belongs to skills**
  (interruption points against a skill's stability), independent of statuses.
- **Progression** (Phase 5): level-ups will give stat points and skill picks; skills also unlock at attribute thresholds and through events. For now everything is
  static (level-ups switched off); the data model and the one resolver function exist so it can be expanded without rework.

## Cross-cutting rules for every phase

- Editor-first: effects, statuses, items, unlock rules and skills are Resources you create and edit in the Inspector; code holds the mechanics and `problems()` checks.
- The server is authoritative; the client only displays and plans. Snapshot fields are additive so older clients keep working during a rollout.
- Randomness: heals, shields and statuses never consume the battle RNG, so existing seeds and tests keep their sequences. Damage keeps its order (hit roll, then crit roll).
- Migration safety: `tests/unit/test_skills.gd` pins every current value; migrated skills must produce identical results. Existing battle tests stay green at every step.
- Each phase ends with: unit tests, docs (`editor-guide.md`, `architecture.md`, `provisional-values.md`), a headless smoke run (`scripts/smoke.sh`), and where the UI changes, a browser check
  (`tests/browser`). Commit and push only when asked.
- AI: enemies keep using damage skills only until a later request; the planner is kept compiling and behaviour-neutral.

---

## Phase 1: effects core

**Goal:** a skill stage is a list of effect resources; damage, heal, shield and interrupt exist; targeting allows anyone including self; Defend and the action bar exist.

Data (new resources in `game/shared/domain/`):
- `SkillEffect` (base, `on: TARGET | CASTER`, `problems()`), with `DamageEffect` (`base`, `can_miss`, `can_crit`, `uses_power`, `interrupt` kept as a separate effect), `HealEffect` (`amount`),
  `ShieldEffect` (`amount`), `InterruptEffect` (`points`).
- `SkillStage.effects: Array[SkillEffect]` replaces `damage` and `interrupt`. `SkillStage.to_dict()` exposes `effects` (and keeps `damage` and `interrupt` sums for the AI and old tests until they are ported).
- `SkillKind.SUPPORT` added (heal, shield, defend). `Targeting.SELF` added (no click; aims at the caster). `ATTACK` no longer implies hostile.
- `defend.tres`: SUPPORT, SELF, 1 AP, one `ShieldEffect` (placeholder amount). Added to every class template.
- One-time `tools/migrate_effects.gd` converts `strike`, `bolt`, `power_strike` (two stages) and `disrupt` (reaction) to effects; the result is committed.

Rules:
- `Combatant.shield` (int). Damage order: crit/side/rear multiplier, minus armor, then shield absorbs, then HP. The shield lasts until the end of the round and does not stack (a new one only replaces a lower one). Provisional.
- Heal: flat, capped at `max_hp`, not applied to a downed combatant (revive stays a separate skill). No hit roll.
- `PlanValidator` and `BeatResolver._stage_problem` drop the team checks; self is a valid target; a missing/eliminated target still skips the stage.
- Resolver: `_attack_stage` becomes "run each effect in order against the target (or the caster for `on = CASTER`)". The hit roll stays inside `DamageEffect`, so non-damage effects skip it.
- Events: `heal`, `shield` (with amounts) in the log; snapshot adds `shield` per unit.

Client:
- Click any unit (also yourself) as a target; Defend queues immediately like Disrupt does now.
- Action bar: Move, Attack (opens the skill list), Defend, Item (disabled), Retreat (the Escape button), Context (disabled). Layout lives in the battle scene so it can be edited in the editor.
- Unit card shows a shield marker; log colours for heal and shield.

Tests: each effect; damage then shield then HP order; shield expiry and non-stacking; heal cap and the downed rule; self-targeting; attacking and healing allies and enemies;
the pinned old values; battles with and without Defend; AI unchanged.

Out of scope: statuses, areas, items.

## Phase 2: statuses (buffs, debuffs, bleed, stun)

**Goal:** timed conditions on combatants that modify stats, tick, or take away actions.

Data:
- `StatusDef` resource (`game/content/statuses/*.tres`): `id`, `display_name`, `hint`, icon (a glyph and a colour; real art later), `duration_turns`, `stacking` (`REFRESH | STACK | IGNORE`, `max_stacks`),
  `stat_mods` (armor, power, accuracy, evasion, dexterity), `tick_effects` (a list of effects applied to the bearer once per turn), and flags `stunned`, `rooted`.
- New effects: `ApplyStatusEffect` (status, optional duration override), `RemoveStatusEffect` (one status or all of a kind: cleanse).
- No statuses ship with the framework; the tests build their own fixtures. Which statuses exist (bleed, brace, stun...) is content, decided afterwards.

Rules:
- `Combatant.statuses: Array[{id, turns_left, stacks}]` and `Combatant.stat(name)` returning the base plus modifiers. Every place that reads armor, power, accuracy, evasion or dexterity goes through it
  (hit chance, damage, AP at the start of a round, movement per AP).
- Duration counts **turns** (rounds). A status's modifiers are active for every beat of each turn it lasts. Tick effects run once per turn, at the start of the turn's resolution. A status applied during
  resolution counts the rest of that turn as its first turn (so a 1-turn status ends when that turn ends), and a status applied in planning (not possible today) would cover the whole coming turn. Provisional.
- `stunned`: the bearer takes no actions while it lasts (its steps are skipped and the plan's AP is forfeited as for any skipped action). It is not an interruption. `rooted`: move steps are skipped.
- Interruption stays a skill mechanic (interruption points vs the skill's stability); statuses neither cause nor prevent it.
- A downed, eliminated or escaped combatant loses all statuses; revive starts clean. Tick damage can down a combatant like any other damage.
- Statuses never consume the RNG (no chance-to-apply in this phase; if wanted later it is a field on `ApplyStatusEffect`).

Client and net: snapshot `statuses` per visible unit; icons with the remaining turns on the unit card and a tooltip; log lines for apply, tick, expire.

Tests (fixture statuses): apply, refresh and stack rules, expiry by turn, stat modifiers in the damage and hit calculations, dexterity and AP, tick damage and healing, stun and root behaviour, cleanse, clearing on down and revive.

## Phase 3: areas of effect

**Goal:** a skill can affect more than one tile.

Data:
- `AreaShape` resource on `SkillDef`: `SINGLE` (default), `RADIUS` (Manhattan, `size`), `LINE` (`length`, from the caster through the aimed tile), `CONE` (`depth`; its width grows by one per step). Plus `requires_los` (the
  effect is blocked by walls between the centre and each tile; default on, provisional).

Rules:
- Tile skills: centre = the aimed tile. Target skills: centre = the target's tile **when the skill executes** (so it follows a moving target).
- Every present combatant on an affected tile is a victim, with no ally/foe distinction and including the caster. Each victim gets its own hit/crit roll, in a fixed order (by combatant id) so results are deterministic.
- Every effect in the stage applies to each victim. `on = CASTER` effects apply once.
- Planning visibility: tile-based skills show the whole area on the board while picking; target-based skills show only the single target, because the area is not known until execution.
- Validator: the centre must be in range and line of sight like any tile or target.

Client: the targeting preview (`targeting_preview.gd`) shades the area for tile skills; log lines summarise ("hits 3 targets"). AI planner: scores an area as the sum over combatants it would cover (it knows sides even though the rules do not).

Tests: each shape against walls and edges, friendly fire and self-hit, follow-the-target behaviour, determinism with a fixed seed, plan-validator limits.

## Phase 4: items

**Goal:** consumables usable in battle, built on the same effects.

Data:
- `ItemDef` resource (`game/content/items/*.tres`): `id`, `display_name`, `hint`, `max_stack`, and an embedded use skill (targeting, range, area, stages with effects, AP cost). No real items ship with the framework;
  the tests and the dev grant script use two throwaway fixtures (a heal and an area damage). The item list is content, decided afterwards.
- Migration `0010_inventory.sql`: `character_items(character_id, item_id, quantity)`. A dev/admin script grants items (no shops, loot or crafting in this plan).
- `balance.json`: `items.battle_slots` (provisional 4): how many item kinds a character brings into a battle.

Rules:
- The API returns the character's loadout (item id and quantity, up to `battle_slots` kinds) in `/internal/auth/session`; the game server puts it on the combatant.
- Planned action `{"item": id, target...}`; the validator checks the loadout count (counting copies already queued) and the item's skill rules. The item is consumed when its skill begins executing, and not consumed if the
  skill is skipped. Cost is the item skill's AP. No cooldown (provisional).
- Consumption is reported in the combat result (`participants[].items_used`) and applied in the same idempotent transaction. A battle that ends without a result (server crash, abandoned) consumes nothing. Enemies have no items.
- The Item slot of the action bar is enabled and lists the loadout with counts.

Tests: validator limits, consumption on use and not on skip, the combat-result transaction (idempotent replay, over-use refused), loadout limit, effects through items (heal, area bomb), API tests for inventory and the session payload.

## Phase 5: progression foundation (static)

**Goal:** the data model and the single resolver for "what stats and skills does this character have", with growth switched off.

Data:
- `UnitTemplate`: `growth` (per-level stat gains), `stat_points_per_level`, `skill_picks_per_level` (all zero for now), `starting_skills` (replaces `skills`; same content) and `unlocks: Array[SkillUnlock]`.
- `SkillUnlock` resource: a skill, `conditions: Array[UnlockCondition]`, and `mode` (`GRANTED` automatically or `PICK` chosen by the player). `UnlockCondition` subclasses: `LevelCondition(min)`, `AttributeCondition(stat, min)`,
  `EventCondition(flag)`.
- `balance.json`: `progression.enabled = false` and an `xp_to_level` table (placeholder).
- Migration `0011_character_build.sql`: `characters.allocated jsonb`, `characters.learned_skills jsonb`, `characters.flags jsonb` (all defaulting to empty).

Rules:
- `CharacterBuild.compose(template, level, allocated, learned, flags)` is the only place that turns a character into stats and a skill list (growth, allocated points, granted unlocks, picked skills). The game server and the Character page both call it.
  With progression disabled and empty state it returns exactly today's stats and skills.
- Awarding XP does not change the level while `progression.enabled` is false.
- API: the session payload includes `level`, `allocated`, `learned_skills`, `flags`; an internal, server-key endpoint sets event flags (the hook for events). No player-facing picking or allocation endpoints in this plan.

Tests: `compose` with synthetic states (growth, thresholds, events, picks), unknown skill ids rejected by `problems()`, the disabled path equals today, API payload and flag endpoint.

## Phase 6: context actions (outline only; needs a design pass first)

Situation/tile actions: map objects (a chest, a lever) list actions with conditions (adjacent to the unit, state of the object); when a unit stands next to one, the Context slot shows it (e.g. "Open"). Resolved in the beat order
like a skill, with results that use the existing systems (grant an item, set an event flag, apply an effect). Needs from the owner: example objects, where they are authored (map editor), whether state is per battle or persistent.
Not part of the phases above; the Context slot stays disabled until then.

---

## Order and checkpoints

1. Phase 1, then review. 2. Phase 2. 3. Phase 3. 4. Phase 4. 5. Phase 5. 6. Phase 6 after its own design pass.
After each phase: tests green, `scripts/smoke.sh` passing, docs updated, and a summary of what changed and what is still provisional. Phases 2 and 3 can swap if wanted; Phase 4 needs Phases 1 and 3.

## Provisional values introduced (to be added to `docs/provisional-values.md` as each lands)

Shield lifetime and stacking; the Defend amount; status duration counted in turns and when a status's first turn starts; stun as a status that skips actions; area line-of-sight rule; `items.battle_slots`; no item cooldown; items consumed only on a committed result; progression table and the disabled flag.
