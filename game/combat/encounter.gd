class_name Encounter
extends RefCounted
## The prototype encounter: map, player slots and enemy group. All stats are provisional.

## The layout lives in an editor-painted scene: game/content/maps/<MAP_ID>.tscn (tiles, player seats P0..,
## enemy spots E0..). Stats below are provisional and stay in code until they move to Resources.
const MAP_ID := "prototype"
const MAP_DIR := "res://game/content/maps/"

const PLAYER_SLOTS: Array[Dictionary] = [
	{"name": "Warrior", "hp": 40, "dex": 8, "power": 3, "armor": 2, "acc": 0, "eva": 0,
		"skills": ["move", "strike", "power_strike", "disrupt"]},
	{"name": "Ranger", "hp": 28, "dex": 12, "power": 1, "armor": 0, "acc": 2, "eva": 1,
		"skills": ["move", "strike", "bolt", "disrupt"]},
	{"name": "Cleric", "hp": 30, "dex": 10, "power": 1, "armor": 1, "acc": 0, "eva": 0,
		"skills": ["move", "strike", "bolt", "revive"]},
	{"name": "Rogue", "hp": 26, "dex": 16, "power": 2, "armor": 0, "acc": 3, "eva": 3,
		"skills": ["move", "strike", "bolt"]},
]

const ENEMIES: Array[Dictionary] = [
	{"name": "Ghoul", "hp": 30, "dex": 8, "power": 2, "armor": 1, "acc": 0, "eva": 0,
		"skills": ["move", "strike", "power_strike"]},
	{"name": "Ghoul", "hp": 30, "dex": 8, "power": 2, "armor": 1, "acc": 0, "eva": 0,
		"skills": ["move", "strike", "power_strike"]},
	{"name": "Cultist", "hp": 20, "dex": 10, "power": 1, "armor": 0, "acc": 1, "eva": 0,
		"skills": ["move", "bolt", "strike"]},
]


## Player combatants are named "pc0".."pcN" by seat. `classes` (optional, lower-case class names)
## picks each seat's template; seats keep their own spawn tile.
static func build(cfg: GameConfig, skills: SkillDb, player_count: int, seed: int, classes: Array = []) -> Battle:
	var map := MapDef.load_scene(MAP_DIR + MAP_ID + ".tscn")
	assert(map.error == "", map.error)
	var battle := Battle.new(cfg, skills, map.battlefield, seed)
	battle.map_id = MAP_ID
	for i in mini(player_count, PLAYER_SLOTS.size()):
		var tpl: Dictionary = PLAYER_SLOTS[i]
		if i < classes.size():
			for cand in PLAYER_SLOTS:
				if (cand["name"] as String).to_lower() == classes[i]:
					tpl = cand
		var c := _make("pc%d" % i, tpl, Enums.Team.PLAYERS, Enums.Facing.EAST)
		c.cell = _spawn(map.player_spawns, i, "player seat P%d" % i)
		battle.add_combatant(c)
	for i in ENEMIES.size():
		var e := _make("e%d" % i, ENEMIES[i], Enums.Team.ENEMIES, Enums.Facing.WEST)
		e.cell = _spawn(map.enemy_spawns, i, "enemy spot E%d" % i)
		battle.add_combatant(e)
	battle.start()
	return battle


static func _spawn(spawns: Array[Vector2i], index: int, what: String) -> Vector2i:
	if index < spawns.size():
		return spawns[index]
	push_error("Map has no %s; falling back to the first column" % what)
	return Vector2i(0, index)


static func _make(id: String, d: Dictionary, team: int, facing: int) -> Combatant:
	var c := Combatant.new()
	c.id = id
	c.display_name = d["name"]
	c.visual = (d["name"] as String).to_lower()
	c.team = team
	c.facing = facing
	c.max_hp = d["hp"]
	c.hp = c.max_hp
	c.dexterity = d["dex"]
	c.power = d["power"]
	c.armor = d["armor"]
	c.accuracy = d["acc"]
	c.evasion = d["eva"]
	c.skills.assign(d["skills"])
	return c
