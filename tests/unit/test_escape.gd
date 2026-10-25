extends TestCase


func test_escape_while_planning_takes_effect_at_once_and_frees_the_tile() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.player("c", V(1, 3)), Fx.enemy("e", V(5, 1))])
	assert_true(b.escape("a")["ok"])
	var a := b.state.get_c("a")
	assert_eq(a.life_state, Enums.LifeState.ESCAPED)
	assert_true(not a.is_active(1) and not a.is_present())
	assert_true(b.state.at_cell(V(1, 1)) == null, "the tile is free")
	assert_eq(b.outcome, Enums.Outcome.NONE, "the battle goes on for the others")
	assert_true(Fx.has_event(b, "escape"))
	assert_true(not b.escape("a")["ok"], "once only")


func test_escaped_character_is_not_waited_for_and_spectates() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.player("c", V(1, 3)), Fx.enemy("e", V(5, 1))])
	b.escape("a")
	Fx.plan(b, "c", [])
	assert_true(b.all_required_ready())
	var snap := b.snapshot_for("a")
	assert_true(snap["escaped"] and not snap["eliminated"])
	var ids: Array = snap["units"].map(func(u: Dictionary) -> String: return u["id"])
	assert_true(not ids.has("a") and ids.has("c"), "the spectator still sees the board")
	assert_true(not b.submit_plan("a", [])["ok"] and not b.set_ready("a", true)["ok"])


func test_escape_during_resolution_waits_for_the_next_beat() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.player("c", V(1, 3)), Fx.enemy("e", V(5, 1))])
	Fx.plan(b, "a", [Fx.move([V(2, 1), V(3, 1)])])
	Fx.plan(b, "c", [])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_true(b.escape("a")["ok"])
	assert_eq(b.state.get_c("a").life_state, Enums.LifeState.ALIVE, "not yet")
	assert_true(b.snapshot_for("a")["units"][0]["escaping"])
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("a").life_state, Enums.LifeState.ESCAPED)


func test_last_character_escaping_ends_the_battle_as_an_escape() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.player("c", V(1, 3)), Fx.enemy("e", V(5, 1))])
	b.escape("a")
	b.state.get_c("c").life_state = Enums.LifeState.ELIMINATED
	Fx.plan(b, "a", [])
	b.begin_resolution()
	b.state.get_c("c").life_state = Enums.LifeState.ALIVE
	assert_true(b.escape("c")["ok"])
	Fx.run_beats(b, 1)
	assert_eq(b.outcome, Enums.Outcome.ESCAPED)
	assert_eq(b.state.phase, Enums.RoundPhase.FINISHED)
	assert_true(not b.escape("c")["ok"], "nothing to escape from after the end")


func test_everyone_dead_or_escaped_is_an_escape_but_all_dead_is_still_a_defeat() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.player("c", V(1, 3)), Fx.enemy("e", V(5, 1))])
	b.state.get_c("c").life_state = Enums.LifeState.ELIMINATED
	b.escape("a")
	assert_eq(b.outcome, Enums.Outcome.ESCAPED)
	var d := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.enemy("e", V(5, 1))])
	d.state.get_c("a").life_state = Enums.LifeState.ELIMINATED
	assert_eq(d.check_victory(), Enums.Outcome.PLAYERS_LOSE)


func test_victory_after_a_teammate_escaped_is_still_a_win() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.player("c", V(2, 2)), Fx.enemy("e", V(2, 1), {"hp": 6})])
	b.escape("c")
	Fx.plan(b, "a", [Fx.act("strike", "e")])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.outcome, Enums.Outcome.PLAYERS_WIN)
