class_name Encounter
extends RefCounted
## Builds the prototype battle from editor-made content: the EncounterDef resource says which map, which
## classes and which enemies (game/content/encounters/prototype.tres), each UnitTemplate holds the stats
## (game/content/stats), and the map scene holds the tiles and spawn markers. All numbers are provisional.

const DEFINITION := "res://game/content/encounters/prototype.tres"


static func definition() -> EncounterDef:
	return load(DEFINITION) as EncounterDef


static func max_players() -> int:
	return definition().max_players()


## Player combatants are named "pc0".."pcN" by seat, enemies "e0".. by spot. `classes` (optional, lower-case
## class ids) picks each seat's template; seats keep their own spawn tile. `def` overrides the default
## encounter (used by tests and the design preview).
static func build(cfg: GameConfig, skills: SkillDb, player_count: int, seed: int, classes: Array = [],
		def: EncounterDef = null) -> Battle:
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
	for i in mini(player_count, def.max_players()):
		var tpl: UnitTemplate = def.classes[i]
		if i < classes.size():
			var chosen := def.class_by_id(str(classes[i]))
			if chosen != null:
				tpl = chosen
		battle.add_combatant(tpl.make_combatant("pc%d" % i, Enums.Team.PLAYERS, Enums.Facing.EAST,
			_spawn(map.player_spawns, i, "player seat P%d" % i)))
	for i in def.enemies.size():
		battle.add_combatant(def.enemies[i].make_combatant("e%d" % i, Enums.Team.ENEMIES, Enums.Facing.WEST,
			_spawn(map.enemy_spawns, i, "enemy spot E%d" % i)))
	battle.start()
	return battle


static func _spawn(spawns: Array[Vector2i], index: int, what: String) -> Vector2i:
	if index < spawns.size():
		return spawns[index]
	push_error("Map has no %s; falling back to the first column" % what)
	return Vector2i(0, index)
