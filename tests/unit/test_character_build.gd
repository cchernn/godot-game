extends TestCase
## Attributes and skills from the class plus the event flags a character holds. There are no levels or points: only grants and unlocks.


## The warrior with fixture grants (the shipped classes have none yet).
func _tpl() -> UnitTemplate:
	var t := (load("res://game/content/stats/classes/warrior.tres") as UnitTemplate).duplicate() as UnitTemplate
	t.attribute_grants = [_grant("trained_might", {"might": 2}), _grant("toughened", {"vitality": 1, "agility": 1})] as Array[AttributeGrant]
	return t


func _grant(flag: String, bonus: Dictionary) -> AttributeGrant:
	var g := AttributeGrant.new()
	g.flag = flag
	g.bonus = Attributes.new()
	for k: String in bonus:
		g.bonus.set(k, bonus[k])
	return g


func test_no_flags_means_exactly_the_class_attributes() -> void:
	var cfg := GameConfig.load_file()
	var t := _tpl()
	var b := CharacterBuild.compose(t, cfg)
	assert_eq(b["attributes"], t.base_attributes().to_dict())
	assert_eq(b["stats"]["max_hp"], 38)
	assert_eq(b["stats"]["power"], 3)


func test_a_flag_adds_its_grant_and_only_its_own() -> void:
	var cfg := GameConfig.load_file()
	var b := CharacterBuild.compose(_tpl(), cfg, ["trained_might", "something_else", 7])
	assert_eq(b["attributes"]["might"], 5)
	assert_eq(b["attributes"]["vitality"], 8, "the other grant's flag is not held")
	assert_eq(b["stats"]["power"], 5)
	var both := CharacterBuild.compose(_tpl(), cfg, ["trained_might", "toughened"])
	assert_eq([both["attributes"]["vitality"], both["attributes"]["agility"]], [9, 4])
	assert_eq(both["stats"]["max_hp"], 14 + 9 * 3)


func test_attributes_stop_at_the_cap() -> void:
	var cfg := GameConfig.load_file()
	var t := _tpl()
	t.attribute_grants = [_grant("huge", {"might": 50, "vitality": 50})] as Array[AttributeGrant]
	var b := CharacterBuild.compose(t, cfg, ["huge"])
	assert_eq(b["attributes"]["might"], 10)
	assert_eq(b["attributes"]["vitality"], 10)
	assert_eq(b["attributes"]["dexterity"], 4, "untouched")


func test_the_shipped_classes_start_within_the_cap() -> void:
	var cap: int = GameConfig.load_file().get_value("stats", "attribute_cap")
	for id in ["warrior", "hunter", "mage"]:
		var t := load("res://game/content/stats/classes/%s.tres" % id) as UnitTemplate
		for a in Attributes.NAMES:
			assert_true(t.base_attributes().get_attr(a) <= cap, "%s %s" % [id, a])


func test_battle_uses_the_build_per_seat() -> void:
	var cfg := GameConfig.load_file()
	var def := Encounter.definition().duplicate() as EncounterDef
	var tpls: Array[UnitTemplate] = [_tpl()]
	tpls.append_array(def.classes.slice(1))
	def.classes = tpls
	var b := Encounter.build(cfg, SkillDb.load_file(), 2, 1, [], def, [{"flags": ["toughened", "trained_might"]}, {}])
	var c := b.state.get_c("pc0")
	assert_eq(c.agility, 4)
	assert_eq(c.power, 5)
	assert_eq(c.max_hp, 14 + 9 * 3)
	assert_eq(b.state.get_c("pc1").max_hp, 26, "a seat with no build is the plain class")


func test_grant_problems_are_reported() -> void:
	var known := SkillDb.load_file()
	var t := _tpl()
	assert_eq(t.problems(known), [] as Array[String])
	t.attribute_grants = [_grant("Bad Flag", {"might": 1})] as Array[AttributeGrant]
	assert_true(str(t.problems(known)).contains("flag"))
	t.attribute_grants = [_grant("ok", {})] as Array[AttributeGrant]
	assert_true(str(t.problems(known)).contains("gives nothing"))
	t.attribute_grants = [_grant("ok", {"might": -1})] as Array[AttributeGrant]
	assert_true(str(t.problems(known)).contains("negative"))


# ---------- skill unlocks (fixture unlocks only; the shipped classes have none) ----------

func _unlock(skill_id: String, conds: Array[UnlockCondition]) -> SkillUnlock:
	var u := SkillUnlock.new()
	u.skill = load("res://game/content/skills/%s.tres" % skill_id) as SkillDef
	u.conditions = conds
	return u


func _attr(name: String, n: int) -> AttributeCondition:
	var c := AttributeCondition.new()
	c.attribute = name
	c.min_value = n
	return c


func _event(flag: String) -> EventCondition:
	var c := EventCondition.new()
	c.flag = flag
	return c


## Warrior (starts without bolt): bolt unlocked by an event flag, revive by Might 5 together with another flag.
func _caster() -> UnitTemplate:
	var t := _tpl()
	var g: Array[UnlockCondition] = [_event("met_hermit")]
	var a: Array[UnlockCondition] = [_attr("might", 5), _event("blessed")]
	t.unlocks = [_unlock("bolt", g), _unlock("revive", a)]
	var start: Array[SkillDef] = [load("res://game/content/skills/move.tres") as SkillDef, load("res://game/content/skills/strike.tres") as SkillDef]
	t.skills = start
	return t


func test_unlocks_follow_events_and_attributes() -> void:
	var cfg := GameConfig.load_file()
	assert_eq(CharacterBuild.compose(_caster(), cfg)["skills"], ["move", "strike"] as Array[String])
	assert_eq(CharacterBuild.compose(_caster(), cfg, ["met_hermit"])["skills"], ["move", "strike", "bolt"] as Array[String])
	var blessed_only := CharacterBuild.compose(_caster(), cfg, ["blessed"])
	assert_true(not ("revive" in blessed_only["skills"]), "Might 3 is below 5")
	var both := CharacterBuild.compose(_caster(), cfg, ["blessed", "trained_might"])
	assert_true("revive" in both["skills"], "the grant lifts Might to 5, and the flag is held")


func test_battle_uses_the_composed_skills() -> void:
	var cfg := GameConfig.load_file()
	var def := Encounter.definition().duplicate() as EncounterDef
	var tpls: Array[UnitTemplate] = [_caster()]
	tpls.append_array(def.classes.slice(1))
	def.classes = tpls
	var b := Encounter.build(cfg, SkillDb.load_file(), 2, 1, [], def, [{"flags": ["met_hermit"]}])
	assert_eq(b.state.get_c("pc0").skills, ["move", "strike", "defend", "bolt"] as Array[String])
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
	t.unlocks.append(_unlock("move", [_event("x")] as Array[UnlockCondition]))
	assert_true(str(t.problems(known)).contains("twice"))
