extends TestCase
## Items: consumables whose use is a skill. The items here are test fixtures; none ship with the game.


func _item(id: String, targeting: int, effects: Array, area: AreaShape = null, attack_range: int = 4) -> ItemDef:
	var sk := SkillDef.new()
	sk.kind = Enums.SkillKind.SUPPORT
	sk.targeting = targeting
	sk.attack_range = attack_range
	sk.speed = 5
	sk.area = area
	var st := SkillStage.new()
	var list: Array[SkillEffect] = []
	for e: SkillEffect in effects:
		list.append(e)
	st.effects = list
	var stages: Array[SkillStage] = [st]
	sk.stage_defs = stages
	var it := ItemDef.new()
	it.id = id
	it.display_name = id.capitalize()
	it.hint = "a test " + id
	it.use = sk
	return it


func _heal(n: int) -> HealEffect:
	var h := HealEffect.new()
	h.amount = n
	return h


func _bomb_effect() -> DamageEffect:
	var d := DamageEffect.new()
	d.base = 6
	d.can_crit = false
	return d


## A duel where the player carries `carry` and the SkillDb knows a heal potion and an area bomb.
func _battle(carry: Dictionary) -> Battle:
	var b := Fx.battle(Fx.OPEN, [Fx.player("p", V(1, 1), {"hp": 30, "cur_hp": 10}), Fx.enemy("e", V(3, 1), {"hp": 30})])
	b.skills.add_item(_item("potion", Enums.Targeting.CHARACTER, [_heal(8)]))
	var radius := AreaShape.new()
	radius.shape = AreaShape.Shape.RADIUS
	radius.size = 1
	b.skills.add_item(_item("bomb", Enums.Targeting.TILE, [_bomb_effect()], radius))
	b.state.get_c("p").items = carry
	return b


func test_an_action_can_name_an_item() -> void:
	var a := PlannedAction.from_dict({"item": "potion", "target": "p"})
	assert_eq(a.item_id, "potion")
	assert_eq(a.skill_id, "item:potion")
	assert_eq(a.to_dict()["item"], "potion")
	assert_true(PlannedAction.from_dict({"item": 5}) == null)
	assert_true(PlannedAction.from_dict({"item": ""}) == null)
	assert_true(PlannedAction.from_dict({"skill": "strike"}).item_id == "")


func test_the_plan_checks_how_many_copies_you_carry() -> void:
	var b := _battle({"potion": 2})
	var use := {"item": "potion", "target": "p"}
	assert_true(b.submit_plan("p", [use, use])["ok"])
	assert_true(not b.submit_plan("p", [use, use, use])["ok"], "three potions with two in the bag")
	assert_true(not b.submit_plan("p", [{"item": "bomb", "cell": V(3, 1)}])["ok"], "not carried")
	assert_true(not b.submit_plan("p", [{"item": "nonsense", "target": "p"}])["ok"], "not an item")
	assert_true(not b.submit_plan("p", [{"skill": "item:potion", "target": "p"}])["ok"], "an item skill is not one of your skills")


func test_using_an_item_runs_its_skill_and_uses_up_a_copy() -> void:
	var b := _battle({"potion": 2})
	Fx.plan(b, "p", [{"item": "potion", "target": "p"}])
	Fx.run_round(b)
	var p := b.state.get_c("p")
	assert_eq(p.hp, 18)
	assert_eq(p.items_used, {"potion": 1})
	assert_eq(b.snapshot_for("p")["units"][0]["items"][0]["count"], 1, "one copy left to show")


func test_two_copies_can_be_used_in_one_round() -> void:
	var b := _battle({"potion": 2})
	var use := {"item": "potion", "target": "p"}
	Fx.plan(b, "p", [use, use])
	Fx.run_round(b)
	assert_eq(b.state.get_c("p").hp, 26, "no once-per-turn limit on items")
	assert_eq(b.state.get_c("p").items_used, {"potion": 2})


func test_a_skipped_item_is_not_used_up() -> void:
	var b := _battle({"potion": 1})
	Fx.plan(b, "p", [{"item": "potion", "target": "e"}])
	b.state.get_c("e").cell = V(7, 3) # far away by the time the item's turn comes
	b.begin_resolution()
	Fx.run_beats(b, 1)
	assert_true(Fx.has_event(b, "skip"))
	assert_eq(b.state.get_c("p").items_used, {})


func test_an_item_with_an_area_hits_everyone_in_it() -> void:
	var b := _battle({"bomb": 1})
	var e := b.state.get_c("e")
	Fx.plan(b, "p", [{"item": "bomb", "cell": e.cell}])
	Fx.run_round(b)
	assert_eq(e.hp, 24)
	assert_eq(b.state.get_c("p").items_used, {"bomb": 1})


func test_a_battle_never_lends_out_more_than_you_carried() -> void:
	var b := _battle({"potion": 1})
	b.state.get_c("p").items_used = {"potion": 1}
	var r := b.submit_plan("p", [{"item": "potion", "target": "p"}])
	assert_true(not r["ok"], "used up earlier in the battle")


func test_only_you_see_your_items_and_enemies_have_none() -> void:
	var b := _battle({"potion": 1})
	for u: Dictionary in b.snapshot_for("p")["units"]:
		assert_eq(u.has("items"), u["id"] == "p")
	assert_true(b.state.get_c("e").items.is_empty())


func test_item_definitions_are_checked_and_the_shipped_set_is_valid() -> void:
	var it := _item("ok", Enums.Targeting.CHARACTER, [_heal(1)])
	assert_true(it.problems().is_empty(), str(it.problems()))
	it.id = "Bad Id"
	assert_true(not it.problems().is_empty())
	var empty := ItemDef.new()
	assert_true(not empty.problems().is_empty())
	var bad := _item("bad", Enums.Targeting.CHARACTER, [_heal(1)])
	bad.use.kind = Enums.SkillKind.MOVE
	assert_true(not bad.problems().is_empty(), "a move cannot be an item")
	var set := load(SkillDb.ITEMS_PATH) as ItemSet
	assert_true(set.problems().is_empty())


func test_each_skill_db_has_its_own_items() -> void:
	var one := SkillDb.load_file()
	var two := SkillDb.load_file()
	one.add_item(_item("potion", Enums.Targeting.CHARACTER, [_heal(1)]))
	assert_true(one.get_skill("item:potion") != null)
	assert_true(two.get_skill("item:potion") == null)
	assert_eq(one.get_skill("item:potion").frequency, Enums.Frequency.UNLIMITED)


func test_the_server_takes_at_most_the_battle_slots_of_known_items() -> void:
	var app: Node = (load("res://game/server/server_app.gd") as GDScript).new()
	var cfg := GameConfig.load_file()
	cfg.data["items"]["battle_slots"] = 2
	var db := SkillDb.load_file()
	for id in ["a", "b", "c"]:
		db.add_item(_item(id, Enums.Targeting.SELF, [_heal(1)]))
	app.set("cfg", cfg)
	app.set("skills", db)
	var got: Dictionary = app.call("_loadout", {"items": [{"item_id": "a", "quantity": 2}, {"item_id": "ghost", "quantity": 9},
		{"item_id": "b", "quantity": 1}, {"item_id": "c", "quantity": 3}]})
	assert_eq(got, {"a": 2, "b": 1}, "unknown items are ignored and only two kinds go in")
	assert_eq(app.call("_loadout", {}), {})
	app.free()
