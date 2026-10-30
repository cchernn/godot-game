class_name Board3D
extends Node3D
## The 3D battlefield. Presentation only: it shows the last authoritative snapshot (with smoothing) and
## reports clicks; it never decides outcomes. What it draws comes from editor-made content:
## the painted map scene (game/content/maps), the unit scenes mapped by `unit_visuals`, the overlay
## materials below, and the CameraRig node. See docs/editor-guide.md.

signal cell_clicked(cell: Vector2i, unit_id: String)

const MAP_DIR := "res://game/content/maps/"
const MOVE_SPEED := 6.0   ## tiles per second for smoothed unit movement

@export var unit_visuals: UnitVisuals
## Tile blocks used to draw a map when the snapshot's map scene cannot be loaded.
@export var fallback_tiles: MeshLibrary

@export_group("Overlays")
@export var fog_material: Material
@export var move_material: Material
@export var target_material: Material
@export var hover_material: Material
## Tiles a picked move or skill can reach, and the units it can target.
@export var range_material: Material
@export var valid_material: Material
## Tiles an area skill would cover where the mouse is.
@export var area_material: Material
## The walk you would make to the hovered tile.
@export var path_material: Material
@export var overlay_lift: float = 0.02
## How thick the border drawn on the hovered tile is, in tiles.
@export_range(0.01, 0.3) var hover_border_width: float = 0.08

@export_group("Symbols")
## Stands on every tile your plan targets, with its order number above.
@export var target_marker_scene: PackedScene
## Stands on the tile you clicked while the action menu is open.
@export var select_marker_scene: PackedScene

@export_group("Floating text")
## One scene per number or word that rises from a unit (content/board/markers/floating_text.tscn).
@export var floating_text_scene: PackedScene
## What a unit says is shown over its head in this scene (content/board/markers/chat_bubble.tscn).
@export var chat_bubble_scene: PackedScene
@export var damage_color: Color = Color(1, 0.4, 0.35)
@export var crit_color: Color = Color(1, 0.8, 0.25)
@export var heal_color: Color = Color(0.45, 0.9, 0.5)
@export var shield_color: Color = Color(0.5, 0.8, 1)
@export var miss_color: Color = Color(0.75, 0.75, 0.75)
@export var status_color: Color = Color(0.85, 0.65, 1)
@export var notice_color: Color = Color(1, 0.85, 0.4)
## How much bigger a crit is, and how long (seconds) each further text of the same unit waits so they do not overlap.
@export var crit_scale: float = 1.4
@export var stagger_seconds: float = 0.3

@export_group("Nodes")
@export var camera_rig: CameraRig
@export var map_root: Node3D
@export var units_root: Node3D
@export var overlay_root: Node3D

var bf: Battlefield = null
var units: Array[Dictionary] = []
var me_id: String = ""
var plan_cells: Array[Vector2i] = []   # planned movement tiles
var plan_marks: Array[Vector2i] = []   # planned attack targets
var range_cells: Array[Vector2i] = []  # tiles the picked skill can reach
var valid_cells: Array[Vector2i] = []  # tiles of units it can target
var area_cells: Array[Vector2i] = []  # tiles an area skill covers if aimed at the hovered tile
var path_cells: Array[Vector2i] = []   # the walk to the hovered tile
var marks: Array[Dictionary] = []      # [{cell, text}] symbols on the tiles your plan targets
var selected_cell: Vector2i = Vector2i(-1, -1)  # the clicked tile while the action menu is open
var hover: Vector2i = Vector2i(-1, -1)
var hover_unit: String = ""            # the unit under the mouse ("" when it is over a tile): it is highlighted instead of the tile
var selected_unit: String = ""         # the unit whose action menu is open

var _map_id: String = "<unset>"
var _gm: GridMap
var _top: Dictionary = {}              # Vector2i column -> height index of its top block
var _seen: Dictionary = {}
var _sight: int = 8
var _unit_nodes: Dictionary = {}       # unit id -> Unit3D
var _disp: Dictionary = {}             # unit id -> smoothed Vector2 cell position
var _overlays: Dictionary = {}         # kind -> Array[MeshInstance3D]
var _overlay_mesh: PlaneMesh
var _frame_mesh: ArrayMesh
var _overlay_sig: int = 0
var _target_nodes: Array[BoardMarker] = []
var _select_node: BoardMarker
var _serial: int = 0


