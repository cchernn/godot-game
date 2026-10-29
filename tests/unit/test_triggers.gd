extends TestCase
## Encounter triggers (wake, appear, remove), immobile units, and the Emerald Serpent's battles.

const EMERALD := ["emerald_trolls", "emerald_lich", "emerald_statues", "emerald_dragon"]


func _trigger(when: int, effect: int, targets: Array, extra: Dictionary = {}) -> Dictionary:
	var t := {"when": when, "round": 2, "watch": "e0", "effect": effect, "targets": targets, "message": "", "done": false}
	t.merge(extra, true)
	return t


func test_a_dormant_enemy_does_nothing_until_a_round_trigger_wakes_it() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e0", V(5, 1)), Fx.enemy("e1", V(5, 2))])
	b.state.get_c("e1").dormant = true
	b.triggers.append(_trigger(EncounterTrigger.When.ROUND_REACHED, EncounterTrigger.Effect.WAKE, ["e1"], {"message": "It stirs."}))
	assert_true(not b.state.get_c("e1").is_active(1), "asleep in round one")
	assert_true(b.state.get_c("e1").is_present(), "but it is on the field, and a target")
	Fx.run_round(b)
	assert_eq(b.state.round_number, 2)
	assert_true(not b.state.get_c("e1").dormant, "awake when round two begins")
	assert_true(b.state.get_c("e1").is_active(2))
	assert_true(Fx.has_event(b, "wake") and Fx.has_event(b, "trigger"))
	assert_true(b.snapshot_for("a")["units"].size() >= 2)


func test_an_enemy_in_reserve_arrives_when_another_falls_and_the_fight_goes_on() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("boss", V(5, 1), {"hp": 4}), Fx.enemy("next", V(5, 2))])
	b.state.get_c("next").in_reserve = true
	b.triggers.append(_trigger(EncounterTrigger.When.ENEMY_DEFEATED, EncounterTrigger.Effect.APPEAR, ["next"], {"watch": "boss"}))
	assert_true(not b.state.get_c("next").is_present())
	for u: Dictionary in b.snapshot_for("a")["units"]:
		assert_true(u["id"] != "next", "nobody sees an enemy that has not arrived")
	assert_eq(b.check_victory(), Enums.Outcome.NONE, "an enemy still to come keeps the fight on")
	b.state.get_c("boss").life_state = Enums.LifeState.ELIMINATED
	b.state.get_c("boss").hp = 0
	b._run_triggers()
	assert_true(b.state.get_c("next").is_present(), "it arrives the moment the boss falls")
	assert_eq(b.check_victory(), Enums.Outcome.NONE)
	b.state.get_c("next").life_state = Enums.LifeState.ELIMINATED
	assert_eq(b.check_victory(), Enums.Outcome.PLAYERS_WIN)


func test_an_arrival_takes_the_nearest_free_tile_when_its_own_is_taken() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(5, 2)), Fx.enemy("e0", V(0, 0)), Fx.enemy("e1", V(5, 2))])
	b.state.get_c("e1").in_reserve = true
	b.triggers.append(_trigger(EncounterTrigger.When.ROUND_REACHED, EncounterTrigger.Effect.APPEAR, ["e1"], {"round": 1}))
	b._run_triggers()
	var cell := b.state.get_c("e1").cell
	assert_true(cell != V(5, 2) and Enums.manhattan(cell, V(5, 2)) == 1, "stands beside the player, not on them")


func test_a_remove_trigger_takes_an_enemy_off_the_field() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e0", V(5, 1)), Fx.enemy("tail", V(3, 3))])
	b.triggers.append(_trigger(EncounterTrigger.When.ENEMY_DEFEATED, EncounterTrigger.Effect.REMOVE, ["tail"]))
	b.state.get_c("e0").life_state = Enums.LifeState.ELIMINATED
	b._run_triggers()
	assert_eq(b.state.get_c("tail").life_state, Enums.LifeState.ELIMINATED)
	assert_eq(b.check_victory(), Enums.Outcome.PLAYERS_WIN, "nothing is left to beat once the boss and its tail are gone")


