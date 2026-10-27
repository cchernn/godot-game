extends TestCase

## The numbers as they were typed into encounter.gd before they became resources.
## Attributes and the battle numbers they give with the provisional config (armor is gear-only, so always 0).
const ORIGINAL := {
	"warrior": {"name": "Warrior", "might": 3, "dex": 4, "agi": 3, "vit": 8, "hp": 38, "power": 3, "acc": 0, "eva": -2, "skills": ["power_strike", "shield_wall"]},
	"hunter": {"name": "Hunter", "might": 2, "dex": 7, "agi": 6, "vit": 4, "hp": 26, "power": 2, "acc": 3, "eva": 1, "skills": ["aimed_shot", "lob_shot"]},
	"mage": {"name": "Mage", "might": 3, "dex": 6, "agi": 4, "vit": 3, "hp": 23, "power": 3, "acc": 2, "eva": -1, "skills": ["fireball", "ice_floor"]},
	"ghoul": {"name": "Ghoul", "might": 2, "dex": 4, "agi": 4, "vit": 5, "hp": 29, "power": 2, "acc": 0, "eva": -1, "skills": ["move", "strike", "power_strike"]},
	"cultist": {"name": "Cultist", "might": 1, "dex": 6, "agi": 5, "vit": 2, "hp": 20, "power": 1, "acc": 2, "eva": 0, "skills": ["move", "bolt", "strike"]},
}


func _skill_ids(t: UnitTemplate) -> Array[String]:
	var ids: Array[String] = []
	for sk in t.skills:
		ids.append(sk.id)
	return ids


func _skill(id: String) -> SkillDef:
	return load("res://game/content/skills/%s.tres" % id) as SkillDef


func _all_templates() -> Array[UnitTemplate]:
	var out: Array[UnitTemplate] = []
	for dir in ["classes", "enemies"]:
		for f in DirAccess.get_files_at("res://game/content/stats/%s" % dir):
			if f.ends_with(".tres"):
				out.append(load("res://game/content/stats/%s/%s" % [dir, f]) as UnitTemplate)
	return out


func test_class_attributes_give_the_expected_battle_numbers() -> void:
	var seen := {}
	for t in _all_templates():
		var want: Dictionary = ORIGINAL[t.id]
		seen[t.id] = true
		assert_eq(t.display_name, want["name"], t.id)
		assert_eq([t.might, t.dexterity, t.agility, t.vitality], [want["might"], want["dex"], want["agi"], want["vit"]], "%s attributes" % t.id)
		var c := t.make_combatant("x", Enums.Team.PLAYERS, Enums.Facing.EAST, Vector2i.ZERO, GameConfig.load_file())
		assert_eq(c.max_hp, want["hp"], "%s hp" % t.id)
		assert_eq(c.power, want["power"], "%s power" % t.id)
		assert_eq(c.armor, 0, "%s armor (gear only)" % t.id)
		assert_eq(c.accuracy, want["acc"], "%s accuracy" % t.id)
		assert_eq(c.evasion, want["eva"], "%s evasion" % t.id)
		assert_eq([c.dexterity, c.agility], [want["dex"], want["agi"]], "%s dex/agi" % t.id)
		assert_eq(_skill_ids(t), want["skills"] as Array[String], "%s skills" % t.id)
	assert_eq(seen.size(), ORIGINAL.size(), "every original unit has a resource")


func test_every_template_and_the_encounter_are_valid() -> void:
	var known := SkillDb.load_file()
	for t in _all_templates():
		assert_eq(t.problems(known), [] as Array[String], t.id)
	assert_eq(Encounter.definition().problems(known), [] as Array[String])


func test_encounter_definition_lists_the_expected_cast() -> void:
	var def := Encounter.definition()
	var classes: Array[String] = []
	for t in def.classes:
		classes.append(t.id)
	var enemies: Array[String] = []
	for t in def.enemies:
		enemies.append(t.id)
	assert_eq(classes, ["warrior", "hunter", "mage"] as Array[String])
	assert_eq(enemies, ["ghoul", "ghoul", "cultist"] as Array[String])
	assert_eq(def.map_id(), "prototype")
	assert_eq(def.max_players(), 4)
	assert_eq(Encounter.max_players(), 4)


func test_encounters_are_looked_up_by_a_plain_id_only() -> void:
	assert_true(Encounter.load_definition("prototype") != null)
	for bad in ["", "nope", "../prototype", "prototype.tres", "res://game/content/encounters/prototype", "Prototype", "a b"]:
		assert_true(Encounter.load_definition(bad) == null, "'%s' must not load" % bad)


