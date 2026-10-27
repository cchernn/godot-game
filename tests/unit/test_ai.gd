extends TestCase


func _sig(b: Battle) -> String:
	var parts: Array[String] = []
	for c in b.state.team_members(Enums.Team.ENEMIES):
		for a in c.plan:
			parts.append("%s:%s:%s:%s" % [c.id, a.skill_id, a.path, a.target_id])
	return "|".join(parts)


func test_ai_plans_are_deterministic_and_committed_through_the_validator() -> void:
	var cfg := GameConfig.load_file()
	var skills := SkillDb.load_file()
	var b1 := Encounter.build(cfg, skills, 3, 5)
	var b2 := Encounter.build(cfg, skills, 3, 5)
	assert_eq(_sig(b1), _sig(b2))
	for c in b1.state.team_members(Enums.Team.ENEMIES):
		assert_true(c.ready, "AI plans and readies like a player")


func test_ai_attacks_a_reachable_target_using_the_same_rules() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(3, 1)), Fx.enemy("e", V(6, 1), {"skills": ["move", "strike"], "agi": 6})])
	b.ai_enabled = true
	b.state.get_c("e").plan = AiPlanner.new().plan_for(b, b.state.get_c("e"))
	var skills_planned: Array[String] = []
	for a in b.state.get_c("e").plan:
		skills_planned.append(a.skill_id)
	assert_eq(skills_planned, ["move", "strike"], "closes in and strikes within its AP")
	assert_true(PlanValidator.validate(b, b.state.get_c("e"), b.state.get_c("e").plan)["ok"])


func test_ai_prefers_finishing_a_downed_target() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("healthy", V(3, 0)), Fx.player("down", V(3, 2), {"cur_hp": 1}),
		Fx.enemy("e", V(4, 1), {"skills": ["move", "strike"]})])
	b.state.get_c("down").life_state = Enums.LifeState.DOWNED
	var plan := AiPlanner.new().plan_for(b, b.state.get_c("e"))
	assert_eq(plan.back().target_id, "down")


func test_full_ai_vs_idle_players_runs_without_breaking_rules() -> void:
	var cfg := GameConfig.load_file()
	var b := Encounter.build(cfg, SkillDb.load_file(), 3, 11)
	for i in 8:
		if b.state.phase == Enums.RoundPhase.FINISHED:
			break
		Fx.run_round(b)
		for c: Combatant in b.state.combatants.values():
			assert_true(c.ap_spent <= c.ap_capacity and c.ap_reserved >= 0)
			assert_true(c.hp >= 0 and c.hp <= c.max_hp)
	var damaged := false
	for c in b.state.team_members(Enums.Team.PLAYERS):
		damaged = damaged or c.hp < c.max_hp
	assert_true(damaged, "the enemy group engages idle players within 8 rounds")
	assert_true(b.outcome != Enums.Outcome.PLAYERS_WIN)
