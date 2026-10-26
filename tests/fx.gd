class_name Fx
extends RefCounted
## Test fixtures: small hand-built battles with deterministic combat (always hit, no crits, no AI).

const OPEN: Array[String] = ["........", "........", "........", "........"]


static func battle(rows: Array, units: Array, seed: int = 1) -> Battle:
	var cfg := GameConfig.load_file()
	cfg.data["combat"]["base_hit_chance"] = 1.0
	cfg.data["combat"]["crit_chance"] = 0.0
	var b := Battle.new(cfg, SkillDb.load_file(), Battlefield.from_rows(rows), seed)
	b.ai_enabled = false
	for u: Dictionary in units:
		var c := Combatant.new()
		c.id = u["id"]
		c.display_name = u["id"]
		c.team = u.get("team", Enums.Team.PLAYERS)
		c.cell = u["cell"]
		c.facing = u.get("facing", Enums.Facing.EAST)
		c.max_hp = u.get("hp", 20)
		c.hp = u.get("cur_hp", c.max_hp)
		c.dexterity = u.get("dex", 8)
		c.agility = u.get("agi", 8)
		c.power = u.get("power", 0)
		c.armor = u.get("armor", 0)
		c.skills.assign(u.get("skills", ["move", "strike", "power_strike", "bolt", "disrupt", "revive", "defend"]))
		b.add_combatant(c)
	b.start()
	return b


static func player(id: String, cell: Vector2i, extra: Dictionary = {}) -> Dictionary:
	var d := {"id": id, "cell": cell, "team": Enums.Team.PLAYERS}
	d.merge(extra, true)
	return d


static func enemy(id: String, cell: Vector2i, extra: Dictionary = {}) -> Dictionary:
	var d := {"id": id, "cell": cell, "team": Enums.Team.ENEMIES, "facing": Enums.Facing.WEST}
	d.merge(extra, true)
	return d


static func move(path: Array, facing: int = -1) -> Dictionary:
	var d := {"skill": "move", "path": path}
	if facing >= 0:
		d["facing"] = facing
	return d


static func act(skill: String, target: String) -> Dictionary:
	return {"skill": skill, "target": target}


## Submit and ready a plan; returns the submit result.
static func plan(b: Battle, id: String, actions: Array) -> Dictionary:
	var r := b.submit_plan(id, actions)
	if r["ok"]:
		b.set_ready(id, true)
	return r


## Resolves the current round to its end (or until the encounter finishes).
static func run_round(b: Battle) -> void:
	b.begin_resolution()
	var guard := 0
	while b.state.phase == Enums.RoundPhase.RESOLVING and guard < 100:
		b.resolve_next_beat()
		guard += 1


static func texts(b: Battle) -> Array[String]:
	var out: Array[String] = []
	for e in b.events:
		out.append(e["text"])
	return out


static func has_event(b: Battle, type: String) -> bool:
	for e in b.events:
		if e["type"] == type:
			return true
	return false


## Runs `n` beats of the current resolution (call begin_resolution first).
static func run_beats(b: Battle, n: int) -> void:
	for i in n:
		b.resolve_next_beat()
