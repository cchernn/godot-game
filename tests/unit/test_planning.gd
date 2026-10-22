extends TestCase


func test_plan_over_ap_capacity_is_rejected() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(7, 3))])
	var r := b.submit_plan("a", [Fx.move([V(1, 1), V(2, 1), V(3, 1), V(4, 1)])])
	assert_true(not r["ok"], "4 AP of movement exceeds the 3 AP capacity")


func test_ready_reserves_ap_and_withdraw_releases() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(2, 1))])
	assert_true(b.submit_plan("a", [Fx.move([V(1, 1)]), Fx.act("strike", "e")])["ok"])
	var a := b.state.get_c("a")
	assert_eq(a.ap_reserved, 0, "nothing reserved while planning")
	b.set_ready("a", true)
	assert_eq(a.ap_reserved, 2)
	assert_eq(a.plan[0].reserved, 1)
	b.set_ready("a", false)
	assert_eq(a.ap_reserved, 0)
	assert_true(b.submit_plan("a", [])["ok"], "editable again after withdrawing")


func test_ready_locks_the_plan() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(2, 1))])
	Fx.plan(b, "a", [Fx.move([V(1, 1)])])
	assert_true(not b.submit_plan("a", [])["ok"])


func test_malformed_and_unowned_skills_are_rejected() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1), {"skills": ["move"]}), Fx.enemy("e", V(1, 1))])
	assert_true(not b.submit_plan("a", [{"skill": 5}])["ok"])
	assert_true(not b.submit_plan("a", "nonsense")["ok"])
	assert_true(not b.submit_plan("a", [{"skill": "strike", "target": "e"}])["ok"], "does not own strike")
	assert_true(not b.submit_plan("a", [{"skill": "move", "path": [[0, 1], "x"]}])["ok"])


func test_cannot_target_unseen_enemy() -> void:
	var rows := ["........", "..#.....", "........"]
	var b := Fx.battle(rows, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(4, 1))])
	var r := b.submit_plan("a", [Fx.act("strike", "e")])
	assert_true(not r["ok"], "wall blocks sight, so the target is not selectable")
	assert_eq(r["error"], "Invalid target")


func test_timeout_executes_current_valid_queue_and_empty_means_nothing() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.player("c", V(0, 3)), Fx.enemy("e", V(7, 3))])
	b.submit_plan("a", [Fx.move([V(1, 1)])]) # never readied
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("a").cell, V(1, 1))
	assert_eq(b.state.get_c("c").cell, V(0, 3))


func test_difficult_terrain_adds_ap_cost() -> void:
	var rows := [".~~.....", "........"]
	var b := Fx.battle(rows, [Fx.player("a", V(0, 0)), Fx.enemy("e", V(7, 1))])
	assert_true(not b.submit_plan("a", [Fx.move([V(1, 0), V(2, 0)])])["ok"], "2 steps + 2 surcharge = 4 > 3")
	assert_true(b.submit_plan("a", [Fx.move([V(1, 0)])])["ok"], "1 step + 1 surcharge = 2")


func test_elevation_step_above_limit_is_rejected() -> void:
	var rows := [".2......", "........"]
	var b := Fx.battle(rows, [Fx.player("a", V(0, 0)), Fx.enemy("e", V(7, 1))])
	assert_true(not b.submit_plan("a", [Fx.move([V(1, 0)])])["ok"])
	var rows2 := [".1......", "........"]
	var b2 := Fx.battle(rows2, [Fx.player("a", V(0, 0)), Fx.enemy("e", V(7, 1))])
	assert_true(b2.submit_plan("a", [Fx.move([V(1, 0)])])["ok"])