## True when the player's team currently sees this tile (its own units are always shown).
func is_seen(cell: Vector2i) -> bool:
	return _seen.has(cell)


func _ready() -> void:
	_sight = GameConfig.load_file().get_value("combat", "sight_range")


# ---------- Snapshot ----------

func set_snapshot(snap: Dictionary) -> void:
	var m: Dictionary = snap["map"]
	bf = Battlefield.from_arrays(m["w"], m["h"], m["terrain"], m["elev"])
	for o: Dictionary in snap.get("objects", []):
		if o["blocks"]:
			bf.object_blocks[o["cell"]] = true
	_ensure_map(str(m.get("id", "")))
	_show_object_states(snap.get("objects", []))
	units.assign(snap["units"])
	me_id = snap["you"]
	_seen.clear()
	for u in units:
		if u["team"] == Enums.Team.PLAYERS:
			for y in bf.height:
				for x in bf.width:
					var c := Vector2i(x, y)
					if not _seen.has(c) and Visibility.can_see(bf, u["cell"], c, _sight):
						_seen[c] = true
	_sync_units()
	_serial += 1


## Shows each object's state on its map node (the Label3D in map_object.tscn).
func _show_object_states(list: Array) -> void:
	if _gm == null or not is_instance_valid(_gm):
		return
	var holder := _gm.get_parent().get_node_or_null(MapDef.OBJECTS_NODE)
	if holder == null:
		return
	for o: Dictionary in list:
		var node := holder.get_node_or_null(str(o["id"])) as MapObject
		if node != null:
			node.show_state(str(o["state"]))


func _sync_units() -> void:
	var present := {}
	for u in units:
		var id: String = u["id"]
		present[id] = true
		var node: Unit3D = _unit_nodes.get(id)
		if node == null:
			var scene := unit_visuals.scene_for(str(u.get("visual", ""))) if unit_visuals != null else null
			if scene == null:
				continue
			node = scene.instantiate() as Unit3D
			units_root.add_child(node)
			_unit_nodes[id] = node
			_disp[id] = Vector2(u["cell"])
			node.position = _unit_position(_disp[id], node.position.y, 0.0, true)
		node.apply(u, id == me_id)
	for id: String in _unit_nodes.keys():
		if not present.has(id):
			(_unit_nodes[id] as Unit3D).queue_free()
			_unit_nodes.erase(id)
			_disp.erase(id)


## Clears the battle (units, highlights) when leaving it; the map stays loaded for the next one.
func reset() -> void:
	for node: Unit3D in _unit_nodes.values():
		node.queue_free()
	_unit_nodes.clear()
	_disp.clear()
	units.clear()
	_seen.clear()
	plan_cells = [] as Array[Vector2i]
	plan_marks = [] as Array[Vector2i]
	range_cells = [] as Array[Vector2i]
	valid_cells = [] as Array[Vector2i]
	area_cells = [] as Array[Vector2i]
	path_cells = [] as Array[Vector2i]
	marks = [] as Array[Dictionary]
	selected_cell = Vector2i(-1, -1)
	hover = Vector2i(-1, -1)
	hover_unit = ""
	selected_unit = ""
	bf = null
	_serial += 1


# ---------- Map ----------

func _valid_map_id(id: String) -> bool:
	if id.is_empty() or id.length() > 40:
		return false
	for ch in id:
		if not (ch in "abcdefghijklmnopqrstuvwxyz0123456789_"):
			return false
	return true


func _ensure_map(id: String) -> void:
	if id == _map_id and _gm != null and is_instance_valid(_gm):
		return
	var first := _gm == null
	_clear_map()
	_map_id = id
	var node: Node3D = null
	if _valid_map_id(id) and ResourceLoader.exists(MAP_DIR + id + ".tscn"):
		var candidate := (load(MAP_DIR + id + ".tscn") as PackedScene).instantiate() as Node3D
		var def := MapDef.from_node(candidate)
		if def.error == "" and def.battlefield.width == bf.width and def.battlefield.height == bf.height \
				and def.battlefield.terrain == bf.terrain and def.battlefield.elevation == bf.elevation:
			node = candidate
		else:
			push_warning("Map '%s' does not match the server's layout%s; drawing the server's layout instead" % [id, (" (" + def.error + ")") if def.error != "" else ""])
			candidate.free()
	if node == null:
		node = _fallback_map()
	map_root.add_child(node)
	_gm = node.get_node(MapDef.TERRAIN_NODE) as GridMap
	_index_columns()
	_overlay_mesh = null
	for list: Array in _overlays.values():
		for mi: MeshInstance3D in list:
			mi.queue_free()
	_overlays.clear()
	camera_rig.frame(map_bounds(), not first)


