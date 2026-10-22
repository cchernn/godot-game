extends TestCase


func test_faster_action_resolves_first_and_defeated_target_loses_its_action() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.enemy("e", V(2, 1), {"hp": 6}), Fx.player("c", V(0, 3))])
	Fx.plan(b, "a", [Fx.act("strike", "e")])
	Fx.plan(b, "e", [{"skill": "bolt", "cell": V(1, 1), "target": ""}])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("e").life_state, Enums.LifeState.ELIMINATED)
	assert_eq(b.state.get_c("a").hp, 20, "the fast strike killed e before its bolt resolved")


func test_victory_is_checked_after_the_whole_beat_and_skips_later_beats() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.player("c", V(1, 3)), Fx.enemy("e", V(2, 1), {"hp": 6})])
	Fx.plan(b, "a", [Fx.act("strike", "e")])
	Fx.plan(b, "c", [{"skill": "bolt", "cell": V(6, 3)}, Fx.move([V(1, 2)])])
	Fx.plan(b, "e", [])
	b.begin_resolution()
	Fx.run_beats(b, 3)
	assert_eq(b.outcome, Enums.Outcome.PLAYERS_WIN)
	assert_eq(b.beat, 1, "later beats do not execute")
	assert_true(Fx.has_event(b, "miss"), "c's slower bolt in the same beat still resolved")
	assert_eq(b.state.get_c("c").cell, V(1, 3), "but its next action (beat 2) did not")
	assert_eq(b.state.phase, Enums.RoundPhase.FINISHED)


func test_invalid_action_is_skipped_and_queue_continues() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(5, 1))])
	Fx.plan(b, "a", [Fx.act("strike", "e"), Fx.move([V(1, 1)])])
	b.begin_resolution()
	Fx.run_beats(b, 3)
	assert_true(Fx.has_event(b, "skip"))
	assert_eq(b.state.get_c("a").cell, V(1, 1))


func test_once_per_turn_limit_consumed_on_execution_not_when_queued_or_skipped() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(1, 1)), Fx.enemy("far", V(4, 1))])
	# the first strike is skipped (target out of range), so it does not use up the limit
	Fx.plan(b, "a", [Fx.act("strike", "far"), Fx.act("strike", "e"), Fx.act("strike", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 4)
	assert_eq(b.state.get_c("e").hp, 14, "exactly one strike landed")
	assert_true("already used this round" in " ".join(Fx.texts(b)))


func test_power_strike_interrupted_by_accumulated_hits() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("p", V(1, 1), {"hp": 60}), Fx.enemy("e1", V(2, 1)), Fx.enemy("e2", V(1, 0))])
	Fx.plan(b, "p", [Fx.act("power_strike", "e1"), Fx.move([V(1, 2)])])
	for id in ["e1", "e2"]:
		Fx.plan(b, id, [Fx.act("strike", "p"), {"skill": "bolt", "cell": V(1, 1)}])
	b.begin_resolution()
	Fx.run_beats(b, 7)
	var p := b.state.get_c("p")
	assert_true(Fx.has_event(b, "interrupt"))
	assert_eq(b.state.get_c("e1").hp, 20, "the smash stage was cancelled")
	assert_eq(p.cell, V(1, 2), "the next queued action proceeds after an ordinary interruption")
	assert_eq(p.ap_spent, 2, "wind-up AP is not refunded; move AP spent")
	assert_eq(p.ap_forfeited, 1, "the cancelled stage's reservation is forfeited")


func test_hits_below_threshold_do_not_interrupt() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("p", V(1, 1), {"hp": 60}), Fx.enemy("e1", V(2, 1))])
	Fx.plan(b, "p", [Fx.act("power_strike", "e1")])
	Fx.plan(b, "e1", [Fx.act("strike", "p"), {"skill": "bolt", "cell": V(1, 1)}])
	b.begin_resolution()
	Fx.run_beats(b, 3)
	assert_true(not Fx.has_event(b, "interrupt"), "one point of two")
	assert_true(b.state.get_c("e1").hp < 20, "smash landed")


func test_reaction_adds_interruption_points_and_can_cancel() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("r", V(1, 1), {"hp": 40}), Fx.enemy("e", V(2, 1))])
	Fx.plan(b, "r", [Fx.act("disrupt", "")])
	Fx.plan(b, "e", [Fx.act("power_strike", "r")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	var r := b.state.get_c("r")
	assert_true(Fx.has_event(b, "reaction"))
	assert_true(Fx.has_event(b, "interrupt"), "2 points reach the stability threshold of 2")
	assert_true(r.skills_used.has("disrupt"), "usage consumed when the reaction executes")
	Fx.run_beats(b, 2)
	assert_eq(r.hp, 40, "smash never happened")


func test_reaction_does_not_interrupt_if_threshold_not_reached() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("r", V(1, 1), {"hp": 40}), Fx.enemy("e", V(2, 1))])
	b.skills.get_skill("power_strike").stability = 3
	Fx.plan(b, "r", [Fx.act("disrupt", "")])
	Fx.plan(b, "e", [Fx.act("power_strike", "r")])
	b.begin_resolution()
	Fx.run_beats(b, 3)
	assert_true(Fx.has_event(b, "reaction"))
	assert_true(not Fx.has_event(b, "interrupt"))
	assert_eq(b.state.get_c("r").hp, 28, "the smash resolved")


