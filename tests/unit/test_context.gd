extends TestCase
## Map objects and their context actions. The chest, door and trap here are test fixtures; none ship with the game.


func _skill(effects: Array, ap: int = 1, speed: int = 5) -> SkillDef:
	var sk := SkillDef.new()
	sk.speed = speed
	var st := SkillStage.new()
	st.ap = ap
	var list: Array[SkillEffect] = []
	for e: SkillEffect in effects:
		list.append(e)
	st.effects = list
	var stages: Array[SkillStage] = [st]
	sk.stage_defs = stages
	return sk


func _action(id: String, requires: String, sets: String, effects: Array = [], ap: int = 1, speed: int = 5) -> ContextAction:
	var a := ContextAction.new()
	a.id = id
	a.display_name = id.capitalize()
	a.requires_state = requires
	a.sets_state = sets
	a.use = _skill(effects, ap, speed)
	return a


func _def(id: String, initial: String, blocking: Array[String], actions: Array[ContextAction], reach: int = 1) -> ContextObjectDef:
	var d := ContextObjectDef.new()
	d.id = id
	d.display_name = id.capitalize()
	d.initial_state = initial
	d.blocking_states = blocking
	d.actions = actions
	d.reach = reach
	return d


func _grant(item: String, n: int) -> GrantItemEffect:
	var g := GrantItemEffect.new()
	g.item_id = item
	g.count = n
	return g


func _flag(name: String) -> SetFlagEffect:
	var f := SetFlagEffect.new()
	f.flag = name
	return f


func _hurt(n: int) -> DamageEffect:
	var d := DamageEffect.new()
	d.base = n
	d.uses_power = false
	d.can_miss = false
	d.can_crit = false
	return d


func _chest() -> ContextObjectDef:
	return _def("chest", "closed", ["closed", "open"] as Array[String],
		[_action("open", "closed", "open", [_grant("potion", 2), _flag("opened_chest")], 2)] as Array[ContextAction])


func _door() -> ContextObjectDef:
	return _def("door", "closed", ["closed"] as Array[String], [_action("pull", "closed", "open"), _action("shut", "open", "closed")] as Array[ContextAction])


func _trap() -> ContextObjectDef:
	return _def("trap", "armed", [] as Array[String], [_action("disarm", "armed", "disarmed"), _action("trigger", "armed", "sprung", [_hurt(7)])] as Array[ContextAction])


func _potion() -> ItemDef:
	var it := ItemDef.new()
	it.id = "potion"
	it.display_name = "Potion"
	var heal := HealEffect.new()
	heal.amount = 5
	var sk := _skill([heal])
	sk.kind = Enums.SkillKind.SUPPORT
	sk.targeting = Enums.Targeting.SELF
	it.use = sk
	it.max_stack = 3
	return it


func _battle(units: Array = []) -> Battle:
	if units.is_empty():
		units = [Fx.player("p", V(1, 1)), Fx.enemy("e", V(7, 3))]
	var b := Fx.battle(Fx.OPEN, units)
	b.skills.add_item(_potion())
	return b


func _use(object_id: String, action_id: String) -> Dictionary:
	return {"object": object_id, "action": action_id}


func test_an_action_can_name_an_object() -> void:
	var a := PlannedAction.from_dict(_use("chest_1", "open"))
	assert_eq([a.object_id, a.action_id, a.skill_id], ["chest_1", "open", "ctx:chest_1:open"])
	assert_eq(a.to_dict()["object"], "chest_1")
	for bad in [{"object": 5, "action": "open"}, {"object": "x", "action": ""}, {"object": "a b", "action": "x"},
			{"object": "x"}, {"object": "x".repeat(41), "action": "y"}]:
		assert_true(PlannedAction.from_dict(bad) == null, str(bad))


func test_planning_checks_reach_and_state() -> void:
	var b := _battle()
	b.add_object(_chest(), "chest", V(2, 1))
	b.add_object(_chest(), "far", V(6, 0))
	assert_true(b.submit_plan("p", [_use("chest", "open")])["ok"])
	assert_true(not b.submit_plan("p", [_use("far", "open")])["ok"], "out of reach")
	assert_true(not b.submit_plan("p", [_use("chest", "nope")])["ok"], "unknown action")
	assert_true(not b.submit_plan("p", [_use("ghost", "open")])["ok"], "unknown object")
	assert_true(not b.submit_plan("p", [_use("chest", "open"), _use("chest", "open")])["ok"], "already open after the first")
	assert_true(not b.submit_plan("p", [{"skill": "ctx:chest:open"}])["ok"], "not a skill of yours")


func test_reach_follows_where_the_unit_will_stand() -> void:
	var b := _battle()
	b.add_object(_chest(), "far", V(6, 1))
	var walk := b.submit_plan("p", [Fx.move([V(2, 1), V(3, 1)]), _use("far", "open")])
	assert_true(not walk["ok"], "still two tiles away")


func test_a_chest_gives_items_and_flags_once_and_costs_its_ap() -> void:
	var b := _battle()
	b.add_object(_chest(), "chest", V(2, 1))
	var costs: Array = PlanValidator.validate(b, b.state.get_c("p"), [PlannedAction.from_dict(_use("chest", "open"))] as Array[PlannedAction])["costs"]
	assert_eq(costs, [2])
	Fx.plan(b, "p", [_use("chest", "open")])
	Fx.run_round(b)
	var p := b.state.get_c("p")
	assert_eq(p.items, {"potion": 2})
	assert_eq(p.items_gained, {"potion": 2})
	assert_eq(p.flags_gained, ["opened_chest"] as Array[String])
	assert_eq(b.objects["chest"].state, "open")
	assert_eq(p.facing, Enums.Facing.EAST, "turns to the object")


