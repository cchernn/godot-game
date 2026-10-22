extends TestCase

const ORIGINAL_ROWS: Array[String] = [
	"..........",
	"..~~..#...",
	"..~~..#.11",
	".....11.11",
	".....11...",
	"..#.......",
	"..#..~~...",
	"..........",
]
const MAP := "res://game/content/maps/prototype.tscn"


func test_painted_prototype_matches_the_original_layout() -> void:
	var def := MapDef.load_scene(MAP)
	assert_eq(def.error, "")
	var expect := Battlefield.from_rows(ORIGINAL_ROWS)
	assert_eq(def.battlefield.width, expect.width)
	assert_eq(def.battlefield.height, expect.height)
	assert_eq(def.battlefield.terrain, expect.terrain)
	assert_eq(def.battlefield.elevation, expect.elevation)


func test_spawns_come_from_the_markers() -> void:
	var def := MapDef.load_scene(MAP)
	assert_eq(def.player_spawns, [V(0, 2), V(0, 3), V(0, 4), V(0, 5)] as Array[Vector2i])
	assert_eq(def.enemy_spawns, [V(8, 3), V(9, 4), V(8, 5)] as Array[Vector2i])


func test_tile_kind_comes_from_the_block_name() -> void:
	assert_eq(MapDef.kind_for_name("wall"), Enums.TerrainKind.BLOCKED)
	assert_eq(MapDef.kind_for_name("Wall_stone"), Enums.TerrainKind.BLOCKED)
	assert_eq(MapDef.kind_for_name("rough_mud"), Enums.TerrainKind.DIFFICULT)
	assert_eq(MapDef.kind_for_name("grass"), Enums.TerrainKind.NORMAL)


func test_unpainted_columns_are_blocked_and_bad_maps_report_errors() -> void:
	var lib := MeshLibrary.new()
	lib.create_item(0)
	lib.set_item_name(0, "ground")
	var root := Node3D.new()
	var gm := GridMap.new()
	gm.name = "Terrain"
	gm.mesh_library = lib
	root.add_child(gm)
	gm.set_cell_item(Vector3i(0, 0, 0), 0)
	gm.set_cell_item(Vector3i(2, 1, 0), 0)
	gm.set_cell_item(Vector3i(2, 0, 0), 0)
	var def := MapDef.from_node(root)
	assert_eq(def.error, "")
	assert_eq(def.battlefield.width, 3)
	assert_eq(def.battlefield.terrain_at(V(1, 0)), Enums.TerrainKind.BLOCKED, "hole in the map")
	assert_eq(def.battlefield.elevation_at(V(2, 0)), 1, "two stacked blocks = elevation 1")
	gm.set_cell_item(Vector3i(-1, 0, 0), 0)
	assert_true(MapDef.from_node(root).error != "", "negative cells are reported")
	root.free()
	var empty := Node3D.new()
	assert_true(MapDef.from_node(empty).error != "", "no Terrain node")
	empty.free()


func test_encounter_places_units_on_the_map_spawns() -> void:
	var b := Encounter.build(GameConfig.load_file(), SkillDb.load_file(), 4, 1)
	assert_eq(b.map_id, "prototype")
	assert_eq(b.state.get_c("pc0").cell, V(0, 2))
	assert_eq(b.state.get_c("pc3").cell, V(0, 5))
	assert_eq(b.state.get_c("e0").cell, V(8, 3))
	assert_eq(b.state.get_c("e2").visual, "cultist")
	var snap := b.snapshot_for("pc0")
	assert_eq(snap["map"]["id"], "prototype")
