extends SceneTree
## One-time scaffold: creates the editor-editable starting content under res://game/content/.
##   scripts/godot.sh --headless --path . --script res://tools/generate_content.gd
## It never overwrites an existing file (so your edits are safe); pass `-- --force` to regenerate.
## After this, edit the scenes and resources in the Godot editor (docs/editor-guide.md).

const ROOT := "res://game/content/"

# The original prototype layout, converted into a painted GridMap scene.
# '.' flat, '1'-'9' raised, '~' rough (difficult) ground, '#' wall.
const MAP_ROWS: Array[String] = [
	"..........",
	"..~~..#...",
	"..~~..#.11",
	".....11.11",
	".....11...",
	"..#.......",
	"..#..~~...",
	"..........",
]
const PLAYER_SPAWNS: Array[Vector2i] = [Vector2i(0, 2), Vector2i(0, 3), Vector2i(0, 4), Vector2i(0, 5)]
const ENEMY_SPAWNS: Array[Vector2i] = [Vector2i(8, 3), Vector2i(9, 4), Vector2i(8, 5)]
const BLOCK := Vector3(1.0, 0.5, 1.0)
const WALL_BLOCKS := 4

# visual id -> body_scale, so each unit is visibly different until real models exist
const UNITS := {
	"warrior": Vector3(1.15, 1.0, 1.15), "hunter": Vector3(0.85, 1.15, 0.85), "mage": Vector3(1.0, 1.0, 1.0),
	"ghoul": Vector3(1.25, 1.1, 1.25), "cultist": Vector3(0.95, 1.05, 0.95),
}

var _force := false
var _written: Array[String] = []
var _skipped: Array[String] = []


func _initialize() -> void:
	_force = "--force" in OS.get_cmdline_user_args()
	for d in ["tiles/materials", "maps", "units", "board/materials"]:
		DirAccess.make_dir_recursive_absolute(ROOT + d)
	var tile_mats := {
		"ground": _material("tiles/materials/ground.tres", Color(0.30, 0.36, 0.31)),
		"rough": _material("tiles/materials/rough.tres", Color(0.33, 0.27, 0.22)),
		"wall": _material("tiles/materials/wall.tres", Color(0.36, 0.34, 0.38)),
	}
	var lib := _tile_library(tile_mats)
	_tiles_source(tile_mats)
	_map(lib)
	var unit_scene := _unit_scene()
	var visuals := _unit_visuals(unit_scene)
	_board(visuals, lib)
	print("written: ", _written)
	print("kept (already exist, use -- --force to regenerate): ", _skipped)
	quit()


# ---------- helpers ----------

func _keep(path: String) -> bool:
	if FileAccess.file_exists(path) and not _force:
		_skipped.append(path.trim_prefix(ROOT))
		return true
	_written.append(path.trim_prefix(ROOT))
	return false


func _load(path: String) -> Resource:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)


func _material(rel: String, color: Color, overlay: bool = false) -> StandardMaterial3D:
	var path := ROOT + rel
	if _keep(path):
		return _load(path) as StandardMaterial3D
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.9
	if overlay:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.no_depth_test = false
	ResourceSaver.save(m, path)
	m.take_over_path(path)
	return m


func _own(root: Node, node: Node) -> void:
	for c in node.get_children():
		c.owner = root
		_own(root, c)


func _save_scene(rel: String, root: Node) -> PackedScene:
	var path := ROOT + rel
	_own(root, root)
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, path)
	root.free()
	return _load(path) as PackedScene


