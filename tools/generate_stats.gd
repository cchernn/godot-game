extends SceneTree
## One-time scaffold: turns the stats that used to be typed into encounter.gd into editable resources:
##   game/content/stats/classes/*.tres, game/content/stats/enemies/*.tres, game/content/encounters/prototype.tres
##   scripts/godot.sh --headless --path . --script res://tools/generate_stats.gd
## Never overwrites an existing file (so your edits are safe); `-- --force` regenerates and discards edits.

const ROOT := "res://game/content/"
const CLASSES := [
	{"id": "warrior", "name": "Warrior", "might": 3, "dex": 4, "agi": 3, "vit": 8,
		"skills": ["power_strike", "shield_wall"]},
	{"id": "hunter", "name": "Hunter", "might": 2, "dex": 7, "agi": 6, "vit": 4,
		"skills": ["lob_shot", "maim_shot"]},
	{"id": "mage", "name": "Mage", "might": 3, "dex": 6, "agi": 4, "vit": 3,
		"skills": ["fireball", "ice_floor"]},
]
const ENEMIES := [
	{"id": "ghoul", "name": "Ghoul", "might": 2, "dex": 4, "agi": 4, "vit": 5,
		"skills": ["move", "strike", "power_strike"]},
	{"id": "cultist", "name": "Cultist", "might": 1, "dex": 6, "agi": 5, "vit": 2,
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
	t.might = d["might"]
	t.dexterity = d["dex"]
	t.agility = d["agi"]
	t.vitality = d["vit"]
	for sid: String in d["skills"]:
		t.skills.append(load("res://game/content/skills/%s.tres" % sid) as SkillDef)
	ResourceSaver.save(t, path)
	t.take_over_path(path)
	print("wrote ", path)
	return t
