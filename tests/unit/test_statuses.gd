extends TestCase
## Statuses: timed conditions counted in turns (stat changes, each-turn effects, stun, root, cleanse). The statuses here are
## test fixtures built in code; no real statuses ship with the framework.


func _status(id: String, turns: int = 2, extra: Dictionary = {}) -> StatusDef:
	var s := StatusDef.new()
	s.id = id
	s.display_name = id.capitalize()
	s.duration_turns = turns
	for k: String in extra:
		s.set(k, extra[k])
	return s


func _apply(s: StatusDef, duration: int = 0, on: int = SkillEffect.On.TARGET) -> ApplyStatusEffect:
	var e := ApplyStatusEffect.new()
	e.status = s
	e.duration_turns = duration
	e.on = on as SkillEffect.On
	return e


func _skill(b: Battle, id: String, effects: Array, targeting: int = Enums.Targeting.CHARACTER) -> void:
	var sk := SkillDef.new()
	sk.id = id
	sk.display_name = id.capitalize()
	sk.kind = Enums.SkillKind.ATTACK if targeting != Enums.Targeting.SELF else Enums.SkillKind.SUPPORT
	sk.targeting = targeting
	sk.attack_range = 3
	sk.speed = 5
	sk.frequency = Enums.Frequency.UNLIMITED
	var st := SkillStage.new()
	st.stage_name = id
	var list: Array[SkillEffect] = []
	for e: SkillEffect in effects:
		list.append(e)
	st.effects = list
	var stages: Array[SkillStage] = [st]
	sk.stage_defs = stages
	b.skills.skills[id] = sk


func _duel() -> Battle:
	var skills := ["move", "strike", "defend", "hex", "cleanse"]
	return Fx.battle(Fx.OPEN, [Fx.player("p", V(1, 1), {"skills": skills}), Fx.enemy("e", V(2, 1), {"skills": skills, "hp": 40})])


## Puts a status on a combatant directly, as if a skill had applied it earlier.
func _give(c: Combatant, s: StatusDef, turns: int = -1, stacks: int = 1) -> void:
	c.statuses.append({"id": s.id, "def": s.to_dict(), "turns_left": turns if turns > 0 else s.duration_turns, "stacks": stacks})


func _dmg_tick(n: int) -> DamageEffect:
	var d := DamageEffect.new()
	d.base = n
	d.can_miss = false
	d.can_crit = false
	d.uses_power = false
	return d


