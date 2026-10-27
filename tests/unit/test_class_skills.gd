extends TestCase
## The skills of the three classes (all numbers provisional): shields by length, lobbing without sight, the fireball star and the ice line.

const SKILLS := ["move", "strike", "defend", "shield_wall", "shoot", "maim_shot", "lob_shot", "slash", "fireball", "ice_floor"]
const BIG: Array = [".........", ".........", ".........", ".........", ".........", ".........", "........."]


func _p(id: String, cell: Vector2i, extra: Dictionary = {}) -> Dictionary:
	var d := {"skills": SKILLS, "dex": 16}
	d.merge(extra, true)
	return Fx.player(id, cell, d)


func test_defend_shields_only_for_its_beat() -> void:
	var b := Fx.battle(Fx.OPEN, [_p("a", V(0, 1)), Fx.enemy("e", V(1, 1))])
	Fx.plan(b, "a", [{"skill": "defend"}])
	Fx.plan(b, "e", [Fx.act("strike", "a")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	var a := b.state.get_c("a")
	assert_eq(a.hp, 18, "the brace soaked 4 of the strike's 6")
	assert_eq(a.beat_shield, 0, "used up")
	var again := Fx.battle(Fx.OPEN, [_p("a", V(0, 1)), Fx.enemy("e", V(1, 1))])
	Fx.plan(again, "a", [{"skill": "defend"}])
	again.begin_resolution()
	Fx.run_beats(again, 1)
	assert_eq(again.state.get_c("a").beat_shield, 4)
	assert_eq(again.snapshot_for("a")["units"][0]["shield"], 4, "the unit card shows it")
	Fx.run_beats(again, 1)
	assert_eq(again.state.get_c("a").beat_shield, 0, "gone with the beat")


func test_shield_wall_lasts_the_round() -> void:
	var b := Fx.battle(Fx.OPEN, [_p("a", V(0, 1)), Fx.enemy("e", V(1, 1))])
	Fx.plan(b, "a", [{"skill": "shield_wall"}])
	b.begin_resolution()
	Fx.run_beats(b, 5)
	assert_eq(b.state.get_c("a").shield, 8)
	Fx.run_round(b)
	assert_eq(b.state.get_c("a").shield, 0, "ends with the round")


func test_shoot_draws_then_shoots_at_range() -> void:
	var b := Fx.battle(Fx.OPEN, [_p("a", V(0, 1)), Fx.enemy("e", V(4, 1))])
	Fx.plan(b, "a", [Fx.act("shoot", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("e").hp, 20, "the first beat only draws")
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("e").hp, 12)


func test_lob_shot_reaches_a_tile_behind_a_wall() -> void:
	var rows := ["...#.....", "...#.....", "...#.....", "...#....."]
	var b := Fx.battle(rows, [_p("a", V(1, 1)), Fx.enemy("e", V(7, 1))])
	var r := Fx.plan(b, "a", [{"skill": "lob_shot", "cell": V(7, 1)}])
	assert_true(r["ok"], str(r))
	b.begin_resolution()
	Fx.run_beats(b, 2)
	assert_eq(b.state.get_c("e").hp, 12, "no line of sight needed")
	var bolt := Fx.battle(rows, [_p("a", V(1, 1)), Fx.enemy("e", V(7, 1))])
	Fx.plan(bolt, "a", [{"skill": "shoot", "target": "e"}])
	bolt.begin_resolution()
	Fx.run_beats(bolt, 2)
	assert_eq(bolt.state.get_c("e").hp, 20, "a shot at a character does")


func test_fireball_burns_a_star_after_two_beats_of_charging() -> void:
	var b := Fx.battle(BIG, [_p("a", V(0, 3)), Fx.enemy("mid", V(4, 3)), Fx.enemy("side", V(4, 2)), Fx.enemy("diag", V(5, 2))])
	var r := Fx.plan(b, "a", [{"skill": "fireball", "cell": V(4, 3)}])
	assert_true(r["ok"], str(r))
	b.begin_resolution()
	Fx.run_beats(b, 2)
	assert_eq(b.state.get_c("mid").hp, 20, "still charging")
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("mid").hp, 6)
	assert_eq(b.state.get_c("side").hp, 6, "beside the centre")
	assert_eq(b.state.get_c("diag").hp, 20, "a star, not a square")


func test_ice_floor_freezes_a_line_of_three() -> void:
	var b := Fx.battle(BIG, [_p("a", V(0, 3)), Fx.enemy("one", V(1, 3)), Fx.enemy("three", V(3, 3)), Fx.enemy("four", V(4, 3))])
	var r := Fx.plan(b, "a", [{"skill": "ice_floor", "cell": V(3, 3)}])
	assert_true(r["ok"], str(r))
	b.begin_resolution()
	Fx.run_beats(b, 2)
	assert_true(b.state.get_c("one").has_condition("rooted"))
	assert_true(b.state.get_c("three").has_condition("rooted"))
	assert_true(not b.state.get_c("four").has_condition("rooted"), "the fourth tile is out of the line")


func _maim_always(b: Battle) -> void:
	var sk := b.skills.get_skill("maim_shot")
	for st in sk.stage_defs:
		for e in st.effects:
			if e is ApplyStatusEffect:
				(e as ApplyStatusEffect).chance_percent = 100
	sk.stage_defs = sk.stage_defs # marks the cached stage view as stale


func test_maim_shot_hurts_a_little_interrupts_hard_and_maims() -> void:
	var b := Fx.battle(Fx.OPEN, [_p("a", V(0, 1)), Fx.enemy("e", V(3, 1))])
	_maim_always(b)
	Fx.plan(b, "a", [Fx.act("maim_shot", "e")])
	Fx.plan(b, "e", [Fx.act("power_strike", "a")])
	b.begin_resolution()
	Fx.run_beats(b, 2)
	var e := b.state.get_c("e")
	assert_eq(e.hp, 16, "4 damage")
	assert_true(e.has_condition("maimed"))
	assert_eq(b.skills.get_skill("maim_shot").stages[1]["interrupt"], 3, "high interrupt")


func test_a_maimed_unit_cannot_attack_or_use_skills_but_can_defend() -> void:
	var b := Fx.battle(Fx.OPEN, [_p("a", V(0, 1)), Fx.enemy("e", V(3, 1), {"skills": SKILLS})])
	_maim_always(b)
	Fx.plan(b, "a", [Fx.act("maim_shot", "e")])
	b.begin_resolution()
	Fx.run_round(b)
	Fx.plan(b, "e", [Fx.act("strike", "a"), {"skill": "defend"}])
	Fx.plan(b, "a", [{"skill": "defend"}])
	b.begin_resolution()
	Fx.run_beats(b, 3)
	assert_eq(b.state.get_c("a").hp, 20, "the strike never happened")
	assert_true("maimed" in " ".join(Fx.texts(b)))
	assert_true(b.state.get_c("e").beat_shield >= 0 and Fx.has_event(b, "shield"), "defend still works")


func test_a_status_with_a_chance_may_be_shrugged_off() -> void:
	var landed := 0
	for seed in range(1, 41):
		var b := Fx.battle(Fx.OPEN, [_p("a", V(0, 1)), Fx.enemy("e", V(3, 1))], seed)
		Fx.plan(b, "a", [Fx.act("maim_shot", "e")])
		b.begin_resolution()
		Fx.run_beats(b, 2)
		if b.state.get_c("e").has_condition("maimed"):
			landed += 1
	assert_true(landed > 8 and landed < 32, "about half of 40 land (got %d)" % landed)