func test_a_second_unit_loses_the_race_when_the_state_changed() -> void:
	var b := _battle([Fx.player("p", V(1, 1)), Fx.player("q", V(3, 1)), Fx.enemy("e", V(7, 3))])
	b.add_object(_chest(), "chest", V(2, 1))
	Fx.plan(b, "p", [_use("chest", "open")])
	Fx.plan(b, "q", [_use("chest", "open")])
	Fx.run_round(b)
	var got := int(b.state.get_c("p").items_gained.get("potion", 0)) + int(b.state.get_c("q").items_gained.get("potion", 0))
	assert_eq(got, 2, "only one of them opened it")
	assert_true(Fx.has_event(b, "skip"), "the other action was skipped")


func test_items_gained_respect_the_item_limit() -> void:
	var b := _battle()
	b.state.get_c("p").items = {"potion": 2}
	b.add_object(_chest(), "chest", V(2, 1))
	Fx.plan(b, "p", [_use("chest", "open")])
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").items, {"potion": 3}, "max stack is 3")
	assert_eq(b.state.get_c("p").items_gained, {"potion": 1})


func test_a_closed_door_blocks_walking_and_opening_it_clears_the_way() -> void:
	var b := _battle()
	b.add_object(_door(), "door", V(2, 1))
	assert_true(b.bf.is_blocked(V(2, 1)))
	assert_true(not b.submit_plan("p", [Fx.move([V(2, 1)])])["ok"], "cannot walk into a closed door")
	Fx.plan(b, "p", [_use("door", "pull")])
	Fx.run_round(b)
	assert_true(not b.bf.is_blocked(V(2, 1)))
	assert_true(b.submit_plan("p", [Fx.move([V(2, 1)])])["ok"])


func test_state_changes_inside_one_plan_can_be_chained() -> void:
	var b := _battle()
	b.add_object(_door(), "door", V(2, 1))
	assert_true(b.submit_plan("p", [_use("door", "pull"), _use("door", "shut")])["ok"], "pull then shut: valid in sequence")
	assert_true(not b.submit_plan("p", [_use("door", "shut")])["ok"], "shut needs it open first")


func test_a_trap_can_hurt_the_one_who_triggers_it() -> void:
	var b := _battle()
	b.add_object(_trap(), "trap", V(2, 1))
	Fx.plan(b, "p", [_use("trap", "trigger")])
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").hp, 20 - 7)
	assert_eq(b.objects["trap"].state, "sprung")


func test_an_enemy_cannot_use_objects_through_a_plan_it_does_not_have() -> void:
	var b := _battle()
	b.add_object(_chest(), "chest", V(2, 1))
	assert_true(b.state.get_c("e").skills.size() >= 0)
	assert_eq(b.snapshot_for("p")["objects"][0]["actions"].size(), 1, "the snapshot lists what the object offers now")
	Fx.plan(b, "p", [_use("chest", "open")])
	Fx.run_round(b)
	var view: Dictionary = b.snapshot_for("p")["objects"][0]
	assert_eq([view["state"], view["blocks"], view["actions"].size()], ["open", true, 0])


func test_object_skills_are_registered_and_defs_are_checked() -> void:
	var b := _battle()
	b.add_object(_chest(), "chest", V(2, 1))
	var sk := b.skills.get_skill("ctx:chest:open")
	assert_true(sk != null and sk.total_ap() == 2 and sk.targeting == Enums.Targeting.SELF)
	assert_eq(_chest().problems(), [] as Array[String])
	assert_eq(_door().problems(), [] as Array[String])
	assert_eq(_trap().problems(), [] as Array[String])
	var bad := _chest()
	bad.actions[0].requires_state = "locked"
	bad.actions[0].use = null
	assert_true(str(bad.problems()).contains("use"))
	var empty := ContextObjectDef.new()
	assert_true(empty.problems().size() >= 3)
	var flag := _flag("Bad Flag")
	assert_true(flag.problems().size() == 1)
	assert_true(_grant("", 1).problems().size() == 1)


func test_map_objects_are_read_from_the_scene() -> void:
	var lib := MeshLibrary.new()
	lib.create_item(0)
	lib.set_item_name(0, "ground")
	var root := Node3D.new()
	var gm := GridMap.new()
	gm.name = "Terrain"
	gm.mesh_library = lib
	root.add_child(gm)
	for x in 4:
		gm.set_cell_item(Vector3i(x, 0, 0), 0)
	var objs := Node3D.new()
	objs.name = "Objects"
	root.add_child(objs)
	var m := MapObject.new()
	m.name = "chest_a"
	m.def = _chest()
	m.position = gm.map_to_local(Vector3i(2, 0, 0))
	objs.add_child(m)
	var def := MapDef.from_node(root)
	assert_eq(def.error, "")
	assert_eq(def.objects.size(), 1)
	assert_eq([def.objects[0]["id"], def.objects[0]["cell"]], ["chest_a", V(2, 0)])
	m.name = "Chest A"
	assert_true(MapDef.from_node(root).error.contains("lower-case"))
	m.name = "chest_a"
	m.def = null
	assert_true(MapDef.from_node(root).error.contains("definition"))
	root.free()