func test_preparing_a_reaction_does_not_consume_its_usage_and_single_stage_does_not_trigger() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("r", V(1, 1), {"hp": 40}), Fx.enemy("e", V(2, 1))])
	Fx.plan(b, "r", [Fx.act("disrupt", "")])
	Fx.plan(b, "e", [Fx.act("strike", "r")])
	b.begin_resolution()
	Fx.run_beats(b, 2)
	var r := b.state.get_c("r")
	assert_true(not r.skills_used.has("disrupt"))
	assert_true(not r.reaction.is_empty(), "still waiting for a trigger")
	assert_true(not Fx.has_event(b, "reaction"))


func test_reaction_out_of_range_does_not_trigger() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("r", V(0, 1), {"hp": 40}), Fx.enemy("e", V(4, 1), {"skills": ["move", "bolt", "power_strike"]}),
		Fx.player("t", V(5, 1), {"hp": 40})])
	Fx.plan(b, "r", [Fx.act("disrupt", "")])
	Fx.plan(b, "e", [Fx.act("power_strike", "t")])
	b.begin_resolution()
	Fx.run_beats(b, 3)
	assert_true(not Fx.has_event(b, "reaction"), "distance 4 > reaction range 3")


func test_downed_revive_once_then_elimination() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("p", V(1, 1), {"hp": 20, "cur_hp": 5}), Fx.player("c", V(0, 1)),
		Fx.enemy("e", V(2, 1), {"hp": 99})])
	# Round 1: e downs p.
	Fx.plan(b, "e", [Fx.act("strike", "p")])
	Fx.run_round(b)
	var p := b.state.get_c("p")
	assert_eq(p.life_state, Enums.LifeState.DOWNED)
	assert_true(not b.submit_plan("p", [])["ok"], "downed characters cannot act")
	# Round 2: c revives p.
	Fx.plan(b, "c", [Fx.act("revive", "p")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(p.life_state, Enums.LifeState.ALIVE)
	assert_eq(p.hp, 4)
	assert_true(p.revived_this_encounter)
	assert_true(not p.is_active(b.state.round_number), "cannot act for the rest of this round")
	while b.state.phase == Enums.RoundPhase.RESOLVING:
		b.resolve_next_beat()
	assert_true(p.is_active(b.state.round_number), "acts again next round")
	# Round 3: a second defeat eliminates immediately.
	Fx.plan(b, "e", [Fx.act("strike", "p")])
	Fx.run_round(b)
	assert_eq(p.life_state, Enums.LifeState.ELIMINATED)
	assert_true(b.snapshot_for("p")["eliminated"])


func test_enemy_can_finish_a_downed_character() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("p", V(1, 1), {"cur_hp": 5}), Fx.player("c", V(0, 3)), Fx.enemy("e", V(2, 1), {"hp": 99})])
	Fx.plan(b, "e", [Fx.act("strike", "p")])
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").life_state, Enums.LifeState.DOWNED)
	Fx.plan(b, "e", [Fx.act("strike", "p")])
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").life_state, Enums.LifeState.ELIMINATED, "no second downed state")


func test_tile_target_misses_when_target_leaves_but_character_target_tracks() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.player("c", V(0, 3)), Fx.enemy("e", V(2, 1), {"hp": 99}),
		Fx.enemy("e2", V(5, 3))])
	b.skills.get_skill("bolt").speed = 3
	b.skills.get_skill("strike").speed = 3
	b.skills.get_skill("strike").attack_range = 3
	Fx.plan(b, "a", [{"skill": "bolt", "cell": V(2, 1)}, Fx.act("strike", "e")])
	Fx.plan(b, "e", [Fx.move([V(3, 1)])])
	b.begin_resolution()
	Fx.run_beats(b, 3)
	assert_true("strikes empty ground" in " ".join(Fx.texts(b)), "tile attack missed the vacated tile")
	assert_eq(b.state.get_c("e").hp, 93, "tracked character-target strike landed (6 damage = 99 - 6)")


func test_flanking_and_armor_modify_damage() -> void:
	var front := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.enemy("e", V(2, 1), {"facing": Enums.Facing.WEST, "hp": 99})])
	Fx.plan(front, "a", [Fx.act("strike", "e")])
	Fx.run_round(front)
	assert_eq(front.state.get_c("e").hp, 93, "front: 6")
	var rear := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.enemy("e", V(2, 1), {"facing": Enums.Facing.EAST, "hp": 99})])
	Fx.plan(rear, "a", [Fx.act("strike", "e")])
	Fx.run_round(rear)
	assert_eq(rear.state.get_c("e").hp, 90, "rear: 6 x 1.5 = 9")
	var side := Fx.battle(Fx.OPEN, [Fx.player("a", V(2, 0)), Fx.enemy("e", V(2, 1), {"facing": Enums.Facing.WEST, "hp": 99})])
	Fx.plan(side, "a", [Fx.act("strike", "e")])
	Fx.run_round(side)
	assert_eq(side.state.get_c("e").hp, 91, "side: 6 x 1.25 = 7.5 -> 8")
	var armored := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.enemy("e", V(2, 1), {"armor": 4, "hp": 99})])
	Fx.plan(armored, "a", [Fx.act("strike", "e")])
	Fx.run_round(armored)
	assert_eq(armored.state.get_c("e").hp, 97, "armor reduces damage after the hit")


func test_ap_refreshes_and_unused_ap_does_not_carry_over() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(7, 3))])
	Fx.plan(b, "a", [Fx.move([V(1, 1)])])
	Fx.run_round(b)
	var a := b.state.get_c("a")
	assert_eq(b.state.round_number, 2)
	assert_eq(a.ap_capacity, 3)
	assert_eq(a.ap_spent, 0)
	assert_eq(a.ap_reserved, 0)
	assert_eq(a.ap_forfeited, 0)
