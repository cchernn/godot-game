extends TestCase
## Effects (damage, heal, shield, interrupt), anyone being a valid target, and Defend. Fx battles always hit and never crit.


## A skill built from effects, registered in the battle's own skill db: a one-stage skill of the given kind.
func _skill(b: Battle, id: String, kind: int, targeting: int, effects: Array, attack_range: int = 3, speed: int = 5) -> void:
	var sk := SkillDef.new()
	sk.id = id
	sk.display_name = id.capitalize()
	sk.kind = kind
	sk.targeting = targeting
	sk.attack_range = attack_range
	sk.speed = speed
	var st := SkillStage.new()
	st.stage_name = id
	var list: Array[SkillEffect] = []
	for e: SkillEffect in effects:
		list.append(e)
	st.effects = list
	var stages: Array[SkillStage] = [st]
	sk.stage_defs = stages
	b.skills.skills[id] = sk


func _heal(n: int, on: int = SkillEffect.On.TARGET) -> HealEffect:
	var e := HealEffect.new()
	e.amount = n
	e.on = on as SkillEffect.On
	return e


func _shield(n: int, on: int = SkillEffect.On.TARGET) -> ShieldEffect:
	var e := ShieldEffect.new()
	e.amount = n
	e.on = on as SkillEffect.On
	return e


func _damage(n: int, on: int = SkillEffect.On.TARGET) -> DamageEffect:
	var e := DamageEffect.new()
	e.base = n
	e.on = on as SkillEffect.On
	return e


func _duel(extra: Dictionary = {}, skills: Array = ["move", "strike", "defend"]) -> Battle:
	return Fx.battle(Fx.OPEN, [Fx.player("p", V(1, 1), {"skills": skills}.merged(extra, true)), Fx.enemy("e", V(2, 1), {"skills": skills, "hp": 40})])


func test_defend_gives_the_caster_a_shield_that_soaks_damage_before_hp() -> void:
	var b := _duel()
	Fx.plan(b, "p", [{"skill": "defend"}])
	Fx.plan(b, "e", [Fx.act("strike", "p")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	var p := b.state.get_c("p")
	assert_eq(p.shield, 0, "4 of the strike's 6 damage were absorbed")
	assert_eq(p.hp, 18, "and the other 2 reached HP")
	assert_true("absorbed" in " ".join(Fx.texts(b)))
	assert_true(Fx.has_event(b, "shield"))


func test_armor_is_applied_before_the_shield() -> void:
	var b := _duel({"armor": 2})
	Fx.plan(b, "p", [{"skill": "defend"}])
	Fx.plan(b, "e", [Fx.act("strike", "p")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	var p := b.state.get_c("p")
	assert_eq(p.hp, 20, "6 - 2 armor = 4, all absorbed by the shield of 4")
	assert_eq(p.shield, 0)


func test_a_shield_ends_with_the_round_and_does_not_stack() -> void:
	var b := _duel()
	b.state.get_c("p").shield = 10
	Fx.plan(b, "p", [{"skill": "defend"}])
	Fx.plan(b, "e", [])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("p").shield, 10, "a lower shield does not replace or add to a higher one")
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").shield, 0, "gone at the start of the next round")
	assert_eq(b.snapshot_for("p")["units"][0]["shield"], 0)


func test_the_snapshot_shows_everyones_shield() -> void:
	var b := _duel()
	Fx.plan(b, "p", [{"skill": "defend"}])
	Fx.plan(b, "e", [])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	var by_id := {}
	for u: Dictionary in b.snapshot_for("p")["units"]:
		by_id[u["id"]] = u
	assert_eq(by_id["p"]["shield"], 4)
	assert_eq(by_id["e"]["shield"], 0)


func test_a_heal_restores_hp_up_to_the_maximum_and_works_on_anyone() -> void:
	var b := _duel({"cur_hp": 15})
	_skill(b, "mend", Enums.SkillKind.SUPPORT, Enums.Targeting.CHARACTER, [_heal(8)])
	b.state.get_c("p").skills.append("mend")
	b.state.get_c("e").skills.append("mend")
	b.state.get_c("e").hp = 30
	Fx.plan(b, "p", [Fx.act("mend", "p")]) # yourself, and the cap: 15 + 8 would pass 20
	Fx.plan(b, "e", [Fx.act("mend", "p")]) # the enemy heals the player
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").hp, 20, "capped at the maximum")
	var heals := b.events.filter(func(e: Dictionary) -> bool: return e["type"] == "heal")
	assert_eq(heals.size(), 2, "both heals ran")
	var total := 0
	for h: Dictionary in heals:
		total += (h["data"] as Dictionary)["amount"] as int
	assert_eq(total, 5, "only 5 HP were missing, whoever healed first")


func test_healing_an_enemy_heals_it() -> void:
	var b := _duel()
	_skill(b, "mend", Enums.SkillKind.SUPPORT, Enums.Targeting.CHARACTER, [_heal(8)])
	b.state.get_c("p").skills.append("mend")
	b.state.get_c("e").hp = 10
	Fx.plan(b, "p", [Fx.act("mend", "e")])
	Fx.plan(b, "e", [])
	Fx.run_round(b)
	assert_eq(b.state.get_c("e").hp, 18)


func test_a_heal_does_nothing_to_a_downed_unit() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("p", V(1, 1)), Fx.enemy("e", V(2, 1)), Fx.enemy("far", V(7, 3))]) # a second enemy keeps the battle going
	_skill(b, "mend", Enums.SkillKind.SUPPORT, Enums.Targeting.CHARACTER, [_heal(8)])
	b.state.get_c("p").skills.append("mend")
	var e := b.state.get_c("e")
	e.life_state = Enums.LifeState.DOWNED
	e.hp = 0
	var r := Fx.plan(b, "p", [Fx.act("mend", "e")])
	assert_true(r["ok"], str(r))
	Fx.run_round(b)
	assert_eq(e.hp, 0)
	assert_eq(e.life_state, Enums.LifeState.DOWNED)
	assert_true(Fx.has_event(b, "no_effect"))


func test_an_attack_can_be_aimed_at_an_ally_and_at_yourself() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.player("c", V(2, 1)), Fx.enemy("e", V(6, 3))])
	assert_true(Fx.plan(b, "a", [Fx.act("strike", "c")])["ok"], "an ally is a valid target")
	Fx.plan(b, "c", [Fx.act("strike", "c")]) # hitting yourself is valid too
	Fx.run_round(b)
	assert_true(b.state.get_c("c").hp < 20, "the ally was hit")
	assert_eq(b.state.get_c("a").hp, 20)