func _clear_map() -> void:
	for c in map_root.get_children():
		c.queue_free()
	_gm = null
	_top.clear()


func _fallback_map() -> Node3D:
	var root := Node3D.new()
	var gm := GridMap.new()
	gm.name = MapDef.TERRAIN_NODE
	gm.mesh_library = fallback_tiles
	gm.cell_size = Vector3(1.0, 0.5, 1.0)
	root.add_child(gm)
	if fallback_tiles == null:
		return root
	var ids := {}
	for item in fallback_tiles.get_item_list():
		ids[fallback_tiles.get_item_name(item)] = item
	for y in bf.height:
		for x in bf.width:
			var c := Vector2i(x, y)
			var kind := bf.terrain_at(c)
			var name := "wall" if kind == Enums.TerrainKind.BLOCKED else ("rough" if kind == Enums.TerrainKind.DIFFICULT else "ground")
			if not ids.has(name):
				continue
			var blocks := 4 if kind == Enums.TerrainKind.BLOCKED else bf.elevation_at(c) + 1
			for h in blocks:
				gm.set_cell_item(Vector3i(x, h, y), ids[name])
	return root


func _index_columns() -> void:
	_top.clear()
	for c in _gm.get_used_cells():
		var key := Vector2i(c.x, c.z)
		if not _top.has(key) or c.y > _top[key]:
			_top[key] = c.y


## World-space box of the map, used to frame and limit the camera.
func map_bounds() -> AABB:
	var cs := _gm.cell_size
	var max_top := 0
	for v: int in _top.values():
		max_top = maxi(max_top, v)
	var lo := _gm.to_global(_gm.map_to_local(Vector3i(0, 0, 0)) - cs * 0.5)
	var hi := _gm.to_global(_gm.map_to_local(Vector3i(bf.width - 1, max_top, bf.height - 1)) + cs * 0.5)
	return AABB(lo, hi - lo)


## World position of the middle of a tile's top face.
func cell_surface(cell: Vector2i) -> Vector3:
	var top: int = _top.get(cell, 0)
	var local := _gm.map_to_local(Vector3i(cell.x, top, cell.y)) + Vector3(0.0, _gm.cell_size.y * 0.5, 0.0)
	return _gm.to_global(local)


func _unit_position(cell_f: Vector2, current_y: float, delta: float, snap: bool = false) -> Vector3:
	var cs := _gm.cell_size
	var xz := _gm.to_global(Vector3((cell_f.x + 0.5) * cs.x, 0.0, (cell_f.y + 0.5) * cs.z))
	var target_y := cell_surface(Vector2i(cell_f.round())).y
	var y := target_y if snap else lerpf(current_y, target_y, 1.0 - exp(-14.0 * delta))
	return Vector3(xz.x, y, xz.z)


# ---------- Per-frame ----------

func _process(delta: float) -> void:
	if _gm == null:
		return
	for u in units:
		var id: String = u["id"]
		var node: Unit3D = _unit_nodes.get(id)
		if node == null:
			continue
		_disp[id] = (_disp[id] as Vector2).move_toward(Vector2(u["cell"]), MOVE_SPEED * delta)
		var p: Vector2 = _disp[id]
		node.set_world_position(_unit_position(p, node.position.y, delta), delta)
		node.visible = _seen.has(Vector2i(p.round())) or u["team"] == Enums.Team.PLAYERS
	var sig := hash([plan_cells, plan_marks, range_cells, valid_cells, area_cells, path_cells, marks, selected_cell, hover, hover_unit, selected_unit, _serial])
	if sig != _overlay_sig:
		_overlay_sig = sig
		_refresh_overlays()