func _mesh_node(name: String, mesh: Mesh, pos: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = mesh
	mi.position = pos
	return mi


# ---------- tiles ----------

func _tile_library(mats: Dictionary) -> MeshLibrary:
	var path := ROOT + "tiles/tiles.tres"
	if _keep(path):
		return _load(path) as MeshLibrary
	var lib := MeshLibrary.new()
	var i := 0
	for n in ["ground", "rough", "wall"]:
		var mesh := BoxMesh.new()
		mesh.size = BLOCK
		mesh.material = mats[n]
		lib.create_item(i)
		lib.set_item_name(i, n)
		lib.set_item_mesh(i, mesh)
		i += 1
	ResourceSaver.save(lib, path)
	return _load(path) as MeshLibrary


## Edit the meshes here, then Scene > Export As > MeshLibrary... over tiles/tiles.tres.
func _tiles_source(mats: Dictionary) -> void:
	if _keep(ROOT + "tiles/tiles_source.tscn"):
		return
	var root := Node3D.new()
	root.name = "TilesSource"
	var x := 0.0
	for n in ["ground", "rough", "wall"]:
		var mesh := BoxMesh.new()
		mesh.size = BLOCK
		mesh.material = mats[n]
		root.add_child(_mesh_node(n, mesh, Vector3(x, 0, 0)))
		x += 1.5
	_save_scene("tiles/tiles_source.tscn", root)


# ---------- map ----------

func _map(lib: MeshLibrary) -> void:
	if _keep(ROOT + "maps/prototype.tscn"):
		return
	var ids := {}
	for item in lib.get_item_list():
		ids[lib.get_item_name(item)] = item
	var root := Node3D.new()
	root.name = "PrototypeMap"
	var gm := GridMap.new()
	gm.name = MapDef.TERRAIN_NODE
	gm.mesh_library = lib
	gm.cell_size = BLOCK
	root.add_child(gm)
	for z in MAP_ROWS.size():
		var row := MAP_ROWS[z]
		for x in row.length():
			var ch := row[x]
			if ch == "#":
				for h in WALL_BLOCKS:
					gm.set_cell_item(Vector3i(x, h, z), ids["wall"])
			elif ch == "~":
				gm.set_cell_item(Vector3i(x, 0, z), ids["rough"])
			else:
				var e := int(ch) if ch.is_valid_int() else 0
				for h in e + 1:
					gm.set_cell_item(Vector3i(x, h, z), ids["ground"])
	var spawns := Node3D.new()
	spawns.name = MapDef.SPAWNS_NODE
	root.add_child(spawns)
	var names := ["P0", "P1", "P2", "P3"]
	for i in PLAYER_SPAWNS.size():
		spawns.add_child(_marker(names[i], PLAYER_SPAWNS[i], gm))
	for i in ENEMY_SPAWNS.size():
		spawns.add_child(_marker("E%d" % i, ENEMY_SPAWNS[i], gm))
	_save_scene("maps/prototype.tscn", root)


func _marker(name: String, cell: Vector2i, gm: GridMap) -> Marker3D:
	var m := Marker3D.new()
	m.name = name
	var top := 0
	for h in 12:
		if gm.get_cell_item(Vector3i(cell.x, h, cell.y)) != GridMap.INVALID_CELL_ITEM:
			top = h
	m.position = Vector3((cell.x + 0.5) * BLOCK.x, (top + 1) * BLOCK.y, (cell.y + 0.5) * BLOCK.z)
	m.gizmo_extents = 0.4
	return m


# ---------- units ----------

func _unit_scene() -> PackedScene:
	var path := ROOT + "units/unit.tscn"
	if _keep(path):
		return _load(path) as PackedScene
	var root := Node3D.new()
	root.name = "Unit"
	root.set_script(load("res://game/client/board/unit_3d.gd"))

	var capsule := CapsuleMesh.new()
	capsule.radius = 0.28
	capsule.height = 1.0
	var body := _mesh_node("Body", capsule, Vector3(0, 0.5, 0))
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color.WHITE
	body_mat.roughness = 0.7
	body.material_override = body_mat
	root.add_child(body)

	var facing := Node3D.new()
	facing.name = "Facing"
	root.add_child(facing)
	var arrow_mesh := BoxMesh.new()
	arrow_mesh.size = Vector3(0.12, 0.06, 0.4)
	var arrow := _mesh_node("Arrow", arrow_mesh, Vector3(0, 0.5, 0.45))
	var arrow_mat := StandardMaterial3D.new()
	arrow_mat.albedo_color = Color(1, 1, 1)
	arrow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	arrow.material_override = arrow_mat
	facing.add_child(arrow)

	var label := _label("NameLabel", Vector3(0, 1.4, 0), 44, Color.WHITE)
	root.add_child(label)
	var status := _label("StatusLabel", Vector3(0, 1.68, 0), 32, Color(1, 0.65, 0.25))
	root.add_child(status)

	var bar := Node3D.new()
	bar.name = "HealthBar"
	bar.position = Vector3(0, 1.2, 0)
	root.add_child(bar)
	var back := _bar("Back", Color(0, 0, 0, 0.7), 0)
	bar.add_child(back)
	var fill := _bar("Fill", Color(0.35, 0.85, 0.4, 1.0), 1)
	bar.add_child(fill)

	var player := AnimationPlayer.new()
	player.name = "AnimationPlayer"
	root.add_child(player)
	var lib := AnimationLibrary.new()
	lib.add_animation("idle", _anim(1.2, true, [[0.0, 0.5], [0.6, 0.54], [1.2, 0.5]], 0.0))
	lib.add_animation("walk", _anim(0.4, true, [[0.0, 0.5], [0.2, 0.62], [0.4, 0.5]], 0.0))
	lib.add_animation("downed", _anim(0.4, false, [[0.0, 0.5], [0.4, 0.28]], -PI / 2.0))
	player.add_animation_library("", lib)

	root.set("body", body)
	root.set("facing_pivot", facing)
	root.set("name_label", label)
	root.set("status_label", status)
	root.set("hp_fill", fill)
	root.set("animation_player", player)
	return _save_scene("units/unit.tscn", root)


func _label(name: String, pos: Vector3, size: int, color: Color) -> Label3D:
	var l := Label3D.new()
	l.name = name
	l.position = pos
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.pixel_size = 0.006
	l.font_size = size
	l.outline_size = 12
	l.modulate = color
	l.text = ""
	l.render_priority = 10          # draw after the translucent tile overlays
	l.outline_render_priority = 9
	return l


func _bar(name: String, color: Color, priority: int) -> MeshInstance3D:
	var quad := QuadMesh.new()
	quad.size = Vector2(0.8, 0.08)
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.billboard_keep_scale = true
	m.render_priority = 10 + priority
	var mi := _mesh_node(name, quad)
	mi.material_override = m
	return mi


## A Body bob animation: keys are [time, y]; `tilt` is the Body's rotation about X.
func _anim(length: float, loop: bool, keys: Array, tilt: float) -> Animation:
	var a := Animation.new()
	a.length = length
	a.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	var pos := a.add_track(Animation.TYPE_VALUE)
	a.track_set_path(pos, "Body:position")
	for k: Array in keys:
		a.track_insert_key(pos, k[0], Vector3(0, k[1], 0))
	var rot := a.add_track(Animation.TYPE_VALUE)
	a.track_set_path(rot, "Body:rotation")
	a.track_insert_key(rot, 0.0, Vector3.ZERO)
	a.track_insert_key(rot, length, Vector3(tilt, 0, 0))
	return a


func _unit_visuals(unit_scene: PackedScene) -> UnitVisuals:
	for id: String in UNITS:
		var rel := "units/%s.tscn" % id
		if _keep(ROOT + rel):
			continue
		var s: Vector3 = UNITS[id]
		var f := FileAccess.open(ROOT + rel, FileAccess.WRITE)
		f.store_string('[gd_scene load_steps=2 format=3]\n\n[ext_resource type="PackedScene" path="res://game/content/units/unit.tscn" id="1"]\n\n[node name="%s" instance=ExtResource("1")]\nbody_scale = Vector3(%s, %s, %s)\n' % [id.capitalize(), s.x, s.y, s.z])
		f.close()
	var path := ROOT + "units/unit_visuals.tres"
	if _keep(path):
		return _load(path) as UnitVisuals
	var v := UnitVisuals.new()
	v.default_scene = unit_scene
	for id: String in UNITS:
		v.scenes[id] = _load(ROOT + "units/%s.tscn" % id) as PackedScene
	ResourceSaver.save(v, path)
	return _load(path) as UnitVisuals


# ---------- board ----------

func _board(visuals: UnitVisuals, lib: MeshLibrary) -> void:
	if _keep(ROOT + "board/board_3d.tscn"):
		return
	var overlay := {
		"fog": _material("board/materials/fog.tres", Color(0, 0, 0, 0.5), true),
		"move": _material("board/materials/move.tres", Color(1.0, 0.85, 0.2, 0.4), true),
		"target": _material("board/materials/target.tres", Color(1.0, 0.4, 0.2, 0.55), true),
		"hover": _material("board/materials/hover.tres", Color(1, 1, 1, 0.3), true),
	}
	var root := Node3D.new()
	root.name = "Board3D"
	root.set_script(load("res://game/client/board/board_3d.gd"))

	var rig := Node3D.new()
	rig.name = "CameraRig"
	rig.set_script(load("res://game/client/board/camera_rig.gd"))
	root.add_child(rig)
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.fov = 40.0
	cam.far = 250.0
	cam.current = true
	rig.add_child(cam)
	rig.set("camera", cam)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-55, 30, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	root.add_child(sun)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.09, 0.11)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.58, 0.6, 0.68)
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	root.add_child(we)

	var map_root := Node3D.new()
	map_root.name = "Map"
	root.add_child(map_root)
	var units_root := Node3D.new()
	units_root.name = "Units"
	root.add_child(units_root)
	var overlay_root := Node3D.new()
	overlay_root.name = "Overlays"
	root.add_child(overlay_root)

	var hud := CanvasLayer.new()
	hud.name = "Hud"
	root.add_child(hud)
	var hint := Label.new()
	hint.name = "Hint"
	hint.text = "Middle mouse: orbit  |  Shift + middle mouse: pan  |  Wheel: zoom  |  Q / E: turn  |  F: reset view"
	hint.position = Vector2(10, 8)
	hint.modulate = Color(1, 1, 1, 0.6)
	hud.add_child(hint)

	root.set("unit_visuals", visuals)
	root.set("fallback_tiles", lib)
	root.set("fog_material", overlay["fog"])
	root.set("move_material", overlay["move"])
	root.set("target_material", overlay["target"])
	root.set("hover_material", overlay["hover"])
	root.set("camera_rig", rig)
	root.set("map_root", map_root)
	root.set("units_root", units_root)
	root.set("overlay_root", overlay_root)
	_save_scene("board/board_3d.tscn", root)
