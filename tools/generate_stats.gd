extends SceneTree
## One-time scaffold: turns the stats that used to be typed into encounter.gd into editable resources:
##   game/content/stats/classes/*.tres, game/content/stats/enemies/*.tres, game/content/encounters/prototype.tres
##   scripts/godot.sh --headless --path . --script res://tools/generate_stats.gd
## Never overwrites an existing file (so your edits are safe); `-- --force` regenerates and discards edits.

const ROOT := "res://game/content/"
const CLASSES := [
	{"id": "warrior", "name": "Warrior", "hp": 40, "dex": 8, "power": 3, "armor": 2, "acc": 0, "eva": 0,
		"skills": ["move", "strike", "power_strike", "disrupt"]},
	{"id": "ranger", "name": "Ranger", "hp": 28, "dex": 12, "power": 1, "armor": 0, "acc": 2, "eva": 1,
		"skills": ["move", "strike", "bolt", "disrupt"]},
	{"id": "cleric", "name": "Cleric", "hp": 30, "dex": 10, "power": 1, "armor": 1, "acc": 0, "eva": 0,
		"skills": ["move", "strike", "bolt", "revive"]},
	{"id": "rogue", "name": "Rogue", "hp": 26, "dex": 16, "power": 2, "armor": 0, "acc": 3, "eva": 3,
		"skills": ["move", "strike", "bolt"]},
]
const ENEMIES := [
	{"id": "ghoul", "name": "Ghoul", "hp": 30, "dex": 8, "power": 2, "armor": 1, "acc": 0, "eva": 0,
		"skills": ["move", "strike", "power_strike"]},
	{"id": "cultist", "name": "Cultist", "hp": 20, "dex": 10, "power": 1, "armor": 0, "acc": 1, "eva": 0,
		"skills": ["move", "bolt", "strike"]},
]
## Who stands on E0, E1, E2 (the same enemy can appear several times).
const ENEMY_ORDER := ["ghoul", "ghoul", "cultist"]

var _force := false


func _initialize() -> void:
	_force = "--force" in OS.get_cmdline_user_args()
	var by_id := {}
	for d: Dictionary in CLASSES:
		by_id[d["id"]] = _template("stats/classes/%s.tres" % d["id"], d)
	for d: Dictionary in ENEMIES:
		by_id[d["id"]] = _template("stats/enemies/%s.tres" % d["id"], d)
	var path := ROOT + "encounters/prototype.tres"
	if FileAccess.file_exists(path) and not _force:
		print("kept ", path)
	else:
		var def := EncounterDef.new()
		def.map = load(ROOT + "maps/prototype.tscn")
		for d: Dictionary in CLASSES:
			def.classes.append(by_id[d["id"]])
		for id: String in ENEMY_ORDER:
			def.enemies.append(by_id[id])
		ResourceSaver.save(def, path)
		print("wrote ", path)
	quit()


func _template(rel: String, d: Dictionary) -> UnitTemplate:
	var path := ROOT + rel
	if FileAccess.file_exists(path) and not _force:
		print("kept ", path)
		return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as UnitTemplate
	var t := UnitTemplate.new()
	t.id = d["id"]
	t.display_name = d["name"]
	t.max_hp = d["hp"]
	t.dexterity = d["dex"]
	t.power = d["power"]
	t.armor = d["armor"]
	t.accuracy = d["acc"]
	t.evasion = d["eva"]
	t.skills.assign(d["skills"])
	ResourceSaver.save(t, path)
	t.take_over_path(path)
	print("wrote ", path)
	return t
