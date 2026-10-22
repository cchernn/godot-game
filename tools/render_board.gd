extends SceneTree
## Renders the board to PNGs in render_out/ (opens a real window briefly; needs a GPU, not --headless):
##   scripts/godot.sh --path . --script res://tools/render_board.gd --resolution 1280x720
func _initialize() -> void:
	var scene := load("res://game/client/client_main.tscn") as PackedScene
	var ui := scene.instantiate()
	root.add_child(ui)
	await process_frame
	var board: Board3D = ui.get_node("BoardHolder/Viewport/Board3D")
	var battle := Encounter.build(GameConfig.load_file(), SkillDb.load_file(), 3, 1)
	board.set_snapshot(battle.snapshot_for("pc0"))
	board.plan_cells = [Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2)] as Array[Vector2i]
	board.plan_marks = [Vector2i(8, 3)] as Array[Vector2i]
	board.hover = Vector2i(4, 3)
	for yaw in [45.0, 135.0]:
		board.camera_rig.yaw_deg = yaw
		board.camera_rig._snap_to_targets()
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		img.save_png("res://render_out/board_yaw%d.png" % int(yaw))
		print("saved yaw ", yaw, " size ", img.get_size())
	quit()
