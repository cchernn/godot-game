extends TestCase

const UNITS := ["unit", "warrior", "hunter", "mage", "ghoul", "cultist"]


func _unit_dict(visual: String, team: int, life: int, hp: int) -> Dictionary:
	return {"id": "u1", "name": "Test", "visual": visual, "team": team, "cell": V(1, 1), "facing": Enums.Facing.EAST,
		"hp": hp, "max_hp": 20, "life": life, "ready": true, "active": true}


func test_every_unit_scene_loads_and_can_show_a_unit() -> void:
	var root := (Engine.get_main_loop() as SceneTree).root
	for id in UNITS:
		var scene := load("res://game/content/units/%s.tscn" % id) as PackedScene
		assert_true(scene != null, id)
		var u := scene.instantiate() as Unit3D
		assert_true(u != null, "%s root uses unit_3d.gd" % id)
		root.add_child(u)
		u.apply(_unit_dict(id, Enums.Team.PLAYERS, Enums.LifeState.ALIVE, 10), true)
		assert_eq(u.name_label.text, "Test")
		assert_true(absf(u.hp_fill.scale.x - 0.5) < 0.001, "health bar at half")
		u.apply(_unit_dict(id, Enums.Team.ENEMIES, Enums.LifeState.DOWNED, 0), false)
		assert_true(u.downed)
		u.free()


func test_unit_animations_exist() -> void:
	var u := (load("res://game/content/units/unit.tscn") as PackedScene).instantiate() as Unit3D
	for anim in [u.idle_animation, u.walk_animation, u.downed_animation]:
		assert_true(u.animation_player.has_animation(anim), anim)
	u.free()


func test_the_animation_names_a_unit_plays_can_be_changed_in_the_inspector() -> void:
	var u := (load("res://game/content/units/unit.tscn") as PackedScene).instantiate() as Unit3D
	(Engine.get_main_loop() as SceneTree).root.add_child(u)
	u.animation_player.get_animation_library("").rename_animation("downed", "Death_A") # as an imported model would name it
	u.downed_animation = &"Death_A"
	u.apply(_unit_dict("x", Enums.Team.ENEMIES, Enums.LifeState.DOWNED, 0), false)
	assert_eq(String(u.animation_player.current_animation), "Death_A")
	u.queue_free()


func test_visuals_resource_maps_ids_to_scenes_with_a_default() -> void:
	var v := load("res://game/content/units/unit_visuals.tres") as UnitVisuals
	assert_true(v.default_scene != null)
	for id in UNITS.slice(1):
		assert_true(v.scenes.has(id), id)
		assert_eq(v.scene_for(id), v.scenes[id])
	assert_eq(v.scene_for("dragon"), v.default_scene)


func test_tile_library_has_the_three_block_kinds() -> void:
	var lib := load("res://game/content/tiles/tiles.tres") as MeshLibrary
	var names: Array[String] = []
	for i in lib.get_item_list():
		names.append(lib.get_item_name(i))
	for n in ["ground", "rough", "wall"]:
		assert_true(n in names, n)


func test_board_scene_is_fully_wired() -> void:
	var b := (load("res://game/content/board/board_3d.tscn") as PackedScene).instantiate() as Board3D
	for prop in ["unit_visuals", "fallback_tiles", "fog_material", "move_material", "target_material", "hover_material",
			"camera_rig", "map_root", "units_root", "overlay_root"]:
		assert_true(b.get(prop) != null, prop)
	b.free()
