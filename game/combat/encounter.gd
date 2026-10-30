class_name Encounter
extends RefCounted
## Builds the prototype battle from editor-made content: the EncounterDef resource says which map, which
## classes and which enemies (game/content/encounters/prototype.tres), each UnitTemplate holds the stats
## (game/content/stats), and the map scene holds the tiles and spawn markers. All numbers are provisional.

const DEFINITION := "res://game/content/encounters/prototype.tres"


static func definition() -> EncounterDef:
	return load(DEFINITION) as EncounterDef


## An encounter by id (a file in game/content/encounters), or null if the id is malformed or has no such file.
## Ids come from the API's activity definitions; this refuses anything that is not a plain name.
static func load_definition(id: String) -> EncounterDef:
	var plain := id != ""
	for ch in id:
		if not (ch in "abcdefghijklmnopqrstuvwxyz0123456789_"):
			plain = false
	var path := "res://game/content/encounters/%s.tres" % id
	if not plain or not ResourceLoader.exists(path):
		return null
	return load(path) as EncounterDef


static func max_players() -> int:
	return definition().max_players()


## Player combatants are named "pc0".."pcN" by seat, enemies "e0".. by spot. `classes` (optional, lower-case
## class ids) picks each seat's template; seats keep their own spawn tile. `builds` (optional, one per seat:
## {flags}) feeds CharacterBuild. `def` overrides the default
## encounter (used by tests and the design preview).
static func build(cfg: GameConfig, skills: SkillDb, player_count: int, seed: int, classes: Array = [],
		def: EncounterDef = null, builds: Array = []) -> Battle:
	if def == null:
		def = definition()
	var problems := def.problems(skills)
	for p in problems:
		push_error("Encounter content: %s" % p)
	assert(problems.is_empty(), "; ".join(problems))
	var map := MapDef.load_scene(def.map.resource_path)
	assert(map.error == "", map.error)
	var battle := Battle.new(cfg, skills, map.battlefield, seed)
	battle.map_id = def.map_id()
	for o: Dictionary in map.objects:
		var issues := (o["def"] as ContextObjectDef).problems()
		for p in issues:
			push_error("Map object %s: %s" % [o["id"], p])
		assert(issues.is_empty(), "; ".join(issues))
		battle.add_object(o["def"], o["id"], o["cell"])
	for i in mini(player_count, def.max_players()):
		var tpl: UnitTemplate = def.classes[i % def.classes.size()]
		if i < classes.size():
			var chosen := def.class_by_id(str(classes[i]))
			if chosen != null:
				tpl = chosen
		var made: Dictionary = {}
		if i < builds.size() and builds[i] is Dictionary:
			var b := builds[i] as Dictionary
			made = CharacterBuild.compose(tpl, cfg, _list(b.get("flags", [])), _list(b["gear"]) if b.has("gear") else null)
		if made.is_empty():
			made = CharacterBuild.compose(tpl, cfg)
		var basics := skills.basic_ids.duplicate()
		var armed := (made["skills"] as Array).any(func(id: String) -> bool:
			var sk := skills.get_skill(id)
			return sk != null and sk.slot() == Enums.ActionSlot.ATTACK)
		if not armed and skills.unarmed_id != "":
			basics.append(skills.unarmed_id)
		battle.add_combatant(tpl.make_combatant("pc%d" % i, Enums.Team.PLAYERS, Enums.Facing.EAST,
			_spawn(map.player_spawns, i, "player seat P%d" % i), cfg, made, basics))
	for i in def.enemies.size():
		battle.add_combatant(def.enemies[i].make_combatant("e%d" % i, Enums.Team.ENEMIES, Enums.Facing.WEST,
			_spawn(map.enemy_spawns, i, "enemy spot E%d" % i), cfg))
	for tr in def.triggers: # who starts asleep or off the map, then what sets them going
		var ids: Array[String] = []
		for i in tr.targets:
			var who := battle.state.get_c("e%d" % i)
			ids.append("e%d" % i)
			if who == null:
				continue
			if tr.effect == EncounterTrigger.Effect.WAKE and not who.in_reserve:
				who.dormant = true
			elif tr.effect == EncounterTrigger.Effect.APPEAR:
				who.in_reserve = true
				who.dormant = false
		battle.triggers.append({"when": tr.when, "round": tr.at_round, "watch": "e%d" % tr.enemy, "effect": tr.effect, "targets": ids,
			"message": tr.message, "done": false})
	battle.start()
	return battle


static func _list(v: Variant) -> Array:
	return v as Array if v is Array else []


static func _spawn(spawns: Array[Vector2i], index: int, what: String) -> Vector2i:
	if index < spawns.size():
		return spawns[index]
	push_error("Map has no %s; falling back to the first column" % what)
	return Vector2i(0, index)
