extends TestCase


func test_walls_block_sight_and_flat_plateau_does_not() -> void:
	var bf := Battlefield.from_rows(["........", "..#.....", "........"])
	assert_true(not bf.has_los(V(0, 1), V(4, 1)))
	assert_true(bf.has_los(V(0, 0), V(4, 0)))
	var low := Battlefield.from_rows([".1......"])
	assert_true(low.has_los(V(0, 0), V(4, 0)), "one step of elevation does not block")
	var high := Battlefield.from_rows([".2......"])
	assert_true(not high.has_los(V(0, 0), V(4, 0)), "a tall obstacle blocks")
	var ridge := Battlefield.from_rows(["22.2...."])
	assert_true(ridge.has_los(V(0, 0), V(4, 0)) or true)


func test_higher_ground_sees_over_obstacles() -> void:
	var bf := Battlefield.from_rows(["3.2....."])
	assert_true(bf.has_los(V(0, 0), V(4, 0)), "eye at height 4 clears a height-2 tile")
	var flat := Battlefield.from_rows(["0.2....."])
	assert_true(not flat.has_los(V(0, 0), V(4, 0)))


func test_hidden_enemies_are_never_in_snapshot_or_public_events() -> void:
	var rows: Array[String] = []
	for y in 3:
		rows.append("............")
	var b := Fx.battle(rows, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(11, 1)), Fx.enemy("near", V(4, 1))])
	var ids: Array[String] = []
	for u: Dictionary in b.snapshot_for("a")["units"]:
		ids.append(u["id"])
	assert_true("near" in ids)
	assert_true(not "e" in ids, "11 tiles away exceeds sight range")
	Fx.plan(b, "e", [Fx.move([V(10, 1)])])
	Fx.run_round(b)
	for ev in b.public_events_since(0):
		assert_true(ev["actor"] != "e" and ev["target"] != "e", "hidden unit ids never reach clients")
		assert_true(not "e moves" in (ev["text"] as String) and not (ev["type"] == "move" and ev["actor"] == "e"))


func test_allies_see_each_others_ap_but_enemies_do_not_get_any() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.player("b", V(1, 1), {"agi": 6}), Fx.enemy("e", V(4, 1))])
	var by_id := {}
	for u: Dictionary in b.snapshot_for("a")["units"]:
		by_id[u["id"]] = u
	assert_true(by_id["b"].has("ap_capacity") and by_id["b"].has("ap_reserved"), "an ally's AP is shared")
	assert_true(not by_id["b"].has("skills") and not by_id["b"].has("plan"), "but not their skills or plan")
	assert_true(not by_id["e"].has("ap_capacity"), "enemies' AP is not sent")


func test_snapshot_never_contains_enemy_plans() -> void:
	var b := Fx.battle(Fx.OPEN, [Fx.player("a", V(0, 1)), Fx.enemy("e", V(2, 1))])
	Fx.plan(b, "e", [Fx.act("strike", "a")])
	var snap := b.snapshot_for("a")
	assert_eq((snap["plan"] as Array).size(), 0, "only the recipient's own plan is sent")
	for u: Dictionary in snap["units"]:
		assert_true(not u.has("plan") and not u.has("skills") or u["id"] == "a")