## The API caps a party by the activity's max_players and the battle seats players by the encounter's classes;
## the two must agree, or a party could be larger than its battle.
func test_every_activity_names_a_real_encounter_with_enough_seats() -> void:
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://services/api/templates/prototype@1.json"))
	assert_true(raw is Dictionary, "template readable")
	for a: Dictionary in (raw as Dictionary)["activities"]:
		var def := Encounter.load_definition(str(a.get("encounter", "")))
		assert_true(def != null, "%s: encounter '%s' exists" % [a["id"], a.get("encounter", "")])
		if def != null:
			assert_true(int(a["max_players"]) <= def.max_players(), "%s: max_players fits the encounter" % a["id"])


func test_class_ids_match_the_account_screen_and_every_unit_has_a_look() -> void:
	var def := Encounter.definition()
	var ids: Array[String] = []
	for t in def.classes:
		ids.append(t.id)
	assert_eq(ids, CharacterCreator.CLASSES, "class list shared with the creator screen and the API rules")
	var visuals := load("res://game/content/units/unit_visuals.tres") as UnitVisuals
	for t in _all_templates():
		assert_true(visuals.scenes.has(t.id), "%s has an entry in unit_visuals.tres" % t.id)


func test_editing_a_template_changes_the_battle() -> void:
	var def := Encounter.definition().duplicate() as EncounterDef
	var tough := def.classes[0].duplicate() as UnitTemplate
	tough.vitality = 9
	tough.might = 7
	var few: Array[SkillDef] = [_skill("move"), _skill("strike")]
	tough.skills = few
	var swapped: Array[UnitTemplate] = [tough]
	swapped.append_array(def.classes.slice(1))
	def.classes = swapped
	var b := Encounter.build(GameConfig.load_file(), SkillDb.load_file(), 2, 1, [], def)
	var c := b.state.get_c("pc0")
	assert_eq(c.max_hp, 41)
	assert_eq(c.hp, 41)
	assert_eq(c.power, 7)
	assert_eq(c.skills, ["move", "strike", "defend"] as Array[String], "the basics are added to the seat's own skills, once")
	assert_eq(b.state.get_c("pc1").max_hp, 26, "other seats are untouched")
	var original := Encounter.build(GameConfig.load_file(), SkillDb.load_file(), 1, 1)
	assert_eq(original.state.get_c("pc0").max_hp, 38, "the shared resource itself was not changed")


func test_a_character_class_picks_its_template_and_unknown_ones_fall_back_to_the_seat() -> void:
	var cfg := GameConfig.load_file()
	var skills := SkillDb.load_file()
	var b := Encounter.build(cfg, skills, 3, 1, ["mage", "", "paladin"])
	assert_eq(b.state.get_c("pc0").visual, "mage")
	assert_eq(b.state.get_c("pc0").cell, Vector2i(0, 2), "seats keep their own spawn tile")
	assert_eq(b.state.get_c("pc1").visual, "hunter", "no class: the seat's default")
	assert_eq(b.state.get_c("pc2").visual, "mage", "unknown class: the seat's default")
	assert_eq(b.state.get_c("e2").visual, "cultist")


func test_problems_are_reported_with_the_unit_named() -> void:
	var known := SkillDb.load_file()
	var t := UnitTemplate.new()
	t.id = "Bad Id"
	var issues := t.problems(known)
	assert_true(issues.size() >= 2, str(issues))
	t.id = "archer"
	t.display_name = "Archer"
	var ghost := SkillDef.new()
	ghost.id = "phantom"
	var mixed: Array[SkillDef] = [_skill("move"), ghost]
	t.skills = mixed
	issues = t.problems(known)
	assert_eq(issues.size(), 1)
	assert_true(issues[0].contains("phantom") and issues[0].contains("archer"), issues[0])
	var def := EncounterDef.new()
	assert_true(def.problems(known).size() >= 3, "no map, no classes, no enemies")
	var twice := Encounter.definition().duplicate() as EncounterDef
	var doubled: Array[UnitTemplate] = [twice.classes[0], twice.classes[0]]
	twice.classes = doubled
	assert_true(str(twice.problems(known)).contains("twice"))


func test_every_player_seat_gets_the_basic_actions_and_enemies_do_not() -> void:
	var skills := SkillDb.load_file()
	assert_eq(skills.basic_ids, ["move", "strike", "defend"] as Array[String])
	var b := Encounter.build(GameConfig.load_file(), skills, 4, 1)
	for i in 4:
		var have := b.state.get_c("pc%d" % i).skills
		for basic in skills.basic_ids:
			assert_true(basic in have, "pc%d has %s" % [i, basic])
	assert_eq(b.state.get_c("pc0").skills, ["move", "strike", "defend", "power_strike", "shield_wall"] as Array[String])
	assert_true(not "defend" in b.state.get_c("e0").skills, "enemies list their own actions")
	assert_eq(SkillSet.new().problems(), [] as Array[String])
