extends TestCase
## Areas of effect: shapes, walls, friendly fire, following a moving target, ordering. The skills here are fixtures.

const BIG: Array = [".........", ".........", ".........", ".........", ".........", ".........", "........."]


func _area(shape: int, size: int, los: bool = true) -> AreaShape:
	var a := AreaShape.new()
	a.shape = shape as AreaShape.Shape
	a.size = size
	a.requires_los = los
	return a


func _skill(b: Battle, id: String, targeting: int, area: AreaShape, dmg: int = 5, extra: Array = []) -> void:
	var sk := SkillDef.new()
	sk.id = id
	sk.display_name = id.capitalize()
	sk.kind = Enums.SkillKind.ATTACK
	sk.targeting = targeting
	sk.attack_range = 6
	sk.speed = 5
	sk.frequency = Enums.Frequency.UNLIMITED
	sk.area = area
	var st := SkillStage.new()
	var d := DamageEffect.new()
	d.base = dmg
	d.can_crit = false # no flanking bonuses: the numbers below are plain
	var list: Array[SkillEffect] = [d]
	for e: SkillEffect in extra:
		list.append(e)
	st.effects = list
	var stages: Array[SkillStage] = [st]
	sk.stage_defs = stages
	b.skills.skills[id] = sk


func _cells(a: AreaShape, bf: Battlefield, caster: Vector2i, centre: Vector2i, facing: int = Enums.Facing.EAST) -> Array:
	var out: Array = a.cells(bf, caster, centre, facing)
	out.sort_custom(func(p: Vector2i, q: Vector2i) -> bool: return p.y < q.y or (p.y == q.y and p.x < q.x))
	return out


func test_radius_covers_a_diamond() -> void:
	var bf := Battlefield.from_rows(BIG)
	var cells := _cells(_area(AreaShape.Shape.RADIUS, 1), bf, V(0, 0), V(4, 3))
	assert_eq(cells, [V(4, 2), V(3, 3), V(4, 3), V(5, 3), V(4, 4)])
	assert_eq(_cells(_area(AreaShape.Shape.RADIUS, 2), bf, V(0, 0), V(4, 3)).size(), 13)


func test_radius_is_cut_by_the_edge_and_by_walls() -> void:
	var bf := Battlefield.from_rows(BIG)
	assert_eq(_cells(_area(AreaShape.Shape.RADIUS, 1), bf, V(0, 0), V(0, 0)).size(), 3)
	var walled := Battlefield.from_rows([".....", "..#..", ".....", ".....", "....."])
	var cells := _cells(_area(AreaShape.Shape.RADIUS, 2), walled, V(0, 4), V(1, 1))
	assert_true(not V(2, 1) in cells, "the wall itself is never covered")
	assert_true(not V(3, 1) in cells, "and it blocks what is behind it")
	var open := _cells(_area(AreaShape.Shape.RADIUS, 2, false), walled, V(0, 4), V(1, 1))
	assert_true(V(3, 1) in open, "unless the area ignores line of sight")


func test_line_runs_from_the_caster_toward_the_aim() -> void:
	var bf := Battlefield.from_rows(BIG)
	var cells := _cells(_area(AreaShape.Shape.LINE, 3), bf, V(1, 3), V(5, 3))
	assert_eq(cells, [V(2, 3), V(3, 3), V(4, 3)])
	assert_eq(_cells(_area(AreaShape.Shape.LINE, 3), bf, V(4, 3), V(4, 0)), [V(4, 0), V(4, 1), V(4, 2)])
	assert_eq(_cells(_area(AreaShape.Shape.LINE, 3), bf, V(1, 3), V(1, 3), Enums.Facing.SOUTH), [V(1, 4), V(1, 5), V(1, 6)], "aimed at the user: their facing")


func test_line_stops_at_a_wall() -> void:
	var bf := Battlefield.from_rows([".......", "...#...", "......."])
	var cells := _cells(_area(AreaShape.Shape.LINE, 5), bf, V(0, 1), V(6, 1))
	assert_eq(cells, [V(1, 1), V(2, 1)])


