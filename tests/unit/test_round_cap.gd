extends TestCase
## A fight that goes on too long ends as a draw instead of for ever.


func _stalemate(max_rounds: int) -> Battle:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(1, 1)), Fx.enemy("e", V(5, 1))])
	b.max_rounds = max_rounds
	return b


func _play_round(b: Battle) -> void:
	Fx.plan(b, "a", [])
	b.begin_resolution()
	Fx.run_beats(b, b.beats_per_round)


func test_the_limit_is_in_the_balance_file() -> void:
	assert_true(int(GameConfig.load_file().get_value("combat", "max_rounds")) > 0)


func test_a_fight_that_reaches_the_limit_ends_as_a_draw() -> void:
	var b := _stalemate(3)
	for i in 2:
		_play_round(b)
		assert_eq(b.outcome, Enums.Outcome.NONE, "round %d: still going" % (i + 1))
		assert_eq(b.state.round_number, i + 2)
	_play_round(b)
	assert_eq(b.outcome, Enums.Outcome.DRAW)
	assert_eq(b.state.phase, Enums.RoundPhase.FINISHED)
	assert_eq(b.state.round_number, 3, "the last round is the one reported")
	assert_true(Fx.has_event(b, "victory"))


func test_no_limit_means_the_fight_may_go_on() -> void:
	var b := _stalemate(0)
	for i in 6:
		_play_round(b)
	assert_eq(b.outcome, Enums.Outcome.NONE)


func test_the_snapshot_tells_the_limit_and_a_win_on_the_last_round_still_counts() -> void:
	var b := _stalemate(2)
	assert_eq(b.snapshot_for("a")["max_rounds"], 2)
	_play_round(b)
	b.state.get_c("e").life_state = Enums.LifeState.ELIMINATED
	Fx.plan(b, "a", [])
	b.begin_resolution()
	Fx.run_beats(b, b.beats_per_round)
	assert_eq(b.outcome, Enums.Outcome.PLAYERS_WIN, "beating the enemy takes precedence over the clock")
