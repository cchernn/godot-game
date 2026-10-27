extends TestCase
## Gear: the starting loadouts, armor, and the Attack list coming from weapons.


func _class(id: String) -> UnitTemplate:
	return load("res://game/content/stats/classes/%s.tres" % id) as UnitTemplate


func test_the_classes_start_with_the_agreed_gear() -> void:
	var ids := func(t: UnitTemplate) -> Array[String]:
		var out: Array[String] = []
		for g in t.gear:
			out.append(g.id)
		return out
	assert_eq(ids.call(_class("warrior")), ["iron_longsword", "wooden_shield", "iron_chainmail"] as Array[String])
	assert_eq(ids.call(_class("hunter")), ["bow", "iron_dagger", "leather_armor"] as Array[String])
	assert_eq(ids.call(_class("mage")), ["wooden_staff", "garb"] as Array[String])


func test_armor_adds_up_over_the_gear() -> void:
	var cfg := GameConfig.load_file()
	assert_eq(CharacterBuild.compose(_class("warrior"), cfg)["stats"]["armor"], 4, "chainmail 3 + shield 1")
	assert_eq(CharacterBuild.compose(_class("hunter"), cfg)["stats"]["armor"], 1, "leather")
	assert_eq(CharacterBuild.compose(_class("mage"), cfg)["stats"]["armor"], 0, "garb")


func test_the_attack_list_comes_from_the_weapons() -> void:
	var skills := SkillDb.load_file()
	var b := Encounter.build(GameConfig.load_file(), skills, 3, 1)
	var attacks := func(id: String) -> Array[String]:
		var out: Array[String] = []
		for sid in b.state.get_c(id).skills:
			if skills.get_skill(sid).slot() == Enums.ActionSlot.ATTACK:
				out.append(sid)
		return out
	assert_eq(attacks.call("pc0"), ["slash"] as Array[String], "the shield grants no attack")
	assert_eq(attacks.call("pc1"), ["shoot", "stab"] as Array[String])
	assert_eq(attacks.call("pc2"), ["bash"] as Array[String])
	assert_eq(b.state.get_c("pc0").armor, 4)
	assert_eq(b.state.get_c("pc2").armor, 0)


func test_without_a_weapon_you_fall_back_on_the_plain_attack() -> void:
	var def := Encounter.definition().duplicate() as EncounterDef
	var bare := _class("warrior").duplicate() as UnitTemplate
	bare.gear = [] as Array[GearDef]
	var classes: Array[UnitTemplate] = [bare]
	classes.append_array(def.classes.slice(1))
	def.classes = classes
	var b := Encounter.build(GameConfig.load_file(), SkillDb.load_file(), 2, 1, [], def)
	assert_true("strike" in b.state.get_c("pc0").skills, "bare hands")
	assert_true(not "strike" in b.state.get_c("pc1").skills, "armed seats do not get it")
	assert_eq(b.state.get_c("pc0").armor, 0)


func test_armor_takes_a_flat_amount_off_every_hit() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(1, 1), {"armor": 3})])
	Fx.plan(b, "a", [Fx.act("strike", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("e").hp, 17, "6 - 3 armor")


func test_gear_problems_are_reported() -> void:
	var known := SkillDb.load_file()
	var t := _class("warrior").duplicate() as UnitTemplate
	assert_eq(t.problems(known), [] as Array[String])
	var gear: Array[GearDef] = []
	gear.append_array(t.gear)
	gear.append(load("res://game/content/gear/bow.tres") as GearDef)
	t.gear = gear
	assert_true(str(t.problems(known)).contains("at most 2"), str(t.problems(known)))
	var g := GearDef.new()
	g.id = "Bad Id"
	assert_true(str(g.problems(known)).contains("lower-case"))
	var loose := SkillDef.new()
	loose.id = "not_in_the_set"
	g.id = "ok"
	g.display_name = "Ok"
	g.grants = [loose] as Array[SkillDef]
	assert_true(str(g.problems(known)).contains("not in the skill set"))


func test_a_maimed_unit_is_greyed_out_for_attacks_and_skills_in_the_menu() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("pc0", V(1, 1), {"skills": ["move", "strike", "defend", "power_strike"]}), Fx.enemy("e", V(2, 1))])
	var snap := b.snapshot_for("pc0")
	for u: Dictionary in snap["units"]:
		if u["id"] == "pc0":
			u["maimed"] = true
	var me: Dictionary = (snap["units"] as Array).filter(func(u: Dictionary) -> bool: return u["id"] == "pc0")[0]
	var opts := ActionOptions.build({"bf": Battlefield.from_rows(Fx.OPEN), "skills": b.skills, "cfg": b.cfg, "me": me, "units": snap["units"],
		"objects": [], "from": V(1, 1), "ap_left": 3, "planned": [], "items_left": {}, "blocked": {}, "cell": V(2, 1), "unit": "e"})
	for o in opts:
		if o["id"] in ["strike", "power_strike"]:
			assert_true(not o["enabled"] and o["reason"].begins_with("maimed"), str(o))