func test_cone_widens_each_row() -> void:
	var bf := Battlefield.from_rows(BIG)
	var cells := _cells(_area(AreaShape.Shape.CONE, 3), bf, V(1, 3), V(5, 3))
	assert_eq(cells.size(), 1 + 3 + 5)
	assert_true(V(2, 3) in cells and V(4, 1) in cells and V(4, 5) in cells)
	assert_true(not V(2, 2) in cells)


func test_a_tile_area_hits_everyone_in_it_friend_foe_and_self() -> void:
	var b := Fx.battle(BIG, [Fx.player("p", V(3, 3), {"skills": ["boom"], "hp": 30}), Fx.player("ally", V(4, 3), {"hp": 30}),
		Fx.enemy("e1", V(5, 3), {"hp": 30}), Fx.enemy("far", V(8, 6), {"hp": 30})])
	_skill(b, "boom", Enums.Targeting.TILE, _area(AreaShape.Shape.RADIUS, 2))
	b.state.get_c("p").facing = Enums.Facing.SOUTH
	var act := {"skill": "boom", "cell": V(4, 3)}
	var planned := Fx.plan(b, "p", [act])
	assert_true(planned["ok"], str(planned))
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").hp, 25, "the caster is covered too")
	assert_eq(b.state.get_c("ally").hp, 25)
	assert_eq(b.state.get_c("e1").hp, 25)
	assert_eq(b.state.get_c("far").hp, 30)
	assert_true("covers 3 targets" in " ".join(Fx.texts(b)))


func test_a_character_area_follows_the_target() -> void:
	var b := Fx.battle(BIG, [Fx.player("p", V(1, 3), {"skills": ["move", "boom"], "hp": 30}),
		Fx.enemy("e1", V(5, 3), {"hp": 30, "skills": ["move"]}), Fx.enemy("e2", V(5, 4), {"hp": 30, "skills": ["move"]}),
		Fx.enemy("e3", V(8, 0), {"hp": 30, "skills": ["move"]})])
	_skill(b, "boom", Enums.Targeting.CHARACTER, _area(AreaShape.Shape.RADIUS, 1))
	b.skills.get_skill("boom").speed = 1 # slower than the step, so the target has already moved
	Fx.plan(b, "p", [Fx.act("boom", "e1")])
	Fx.plan(b, "e1", [Fx.move([V(6, 3)])]) # steps away; still in range of the skill
	Fx.plan(b, "e2", [])
	Fx.plan(b, "e3", [])
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_eq(b.state.get_c("e1").hp, 25, "the target was hit where it ended up")
	assert_eq(b.state.get_c("e2").hp, 30, "e2 at (5,4) is not next to (6,3)")


func test_a_tile_skill_that_finds_no_one_misses_and_a_wall_shelters() -> void:
	var rows: Array = [".....", ".....", "..#..", ".....", "....."]
	var b := Fx.battle(rows, [Fx.player("p", V(0, 4), {"skills": ["boom"]}), Fx.enemy("e", V(2, 3), {"hp": 30})])
	_skill(b, "boom", Enums.Targeting.TILE, _area(AreaShape.Shape.RADIUS, 2))
	Fx.plan(b, "p", [{"skill": "boom", "cell": V(2, 1)}])
	Fx.run_round(b)
	assert_eq(b.state.get_c("e").hp, 30, "the wall at (2,2) sheltered it")
	assert_true("empty ground" in " ".join(Fx.texts(b)))