func test_a_skill_applies_a_status_that_lasts_its_turns() -> void:
	var b := _duel()
	_skill(b, "hex", [_apply(_status("hexed", 2))])
	Fx.plan(b, "p", [Fx.act("hex", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	var e := b.state.get_c("e")
	assert_eq(e.statuses.size(), 1)
	assert_eq(e.statuses[0]["turns_left"], 2)
	assert_true(Fx.has_event(b, "status_apply"))
	Fx.run_round(b) # finishes this turn: the turn it was applied in counted as the first
	assert_eq(e.statuses[0]["turns_left"], 1)
	Fx.run_round(b)
	assert_eq(e.statuses.size(), 0, "gone after its second turn")
	assert_true(Fx.has_event(b, "status_end"))


func test_a_one_turn_status_applied_mid_turn_ends_with_that_turn() -> void:
	var b := _duel()
	_skill(b, "hex", [_apply(_status("hexed", 1))])
	Fx.plan(b, "p", [Fx.act("hex", "e")])
	Fx.run_round(b)
	assert_eq(b.state.get_c("e").statuses.size(), 0)


func test_the_duration_can_be_overridden_on_the_effect() -> void:
	var b := _duel()
	_skill(b, "hex", [_apply(_status("hexed", 2), 4)])
	Fx.plan(b, "p", [Fx.act("hex", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("e").statuses[0]["turns_left"], 4)


func test_refresh_restarts_the_timer_without_stacking() -> void:
	var b := _duel()
	_skill(b, "hex", [_apply(_status("hexed", 3, {"armor": 2}))])
	var e := b.state.get_c("e")
	_give(e, _status("hexed", 3, {"armor": 2}), 1)
	Fx.plan(b, "p", [Fx.act("hex", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(e.statuses.size(), 1)
	assert_eq(e.statuses[0]["turns_left"], 3)
	assert_eq(e.statuses[0]["stacks"], 1)
	assert_eq(e.stat("armor"), 2)


func test_stack_adds_up_to_the_maximum_and_scales_the_changes() -> void:
	var b := _duel()
	var def := _status("frail", 2, {"stacking": StatusDef.Stacking.STACK, "max_stacks": 2, "armor": -1, "evasion": 2})
	_skill(b, "hex", [_apply(def)])
	Fx.plan(b, "p", [Fx.act("hex", "e"), Fx.act("hex", "e"), Fx.act("hex", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 3)
	var e := b.state.get_c("e")
	assert_eq(e.statuses[0]["stacks"], 2, "capped at max_stacks")
	assert_eq(e.stat("armor"), -2)
	assert_eq(e.stat("evasion"), 4)


func test_ignore_leaves_the_first_one_alone() -> void:
	var b := _duel()
	var def := _status("mark", 3, {"stacking": StatusDef.Stacking.IGNORE})
	_skill(b, "hex", [_apply(def)])
	var e := b.state.get_c("e")
	_give(e, def, 1)
	Fx.plan(b, "p", [Fx.act("hex", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(e.statuses[0]["turns_left"], 1)
	assert_true(Fx.has_event(b, "no_effect"))


func test_stat_changes_reach_damage_and_hit_chance() -> void:
	var b := _duel()
	_give(b.state.get_c("e"), _status("plated", 2, {"armor": 3}))
	Fx.plan(b, "p", [Fx.act("strike", "e")])
	Fx.plan(b, "e", [])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("e").hp, 40 - 3, "6 damage minus 3 armor from the status (strike does 6 here)")
	var c := Combatant.new()
	c.accuracy = 1
	_give(c, _status("sharp", 2, {"accuracy": 4, "power": 2}))
	assert_eq(c.stat("accuracy"), 5)
	assert_eq(c.stat("power"), 2)


func test_dexterity_changes_ap() -> void:
	var b := _duel()
	var p := b.state.get_c("p")
	_give(p, _status("swift", 2, {"dexterity": 4}))
	assert_eq(p.stat("dexterity"), p.dexterity + 4)
	Fx.run_round(b)
	assert_eq(p.ap_capacity, b.cfg.ap_capacity(p.dexterity + 4), "next round's AP follows the changed dexterity")


func test_agility_changes_tiles_per_ap() -> void:
	var b := _duel()
	var p := b.state.get_c("p")
	_give(p, _status("fleet", 2, {"agility": 4}))
	assert_eq(p.stat("agility"), p.agility + 4)
	assert_eq(b.snapshot_for("p")["units"][0]["tiles_per_ap"], b.cfg.tiles_per_ap(p.agility + 4))


func test_each_turn_damage_ticks_at_the_start_of_every_turn() -> void:
	var b := _duel()
	var d := _status("bleed", 2)
	d.tick_effects.append(_dmg_tick(3))
	var p := b.state.get_c("p")
	_give(p, d)
	Fx.run_round(b)
	assert_eq(p.hp, 20 - 3)
	Fx.run_round(b)
	assert_eq(p.hp, 20 - 6)
	Fx.run_round(b)
	assert_eq(p.hp, 20 - 6, "it has run out")


func test_ticks_repeat_per_stack_and_can_down_a_unit() -> void:
	var b := _duel()
	var d := _status("bleed", 3, {"stacking": StatusDef.Stacking.STACK})
	d.tick_effects.append(_dmg_tick(4))
	var p := b.state.get_c("p")
	p.hp = 5
	_give(p, d, 3, 2)
	b.begin_resolution()
	assert_eq(p.life_state, Enums.LifeState.DOWNED, "2 stacks x 4 damage")
	assert_eq(p.statuses.size(), 0, "a downed unit loses its statuses")


func test_each_turn_healing_is_capped_at_max_hp() -> void:
	var b := _duel()
	var d := _status("mend", 2)
	var h := HealEffect.new()
	h.amount = 5
	d.tick_effects.append(h)
	var p := b.state.get_c("p")
	p.hp = 18
	_give(p, d)
	b.begin_resolution()
	assert_eq(p.hp, 20)


func test_statuses_use_no_random_numbers() -> void:
	var b := _duel()
	var d := _status("bleed", 2)
	d.tick_effects.append(_dmg_tick(1))
	_give(b.state.get_c("p"), d)
	var before := b.rng.state
	b.begin_resolution()
	assert_eq(b.rng.state, before)


func test_a_stunned_unit_loses_its_actions_but_not_the_battle() -> void:
	var b := _duel()
	_give(b.state.get_c("e"), _status("stun", 1, {"stunned": true}))
	Fx.plan(b, "p", [])
	Fx.plan(b, "e", [Fx.act("strike", "p")])
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").hp, 20, "the stunned enemy never struck")
	assert_true(Fx.has_event(b, "stunned"))
	assert_eq(b.state.get_c("e").ap_reserved, 0)
	assert_eq(b.state.get_c("e").statuses.size(), 0)
	Fx.plan(b, "e", [Fx.act("strike", "p")])
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").hp, 14, "free to act the turn after")


func test_a_stun_applied_mid_turn_cancels_the_rest_of_that_turn() -> void:
	var b := _duel()
	var s := _status("stun", 1, {"stunned": true})
	_skill(b, "hex", [_apply(s)])
	b.skills.get_skill("hex").speed = 9
	Fx.plan(b, "p", [Fx.act("hex", "e")])
	Fx.plan(b, "e", [Fx.act("strike", "p")])
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").hp, 20)


func test_a_stunned_unit_does_not_react() -> void:
	var b := _duel()
	var e := b.state.get_c("e")
	e.reaction = {"skill": "disrupt", "expires_beat": 8}
	_give(e, _status("stun", 1, {"stunned": true}))
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_true(e.reaction.is_empty())


func test_a_rooted_unit_cannot_move_but_can_attack() -> void:
	var b := _duel()
	var p := b.state.get_c("p")
	_give(p, _status("root", 1, {"rooted": true}))
	Fx.plan(b, "p", [Fx.move([V(1, 2)]), Fx.act("strike", "e")])
	Fx.plan(b, "e", [])
	Fx.run_round(b)
	assert_eq(p.cell, V(1, 1))
	assert_true("rooted" in " ".join(Fx.texts(b)))
	assert_eq(b.state.get_c("e").hp, 40 - 6, "the strike still happened")


func test_cleanse_removes_by_mode() -> void:
	var b := _duel()
	var p := b.state.get_c("p")
	_give(p, _status("boon", 3, {"kind": StatusDef.Kind.BUFF}))
	_give(p, _status("bane", 3, {"kind": StatusDef.Kind.DEBUFF}))
	_give(p, _status("odd", 3))
	var r := RemoveStatusEffect.new()
	r.mode = RemoveStatusEffect.Mode.DEBUFFS
	r.on = SkillEffect.On.CASTER
	_skill(b, "cleanse", [r], Enums.Targeting.SELF)
	Fx.plan(b, "p", [{"skill": "cleanse"}])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(p.statuses.size(), 2)
	assert_true(p.status_of("bane").is_empty())
	r.mode = RemoveStatusEffect.Mode.ONE
	r.status = _status("odd")
	b.skills.skills["cleanse"].stage_defs[0].effects[0] = r
	assert_true(r.problems().is_empty())


func test_a_status_does_not_land_when_the_hit_before_it_missed() -> void:
	var b := _duel()
	b.cfg.data["combat"]["base_hit_chance"] = 0.0
	b.cfg.data["combat"]["accuracy_per_point"] = 0.0
	var d := DamageEffect.new()
	d.base = 4
	_skill(b, "hex", [d, _apply(_status("hexed"))])
	Fx.plan(b, "p", [Fx.act("hex", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("e").statuses.size(), 0)


func test_the_snapshot_lists_statuses_and_conditions() -> void:
	var b := _duel()
	_give(b.state.get_c("e"), _status("stun", 2, {"stunned": true, "glyph": "Z", "hint": "can't act"}))
	var found := false
	for u: Dictionary in b.snapshot_for("p")["units"]:
		if u["id"] == "e":
			found = true
			assert_eq(u["statuses"].size(), 1)
			assert_eq(u["statuses"][0]["turns"], 2)
			assert_eq(u["statuses"][0]["glyph"], "Z")
			assert_true(u["stunned"])
			assert_true(not u["rooted"])
	assert_true(found)


func test_status_problems_are_reported() -> void:
	assert_true(not StatusDef.new().problems().is_empty(), "needs an id")
	var d := _status("x")
	var miss := DamageEffect.new()
	miss.base = 1
	d.tick_effects.append(miss)
	assert_true(not d.problems().is_empty(), "each-turn damage may not miss or crit")
	var d2 := _status("y")
	d2.tick_effects.append(InterruptEffect.new())
	assert_true(not d2.problems().is_empty(), "only damage, heal or shield tick")
	assert_true(not ApplyStatusEffect.new().problems().is_empty(), "needs a status")
	assert_true(_status("fine").problems().is_empty())


func test_statuses_are_cleared_when_revived_and_a_revive_starts_clean() -> void:
	var b := _duel()
	var p := b.state.get_c("p")
	_give(p, _status("bane", 5))
	p.hp = 1
	Fx.plan(b, "p", [])
	Fx.plan(b, "e", [Fx.act("strike", "p")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(p.life_state, Enums.LifeState.DOWNED)
	assert_eq(p.statuses.size(), 0)