func test_a_tile_attack_hits_whoever_is_on_the_tile_friend_or_foe() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.player("c", V(3, 1), {"facing": Enums.Facing.WEST}), Fx.enemy("e", V(6, 3))])
	Fx.plan(b, "a", [{"skill": "bolt", "cell": V(3, 1)}])
	Fx.run_round(b)
	assert_eq(b.state.get_c("c").hp, 15, "bolt deals 5")


func test_an_effect_aimed_at_the_caster_applies_to_the_caster() -> void:
	var b := _duel()
	_skill(b, "drain", Enums.SkillKind.ATTACK, Enums.Targeting.CHARACTER, [_damage(5), _heal(3, SkillEffect.On.CASTER)], 1)
	b.state.get_c("p").skills.append("drain")
	b.state.get_c("p").hp = 10
	Fx.plan(b, "p", [Fx.act("drain", "e")])
	Fx.plan(b, "e", [])
	Fx.run_round(b)
	assert_eq(b.state.get_c("e").hp, 35)
	assert_eq(b.state.get_c("p").hp, 13)


func test_a_self_skill_needs_no_target_and_ignores_range() -> void:
	var b := _duel()
	assert_true(Fx.plan(b, "p", [{"skill": "defend"}])["ok"])
	var s := b.skills.get_skill("defend")
	assert_eq(s.kind, Enums.SkillKind.SUPPORT)
	assert_eq(s.targeting, Enums.Targeting.SELF)


func test_a_miss_does_not_apply_a_following_interrupt() -> void:
	var b := _duel()
	b.cfg.data["combat"]["base_hit_chance"] = 0.0
	b.cfg.data["combat"]["accuracy_per_point"] = 0.0
	b.rng.seed = 5
	var strike := b.skills.get_skill("strike")
	strike.stability = 1
	var e := b.state.get_c("e")
	e.skills.append("power_strike")
	Fx.plan(b, "e", [Fx.act("power_strike", "p")])
	Fx.plan(b, "p", [Fx.act("strike", "e")])
	Fx.run_round(b)
	assert_true(not Fx.has_event(b, "interrupt"), "the strike missed (the minimum chance is 5 percent), so there is no interruption")


func test_effect_problems_are_reported() -> void:
	assert_true(not DamageEffect.new().problems().is_empty(), "a damage effect with no base")
	assert_true(not HealEffect.new().problems().is_empty())
	assert_true(not ShieldEffect.new().problems().is_empty())
	assert_true(_damage(3).problems().is_empty())
	var sk := SkillDef.new()
	sk.id = "x"
	sk.display_name = "X"
	sk.kind = Enums.SkillKind.SUPPORT
	var st := SkillStage.new()
	var list: Array[SkillEffect] = [ShieldEffect.new()]
	st.effects = list
	var stages: Array[SkillStage] = [st]
	sk.stage_defs = stages
	var text := " ".join(sk.problems())
	assert_true("shield effect" in text and "target type" in text, text)