func test_each_victim_gets_its_own_roll_in_id_order() -> void:
	var make := func() -> Battle:
		var b := Fx.battle(BIG, [Fx.player("p", V(0, 3), {"skills": ["boom"]}), Fx.enemy("b", V(4, 3), {"hp": 30}),
			Fx.enemy("a", V(4, 4), {"hp": 30}), Fx.enemy("c", V(4, 2), {"hp": 30})], 7)
		b.cfg.data["combat"]["base_hit_chance"] = 0.5
		_skill(b, "boom", Enums.Targeting.TILE, _area(AreaShape.Shape.RADIUS, 1))
		Fx.plan(b, "p", [{"skill": "boom", "cell": V(4, 3)}])
		Fx.run_round(b)
		return b
	var one: Battle = make.call()
	var two: Battle = make.call()
	assert_eq(Fx.texts(one), Fx.texts(two), "the same seed gives the same results")
	var hits: Array[String] = []
	for e in one.events:
		if e["type"] in ["hit", "miss"] and e["target"] != "":
			hits.append(e["target"])
	assert_eq(hits, ["a", "b", "c"], "rolled in id order")


func test_caster_effects_run_once_and_statuses_land_per_victim() -> void:
	var b := Fx.battle(BIG, [Fx.player("p", V(0, 3), {"skills": ["boom"], "hp": 30, "cur_hp": 10}), Fx.enemy("e1", V(4, 3), {"hp": 30}),
		Fx.enemy("e2", V(4, 4), {"hp": 30})])
	var heal := HealEffect.new()
	heal.amount = 3
	heal.on = SkillEffect.On.CASTER
	var st := StatusDef.new()
	st.id = "burn"
	var ap := ApplyStatusEffect.new()
	ap.status = st
	ap.duration_turns = 3
	_skill(b, "boom", Enums.Targeting.TILE, _area(AreaShape.Shape.RADIUS, 1), 5, [heal, ap])
	Fx.plan(b, "p", [{"skill": "boom", "cell": V(4, 3)}])
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").hp, 13, "healed once, not once per victim")
	assert_eq(b.state.get_c("e1").hp, 25)
	assert_eq(b.state.get_c("e2").hp, 25)
	assert_eq(b.state.get_c("e1").statuses.size(), 1, "each victim got the status")
	assert_eq(b.state.get_c("e2").statuses.size(), 1)


func test_self_centred_radius_and_downed_units_inside_the_area() -> void:
	var b := Fx.battle(BIG, [Fx.player("p", V(3, 3), {"skills": ["nova"], "hp": 30}), Fx.enemy("e", V(3, 4), {"hp": 30})])
	_skill(b, "nova", Enums.Targeting.SELF, _area(AreaShape.Shape.RADIUS, 1))
	b.skills.get_skill("nova").kind = Enums.SkillKind.SUPPORT
	Fx.plan(b, "p", [{"skill": "nova"}])
	Fx.run_round(b)
	assert_eq(b.state.get_c("e").hp, 25)
	assert_eq(b.state.get_c("p").hp, 25, "the nova centre is the caster, so it hurts itself")


func test_area_problems() -> void:
	var sk := SkillDef.new()
	sk.id = "x"
	sk.display_name = "X"
	sk.kind = Enums.SkillKind.REVIVE
	sk.targeting = Enums.Targeting.CHARACTER
	sk.area = _area(AreaShape.Shape.RADIUS, 1)
	var st := SkillStage.new()
	var stages: Array[SkillStage] = [st]
	sk.stage_defs = stages
	assert_true(not sk.problems().is_empty(), "a revive cannot have an area")
	assert_true(not SkillDef.new().is_area())


func test_the_ai_counts_players_caught_minus_its_own_side() -> void:
	var b := Fx.battle(BIG, [Fx.player("p", V(6, 3)), Fx.enemy("e", V(2, 3)), Fx.enemy("buddy", V(6, 4))])
	_skill(b, "boom", Enums.Targeting.TILE, _area(AreaShape.Shape.RADIUS, 1))
	var ai := AiPlanner.new()
	var e := b.state.get_c("e")
	var sk := b.skills.get_skill("boom")
	assert_eq(ai._area_net_hits(b, e, sk, V(2, 3), V(6, 3)), 0, "one player, one of its own")
	assert_eq(ai._area_net_hits(b, e, sk, V(2, 3), V(4, 3)), 0, "(4,3) covers no one")
	assert_eq(ai._area_net_hits(b, e, sk, V(2, 3), V(7, 3)), 1, "(7,3) covers only the player")
