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


# ---------- skill unlocks (fixture unlocks only; the shipped classes have none) ----------

func _unlock(skill_id: String, mode: int, conds: Array[UnlockCondition]) -> SkillUnlock:
	var u := SkillUnlock.new()
	u.skill = load("res://game/content/skills/%s.tres" % skill_id) as SkillDef
	u.mode = mode as SkillUnlock.Mode
	u.conditions = conds
	return u


func _level(n: int) -> LevelCondition:
	var c := LevelCondition.new()
	c.min_level = n
	return c


func _attr(name: String, n: int) -> AttributeCondition:
	var c := AttributeCondition.new()
	c.attribute = name
	c.min_value = n
	return c


func _event(flag: String) -> EventCondition:
	var c := EventCondition.new()
	c.flag = flag
	return c


## Warrior (starts without bolt): bolt granted at level 3, revive granted by attribute (might 6) and the event, and two picks.
func _caster() -> UnitTemplate:
	var t := _tpl()
	var g: Array[UnlockCondition] = [_level(3)]
	var a: Array[UnlockCondition] = [_attr("might", 6), _event("met_hermit")]
	var p1: Array[UnlockCondition] = [_level(2)]
	var p2: Array[UnlockCondition] = [_level(4)]
	t.unlocks = [_unlock("bolt", SkillUnlock.Mode.GRANTED, g), _unlock("revive", SkillUnlock.Mode.GRANTED, a),
		_unlock("disrupt", SkillUnlock.Mode.PICK, p1), _unlock("power_strike", SkillUnlock.Mode.PICK, p2)]
	var start: Array[SkillDef] = [load("res://game/content/skills/move.tres") as SkillDef, load("res://game/content/skills/strike.tres") as SkillDef]
	t.skills = start
	t.skill_picks_per_level = 1
	return t


func test_disabled_keeps_the_starting_skills_only() -> void:
	var b := CharacterBuild.compose(_caster(), 9, {}, _cfg(false), ["disrupt"], ["met_hermit"])
	assert_eq(b["skills"], ["move", "strike"] as Array[String])
	assert_eq(b["picks_left"], 0)


func test_granted_unlocks_follow_level_attribute_and_event() -> void:
	var cfg := _cfg(true)
	assert_eq(CharacterBuild.compose(_caster(), 1, {}, cfg)["skills"], ["move", "strike"] as Array[String])
	assert_eq(CharacterBuild.compose(_caster(), 3, {}, cfg)["skills"], ["move", "strike", "bolt"] as Array[String])
	var might_only := CharacterBuild.compose(_caster(), 3, {"might": 4}, cfg)  # might 3 + 4 growth... = 3 + 2 + 4
	assert_true(not ("revive" in might_only["skills"]), "attribute alone is not enough: needs the event too")
	var both := CharacterBuild.compose(_caster(), 3, {"might": 1}, cfg, [], ["met_hermit"])
	assert_true("revive" in both["skills"], "might 3 + 2 growth + 1 point = 6 and the flag")
	var event_only := CharacterBuild.compose(_caster(), 3, {}, cfg, [], ["met_hermit"])
	assert_true(not ("revive" in event_only["skills"]), "might 5 is below 6")


func test_picks_cost_one_each_and_must_be_available() -> void:
	var cfg := _cfg(true)
	var l2 := CharacterBuild.compose(_caster(), 2, {}, cfg)
	assert_eq(l2["pickable"], ["disrupt"] as Array[String])
	assert_eq(l2["picks_left"], 1)
	var taken := CharacterBuild.compose(_caster(), 2, {}, cfg, ["disrupt"])
	assert_eq(taken["skills"], ["move", "strike", "disrupt"] as Array[String])
	assert_eq(taken["picks_left"], 0)
	assert_eq(taken["pickable"], [] as Array[String], "learned skills are no longer on offer")
	var greedy := CharacterBuild.compose(_caster(), 2, {}, cfg, ["power_strike", "disrupt", "bolt", 7, "disrupt"])
	assert_eq(greedy["skills"], ["move", "strike", "disrupt"] as Array[String], "not yet available / granted / junk / duplicate: dropped; budget of 1")
	var l4 := CharacterBuild.compose(_caster(), 4, {}, cfg, ["power_strike", "disrupt"])
	assert_eq(l4["learned"], ["power_strike", "disrupt"] as Array[String], "3 picks available, both fit")


func test_battle_uses_the_composed_skills() -> void:
	var cfg := _cfg(true)
	var def := Encounter.definition().duplicate() as EncounterDef
	var tpls: Array[UnitTemplate] = [_caster()]
	tpls.append_array(def.classes.slice(1))
	def.classes = tpls
	var b := Encounter.build(cfg, SkillDb.load_file(), 2, 1, [], def, [{"level": 3, "learned_skills": ["disrupt"], "flags": []}])
	assert_eq(b.state.get_c("pc0").skills, ["move", "strike", "defend", "bolt", "disrupt"] as Array[String])
	assert_true(b.state.get_c("pc1").skills.size() > 0, "a seat with no build keeps the class's skills")


func test_unlock_problems_are_reported() -> void:
	var known := SkillDb.load_file()
	var t := _caster()
	assert_eq(t.problems(known), [] as Array[String])
	t.unlocks[0].conditions = [] as Array[UnlockCondition]
	assert_true(str(t.problems(known)).contains("no conditions"))
	t = _caster()
	t.unlocks[1].conditions = [_event("Bad Flag")] as Array[UnlockCondition]
	assert_true(str(t.problems(known)).contains("flag"))
	t = _caster()
	t.unlocks.append(_unlock("move", SkillUnlock.Mode.GRANTED, [_level(2)] as Array[UnlockCondition]))
	assert_true(str(t.problems(known)).contains("twice"))
	t = _caster()
	t.unlocks = [t.unlocks[0], t.unlocks[1]]
	assert_true(str(t.problems(known)).contains("no Pick unlock"))