func test_a_trigger_fires_once() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e0", V(5, 1))])
	b.triggers.append(_trigger(EncounterTrigger.When.ROUND_REACHED, EncounterTrigger.Effect.WAKE, ["e0"], {"round": 1, "message": "Once."}))
	b._run_triggers()
	b._run_triggers()
	var n := 0
	for e in b.events:
		if e["type"] == "trigger":
			n += 1
	assert_eq(n, 1)


func test_an_immobile_unit_cannot_plan_a_walk_and_only_attacks_what_is_in_reach() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(6, 3)), Fx.enemy("boss", V(1, 1), {"skills": ["move", "strike"], "agi": 6})])
	var boss := b.state.get_c("boss")
	boss.immobile = true
	var walk: Array[PlannedAction] = [PlannedAction.from_dict(Fx.move([V(2, 1)]))]
	assert_true(not PlanValidator.validate(b, boss, walk)["ok"], "cannot walk")
	assert_true(AiPlanner.new().plan_for(b, boss).is_empty(), "nobody in reach: it stays put and plans nothing")
	b.state.get_c("a").cell = V(2, 1)
	var plan := AiPlanner.new().plan_for(b, boss)
	assert_eq(plan.size(), 1, "someone beside it: it strikes without moving")
	assert_eq(plan[0].skill_id, "strike")


func test_trigger_mistakes_are_reported() -> void:
	var t := EncounterTrigger.new()
	assert_true(not t.problems(3).is_empty(), "no targets")
	t.targets = PackedInt32Array([5])
	assert_true(not t.problems(3).is_empty(), "a target that does not exist")
	t.targets = PackedInt32Array([1])
	assert_true(t.problems(3).is_empty())
	t.when = EncounterTrigger.When.ENEMY_DEFEATED
	t.enemy = 1
	assert_true(not t.problems(3).is_empty(), "waking the enemy it watches")
	t.effect = EncounterTrigger.Effect.REMOVE
	assert_true(t.problems(3).is_empty(), "removing the one that fell is fine")
	t.enemy = 9
	assert_true(not t.problems(3).is_empty(), "a watched enemy that does not exist")


func test_the_emerald_serpent_battles_are_sound_and_start_as_designed() -> void:
	var cfg := GameConfig.load_file()
	var skills := SkillDb.load_file()
	for id: String in EMERALD:
		var def := Encounter.load_definition(id)
		assert_true(def != null, "%s exists" % id)
		if def == null:
			continue
		assert_eq(def.problems(skills), [] as Array[String], id)
		assert_true(def.max_players() >= 4, "%s seats a full party" % id)
		var b := Encounter.build(cfg, skills, 4, 3, ["warrior", "hunter", "mage", "warrior"], def)
		assert_eq(b.state.team_members(Enums.Team.ENEMIES).size(), def.enemies.size())
		for c in b.state.combatants.values():
			var bf := b.bf
			assert_true(not bf.is_blocked((c as Combatant).cell), "%s: %s starts on open ground" % [id, c.id])
	var trolls := Encounter.build(cfg, skills, 4, 3, [], Encounter.load_definition("emerald_trolls"))
	assert_eq(trolls.state.team_members(Enums.Team.ENEMIES).size(), 4)
	var statues := Encounter.build(cfg, skills, 4, 3, [], Encounter.load_definition("emerald_statues"))
	for c in statues.state.team_members(Enums.Team.ENEMIES):
		assert_true(c.dormant, "all six wolves are stone to begin with")
	Fx.run_round(statues)
	for c in statues.state.team_members(Enums.Team.ENEMIES):
		assert_true(not c.dormant, "and awake in round two")
	var dragon := Encounter.build(cfg, skills, 4, 3, [], Encounter.load_definition("emerald_dragon"))
	assert_true(dragon.state.get_c("e0").immobile and dragon.state.get_c("e1").immobile, "the dragon and its tail are rooted")
	assert_true(dragon.state.get_c("e2").in_reserve, "the leshen is not there yet")
	dragon.state.get_c("e0").life_state = Enums.LifeState.ELIMINATED
	dragon._run_triggers()
	assert_true(dragon.state.get_c("e2").is_present(), "the leshen arrives when the dragon falls")
	assert_eq(dragon.state.get_c("e1").life_state, Enums.LifeState.ELIMINATED, "and the tail goes limp")
