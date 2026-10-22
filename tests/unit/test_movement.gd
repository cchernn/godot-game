extends TestCase


func test_movement_resolves_tile_by_tile_spending_ap_as_it_goes() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(7, 3))])
	Fx.plan(b, "a", [Fx.move([V(1, 1), V(2, 1), V(3, 1)])])
	var a := b.state.get_c("a")
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(a.cell, V(1, 1))
	assert_eq(a.ap_spent, 1)
	assert_eq(a.ap_reserved, 2, "reserved AP is not spent AP")
	Fx.run_beats(b, 2)
	assert_eq(a.cell, V(3, 1))
	assert_eq(a.ap_spent, 3)


func test_blocked_tile_stops_at_last_valid_tile_and_forfeits_rest() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(2, 1))])
	Fx.plan(b, "a", [Fx.move([V(1, 1), V(2, 1), V(3, 1)])])
	b.begin_resolution()
	Fx.run_beats(b, 7)
	var a := b.state.get_c("a")
	assert_eq(a.cell, V(1, 1))
	assert_eq(a.ap_spent, 1)
	assert_eq(a.ap_forfeited, 2, "unused reservation is forfeited, not refunded")
	assert_eq(a.ap_reserved, 0)


func test_equal_speed_collision_has_exactly_one_winner_and_is_deterministic() -> void:
	var winners: Array[String] = []
	for run in 2:
		var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(2, 1))], 7)
		Fx.plan(b, "a", [Fx.move([V(1, 1)])])
		Fx.plan(b, "e", [Fx.move([V(1, 1)])])
		b.begin_resolution()
		Fx.run_beats(b, 1)
		var at_target := b.state.at_cell(V(1, 1))
		assert_true(at_target != null)
		var other := b.state.get_c("e" if at_target.id == "a" else "a")
		assert_true(other.cell != V(1, 1), "loser stays out")
		winners.append(at_target.id)
		assert_true(Fx.has_event(b, "skip") or Fx.has_event(b, "move_stop"))
	assert_eq(winners[0], winners[1], "same seed, same priority")


func test_both_winners_possible_across_seeds() -> void:
	var seen := {}
	for s in range(1, 30):
		var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(2, 1))], s)
		Fx.plan(b, "a", [Fx.move([V(1, 1)])])
		Fx.plan(b, "e", [Fx.move([V(1, 1)])])
		b.begin_resolution()
		Fx.run_beats(b, 1)
		seen[b.state.at_cell(V(1, 1)).id] = true
	assert_eq(seen.size(), 2, "priority is random per beat, not always the same side")


func test_dexterity_moves_multiple_tiles_per_ap() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1), {"dex": 12}), Fx.enemy("e", V(7, 3))])
	Fx.plan(b, "a", [Fx.move([V(1, 1), V(2, 1)])])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	var a := b.state.get_c("a")
	assert_eq(a.cell, V(2, 1))
	assert_eq(a.ap_spent, 1, "two tiles for one AP")


func test_difficult_terrain_costs_extra_when_entered() -> void:
	var b := Fx.battle([".~......", "........"], [Fx.player("a", V(0, 0)), Fx.enemy("e", V(7, 1))])
	Fx.plan(b, "a", [Fx.move([V(1, 0)])])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("a").ap_spent, 2)


func test_facing_after_move_is_explicit() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(7, 3))])
	Fx.plan(b, "a", [Fx.move([V(1, 1)], Enums.Facing.NORTH)])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("a").facing, Enums.Facing.NORTH, "independent of the movement direction")


func test_defeated_character_loses_whole_queue() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1), {"hp": 6}), Fx.enemy("e", V(1, 1))])
	Fx.plan(b, "a", [Fx.move([V(0, 2)]), Fx.move([V(0, 3)])])
	Fx.plan(b, "e", [Fx.act("strike", "a")])
	b.begin_resolution()
	Fx.run_beats(b, 7)
	var a := b.state.get_c("a")
	assert_eq(a.life_state, Enums.LifeState.DOWNED)
	assert_eq(a.cell, V(0, 1), "strike (speed 6) beats move (speed 5); a never moved")
	assert_eq(a.ap_reserved, 0)