func _refresh_overlays() -> void:
	var fog: Array[Vector2i] = []
	if bf != null:
		for y in bf.height:
			for x in bf.width:
				if not _seen.has(Vector2i(x, y)):
					fog.append(Vector2i(x, y))
	_show("fog", fog, fog_material, 0.0)
	_show("range", range_cells, range_material, 0.005)
	_show("move", plan_cells, move_material, 0.01)
	_show("valid", valid_cells, valid_material, 0.015)
	_show("area", area_cells, area_material, 0.017)
	_show("path", path_cells, path_material, 0.012)
	_refresh_markers()
	_show("target", plan_marks, target_material, 0.02)
	var hovered: Array[Vector2i] = []
	if bf != null and bf.in_bounds(hover) and hover_unit == "":
		hovered.append(hover) # over a tile: its border; over a unit the unit glows instead
	_show("hover", hovered, hover_material, 0.03, _frame())
	for id: String in _unit_nodes:
		(_unit_nodes[id] as Unit3D).set_hovered(id == hover_unit or id == selected_unit)


## Puts the target symbols (with their numbers) and the selected-tile symbol where they belong.
func _refresh_markers() -> void:
	if target_marker_scene != null:
		while _target_nodes.size() < marks.size():
			var m := target_marker_scene.instantiate() as BoardMarker
			overlay_root.add_child(m)
			_target_nodes.append(m)
		for i in _target_nodes.size():
			_target_nodes[i].visible = i < marks.size()
			if i < marks.size():
				_target_nodes[i].position = cell_surface(marks[i]["cell"]) + Vector3(0.0, overlay_lift + 0.03, 0.0)
				_target_nodes[i].set_text(str(marks[i]["text"]))
	if select_marker_scene != null:
		if _select_node == null:
			_select_node = select_marker_scene.instantiate() as BoardMarker
			overlay_root.add_child(_select_node)
		_select_node.visible = bf != null and bf.in_bounds(selected_cell)
		if _select_node.visible:
			_select_node.position = cell_surface(selected_cell) + Vector3(0.0, overlay_lift + 0.04, 0.0)


# ---------- Floating text ----------

## Shows a line of chat over a unit. Nothing happens for a unit that is not on the board (not in sight, or gone).
func say(unit_id: String, text: String) -> void:
	var node: Unit3D = _unit_nodes.get(unit_id)
	if node != null and chat_bubble_scene != null:
		node.say(chat_bubble_scene, text)


## Floats a number or word over a unit. `delay` staggers texts that start together.
func float_text(unit_id: String, text: String, color: Color, size: float = 1.0, delay: float = 0.0) -> void:
	var node: Unit3D = _unit_nodes.get(unit_id)
	if node == null or floating_text_scene == null:
		return
	var ft := floating_text_scene.instantiate() as FloatingText
	overlay_root.add_child(ft)
	ft.position = node.position + Vector3(0.0, 1.2, 0.0)
	ft.play(text, color, size, delay)


## Shows what a battle event did to a unit: damage, a miss, healing, a shield, a status. `slot` counts the texts already started
## for that unit in this batch.
func show_event(e: Dictionary, slots: Dictionary) -> void:
	var id: String = e.get("target", "")
	if id == "" or not _unit_nodes.has(id):
		return
	var d: Dictionary = e.get("data", {})
	var text := ""
	var color := notice_color
	var size := 1.0
	match e["type"]:
		"hit":
			if d.has("amount"):
				var through: int = d["amount"] - d.get("absorbed", 0)
				text = "-%d" % through if through > 0 else "Absorbed"
				color = damage_color if through > 0 else shield_color
				if d.get("crit", false):
					text += "!"
					color = crit_color
					size = crit_scale
		"miss":
			text = "Miss"
			color = miss_color
		"heal":
			text = "+%d" % d.get("amount", 0)
			color = heal_color
		"shield":
			text = "+%d shield" % d.get("amount", 0)
			color = shield_color
		"status_apply":
			text = "%s %s" % [d.get("glyph", ""), d.get("name", "")]
			color = Color.html(str(d.get("color", "d9a0ff")))
		"status_end":
			text = "%s ends" % d.get("name", "")
			color = miss_color
		"interrupt":
			text = "Interrupted"
		"revived":
			text = "Revived"
			color = heal_color
		"downed":
			text = "Downed"
			color = damage_color
		"eliminated":
			text = "Defeated"
			color = damage_color
	if text == "":
		return
	var n: int = slots.get(id, 0)
	slots[id] = n + 1
	float_text(id, text.strip_edges(), color, size, n * stagger_seconds)


