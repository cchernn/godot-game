extends TestCase

const BOARD := "res://game/content/board/board_3d.tscn"


func _board() -> Board3D:
	var root := (Engine.get_main_loop() as SceneTree).root
	var b := (load(BOARD) as PackedScene).instantiate() as Board3D
	root.add_child(b)
	return b


func _snap() -> Dictionary:
	var battle := Encounter.build(GameConfig.load_file(), SkillDb.load_file(), 4, 1)
	return battle.snapshot_for("pc0")


func _finish_camera(b: Board3D) -> void:
	b.camera_rig._snap_to_targets()


func test_board_draws_the_painted_map_and_the_units() -> void:
	var b := _board()
	var snap := _snap()
	b.set_snapshot(snap)
	assert_true(b._gm != null and b._gm.get_used_cells().size() > 80, "map blocks were created")
	assert_eq(b._unit_nodes.size(), (snap["units"] as Array).size())
	assert_true(absf(b.cell_surface(V(0, 0)).y - 0.5) < 0.001, "flat tile top is one block high")
	assert_true(absf(b.cell_surface(V(8, 2)).y - 1.0) < 0.001, "raised tile is one block higher")
	b.free()


func test_unknown_or_hostile_map_id_falls_back_to_the_servers_layout() -> void:
	for bad in ["no_such_map", "../../etc/passwd", ""]:
		var b := _board()
		var snap := _snap()
		snap["map"]["id"] = bad
		b.set_snapshot(snap)
		assert_true(b._gm != null and b._gm.get_used_cells().size() > 80, "fallback map for '%s'" % bad)
		var top := b._top.get(V(2, 5), -1) as int
		assert_eq(top, 3, "wall column built from terrain arrays")
		b.free()


func test_a_map_that_disagrees_with_the_server_is_not_trusted() -> void:
	var b := _board()
	var snap := _snap()
	(snap["map"]["elev"] as Array)[0] = 3
	b.set_snapshot(snap)
	assert_eq(b._top.get(V(0, 0), -1), 3, "drawn from the server's data")
	b.free()


func test_clicks_pick_the_tile_under_the_ray_from_every_side() -> void:
	var b := _board()
	b.set_snapshot(_snap())
	for yaw in [45.0, 135.0, 225.0, 315.0]:
		b.camera_rig.yaw_deg = yaw
		_finish_camera(b)
		var cam := b.camera_rig.camera
		for cell: Vector2i in [V(0, 0), V(9, 7), V(4, 4)]:
			var target := b.cell_surface(cell)
			var hit := b.pick_ray(cam.global_position, (target - cam.global_position).normalized())
			assert_eq(hit.get("cell", V(-1, -1)), cell, "yaw %d cell %s" % [yaw, str(cell)])
	b.free()


func test_clicking_a_unit_picks_the_unit() -> void:
	var b := _board()
	b.set_snapshot(_snap())
	_finish_camera(b)
	var cam := b.camera_rig.camera
	var node: Unit3D = b._unit_nodes["pc1"]
	var aim := node.global_position + Vector3(0, node.pick_height, 0)
	var hit := b.pick_ray(cam.global_position, (aim - cam.global_position).normalized())
	assert_eq(hit.get("unit", ""), "pc1")
	assert_eq(hit.get("cell", V(-1, -1)), V(0, 3))
	b.free()


func test_overlays_follow_the_plan_and_fog() -> void:
	var b := _board()
	var snap := _snap()
	b.set_snapshot(snap)
	b._process(0.0)
	var fogged := 0
	for mi: MeshInstance3D in b._overlays["fog"]:
		if mi.visible:
			fogged += 1
	assert_true(fogged > 0 and fogged < 80, "some tiles are unseen")
	b.plan_cells = [V(1, 2), V(2, 2)] as Array[Vector2i]
	b.plan_marks = [V(3, 3)] as Array[Vector2i]
	b._process(0.0)
	var moves := 0
	for mi: MeshInstance3D in b._overlays["move"]:
		if mi.visible:
			moves += 1
	assert_eq(moves, 2)
	b.plan_cells = [] as Array[Vector2i]
	b._process(0.0)
	moves = 0
	for mi: MeshInstance3D in b._overlays["move"]:
		if mi.visible:
			moves += 1
	assert_eq(moves, 0)
	b.free()


func test_units_glide_towards_their_cell() -> void:
	var b := _board()
	var snap := _snap()
	b.set_snapshot(snap)
	var start: Vector3 = (b._unit_nodes["pc0"] as Unit3D).position
	for u: Dictionary in snap["units"]:
		if u["id"] == "pc0":
			u["cell"] = V(3, 2)
	b.set_snapshot(snap)
	b._process(0.1)
	var mid: Vector3 = (b._unit_nodes["pc0"] as Unit3D).position
	assert_true(mid.x > start.x and mid.x < 3.5, "moved part of the way")
	b.free()
