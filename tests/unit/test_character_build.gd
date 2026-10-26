extends TestCase


func _cfg(enabled: bool) -> GameConfig:
	var cfg := GameConfig.load_file()
	cfg.data["progression"]["enabled"] = enabled
	return cfg


## A template with growth and point values (test fixture only; the shipped classes have none).
func _tpl() -> UnitTemplate:
	var t := (load("res://game/content/stats/classes/warrior.tres") as UnitTemplate).duplicate() as UnitTemplate
	t.growth = Attributes.new()
	t.growth.vitality = 2
	t.growth.might = 1
	t.point_value = Attributes.new()
	t.point_value.might = 1
	t.point_value.agility = 2
	t.stat_points_per_level = 3
	t.max_points_per_stat = 4
	return t


func test_disabled_ignores_level_and_points() -> void:
	var t := _tpl()
	var b := CharacterBuild.compose(t, 9, {"might": 5}, _cfg(false))
	assert_eq(b["attributes"], t.base_attributes().to_dict())
	assert_eq(b["points_left"], 0)
	assert_eq(b["stats"]["max_hp"], 40)
	assert_eq(CharacterBuild.level_for_xp(_cfg(false), 99999), 1)


func test_growth_by_level() -> void:
	var b := CharacterBuild.compose(_tpl(), 5, {}, _cfg(true))
	assert_eq(b["attributes"]["vitality"], 15 + 2 * 4)
	assert_eq(b["attributes"]["might"], 3 + 4)
	assert_eq(b["points_left"], 12)
	assert_eq(b["stats"]["max_hp"], 10 + 23 * 2)
	assert_eq(b["stats"]["power"], 7)


func test_allocated_points_use_point_value() -> void:
	var b := CharacterBuild.compose(_tpl(), 3, {"might": 2, "agility": 3}, _cfg(true))
	assert_eq(b["attributes"]["might"], 3 + 2 + 2)
	assert_eq(b["attributes"]["agility"], 8 + 3 * 2)
	assert_eq(b["points_left"], 6 - 5 + 0)
	assert_eq(b["allocated"], {"might": 2, "agility": 3})


func test_bad_allocations_are_dropped_or_trimmed() -> void:
	var t := _tpl()
	var b := CharacterBuild.compose(t, 20, {"might": 99, "dexterity": 5, "vitality": 3, "agility": -4, "luck": 7, "x": "y"}, _cfg(true))
	assert_eq(b["allocated"], {"might": 4}, "capped per attribute; no point value / negative / unknown / junk dropped")
	var broke := CharacterBuild.compose(t, 2, {"might": 4, "agility": 4}, _cfg(true))
	assert_eq(broke["allocated"], {"might": 3}, "trimmed to the 3-point budget, in attribute order")
	assert_eq(broke["points_left"], 0)
	var low := CharacterBuild.compose(t, -5, {"might": 2}, _cfg(true))
	assert_eq(low["allocated"], {} as Dictionary, "level below 1 counts as 1: no points")


func test_xp_to_level() -> void:
	var cfg := _cfg(true)
	assert_eq(CharacterBuild.level_for_xp(cfg, 0), 1)
	assert_eq(CharacterBuild.level_for_xp(cfg, 100), 2)
	assert_eq(CharacterBuild.level_for_xp(cfg, 260), 3)
	assert_eq(CharacterBuild.level_for_xp(cfg, 99999), 6)


func test_battle_uses_the_build_per_seat() -> void:
	var cfg := _cfg(true)
	var def := Encounter.definition().duplicate() as EncounterDef
	var tpls: Array[UnitTemplate] = [_tpl()]
	tpls.append_array(def.classes.slice(1))
	def.classes = tpls
	var b := Encounter.build(cfg, SkillDb.load_file(), 2, 1, [], def, [{"level": 3, "allocated": {"agility": 2}}, {}])
	var c := b.state.get_c("pc0")
	assert_eq(c.agility, 8 + 4)
	assert_eq(c.power, 3 + 2)
	assert_eq(b.state.get_c("pc1").max_hp, 28, "a seat with no build is the plain class")


func test_template_problems_for_progression_fields() -> void:
	var known := SkillDb.load_file()
	var t := _tpl()
	assert_eq(t.problems(known), [] as Array[String])
	t.growth.might = -1
	assert_true(str(t.problems(known)).contains("negative"))
	t.growth.might = 0
	t.point_value = null
	assert_true(str(t.problems(known)).contains("point value"))