## A square border the size of a tile (a frame, not a filled square).
func _frame() -> ArrayMesh:
	if _frame_mesh == null:
		var half := Vector2(_gm.cell_size.x, _gm.cell_size.z) * 0.49
		var inner := half - Vector2(hover_border_width, hover_border_width) * Vector2(_gm.cell_size.x, _gm.cell_size.z)
		var v := PackedVector3Array()
		for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			v.append(Vector3(corner.x * half.x, 0.0, corner.y * half.y))
		for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			v.append(Vector3(corner.x * inner.x, 0.0, corner.y * inner.y))
		var idx := PackedInt32Array()
		for i in 4:
			var j := (i + 1) % 4
			idx.append_array([i, j, 4 + j, i, 4 + j, 4 + i])
		var normals := PackedVector3Array()
		for i in 8:
			normals.append(Vector3.UP)
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_INDEX] = idx
		_frame_mesh = ArrayMesh.new()
		_frame_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return _frame_mesh


func _show(kind: String, cells: Array[Vector2i], material: Material, extra_lift: float, mesh: Mesh = null) -> void:
	if _overlay_mesh == null:
		_overlay_mesh = PlaneMesh.new()
		_overlay_mesh.size = Vector2(_gm.cell_size.x * 0.98, _gm.cell_size.z * 0.98)
	var list: Array = _overlays.get(kind, [])
	_overlays[kind] = list
	while list.size() < cells.size():
		var mi := MeshInstance3D.new()
		mi.mesh = mesh if mesh != null else _overlay_mesh
		mi.material_override = material
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		overlay_root.add_child(mi)
		list.append(mi)
	for i in list.size():
		var mi := list[i] as MeshInstance3D
		mi.visible = i < cells.size()
		if mi.visible:
			mi.position = cell_surface(cells[i]) + Vector3(0.0, overlay_lift + extra_lift, 0.0)


# ---------- Picking and input ----------

## What is under a viewport position: {"cell": Vector2i, "unit": String} or {} if nothing.
func pick(pos: Vector2) -> Dictionary:
	if _gm == null:
		return {}
	var cam := camera_rig.camera
	return pick_ray(cam.project_ray_origin(pos), cam.project_ray_normal(pos))


func pick_ray(origin: Vector3, dir: Vector3) -> Dictionary:
	var best_t := INF
	var result := {}
	for u in units:
		var node: Unit3D = _unit_nodes.get(u["id"])
		if node == null or not node.visible:
			continue
		var t := _ray_sphere(origin, dir, node.global_position + Vector3(0.0, node.pick_height, 0.0), node.pick_radius)
		if t >= 0.0 and t < best_t:
			best_t = t
			result = {"cell": u["cell"], "unit": u["id"]}
	var inv := _gm.global_transform.affine_inverse()
	var o := inv * origin
	var d := inv.basis * dir
	var cs := _gm.cell_size
	for key: Vector2i in _top.keys():
		var lo := _gm.map_to_local(Vector3i(key.x, 0, key.y)) - cs * 0.5
		var hi := _gm.map_to_local(Vector3i(key.x, _top[key], key.y)) + cs * 0.5
		var t := _ray_box(o, d, lo, hi)
		if t >= 0.0 and t < best_t:
			best_t = t
			result = {"cell": key, "unit": ""}
	return result


static func _ray_sphere(o: Vector3, d: Vector3, center: Vector3, radius: float) -> float:
	var oc := o - center
	var b := oc.dot(d)
	var disc := b * b - (oc.dot(oc) - radius * radius)
	if disc < 0.0:
		return -1.0
	var t := -b - sqrt(disc)
	return t if t >= 0.0 else -b + sqrt(disc)


static func _ray_box(o: Vector3, d: Vector3, lo: Vector3, hi: Vector3) -> float:
	var tmin := 0.0
	var tmax := INF
	for i in 3:
		if absf(d[i]) < 1e-9:
			if o[i] < lo[i] or o[i] > hi[i]:
				return -1.0
		else:
			var t1 := (lo[i] - o[i]) / d[i]
			var t2 := (hi[i] - o[i]) / d[i]
			tmin = maxf(tmin, minf(t1, t2))
			tmax = minf(tmax, maxf(t1, t2))
			if tmin > tmax:
				return -1.0
	return tmin


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if not (mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE):
			var h := pick(mm.position)
			hover = h.get("cell", Vector2i(-1, -1))
			hover_unit = h.get("unit", "")
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var h := pick(mb.position)
			if not h.is_empty():
				cell_clicked.emit(h["cell"], h["unit"])
