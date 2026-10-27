extends TestCase
## The skills of the three classes (all numbers provisional): shields by length, lobbing without sight, the fireball star and the ice line.

const SKILLS := ["move", "strike", "defend", "shield_wall", "aimed_shot", "lob_shot", "fireball", "ice_floor"]
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


func test_aimed_shot_draws_then_shoots_at_range() -> void:
	var b := Fx.battle(Fx.OPEN, [_p("a", V(0, 1)), Fx.enemy("e", V(4, 1))])
	Fx.plan(b, "a", [Fx.act("aimed_shot", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("e").hp, 20, "the first beat only draws")
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("e").hp, 11)


func test_lob_shot_reaches_a_tile_behind_a_wall() -> void:
	var rows := ["...#.....", "...#.....", "...#.....", "...#....."]
	var b := Fx.battle(rows, [_p("a", V(1, 1)), Fx.enemy("e", V(7, 1))])
	var r := Fx.plan(b, "a", [{"skill": "lob_shot", "cell": V(7, 1)}])
	assert_true(r["ok"], str(r))
	b.begin_resolution()
	Fx.run_beats(b, 2)
	assert_eq(b.state.get_c("e").hp, 12, "no line of sight needed")
	var bolt := Fx.battle(rows, [_p("a", V(1, 1)), Fx.enemy("e", V(7, 1))])
	Fx.plan(bolt, "a", [{"skill": "aimed_shot", "target": "e"}])
	bolt.begin_resolution()
	Fx.run_beats(bolt, 2)
	assert_eq(bolt.state.get_c("e").hp, 20, "an aimed shot does")


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
