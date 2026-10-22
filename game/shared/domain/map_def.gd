class_name MapDef
extends RefCounted
## Reads a battle map painted in the Godot editor (a GridMap plus spawn markers) into gameplay data.
## The server and the client both read the same scene, so the layout cannot drift.
##
## Conventions (see docs/editor-guide.md):
##  - Grid x and z are the battlefield x and y. Each GridMap column is one tile.
##  - The tile kind comes from the MeshLibrary item NAME of the column's top block:
##    names starting with "wall" are blocked, "rough" is difficult terrain, anything else is normal.
##  - Elevation is the height index of the top block (a flat tile is one block at y = 0).
##  - Columns with no blocks are blocked (void). Unpainted space outside the map is ignored.
##  - A node called "Spawns" holds Marker3D children: names starting with "P" are player seats
##    (sorted by name), names starting with "E" are enemy spots.

const TERRAIN_NODE := "Terrain"
const SPAWNS_NODE := "Spawns"

var battlefield: Battlefield
var player_spawns: Array[Vector2i] = []
var enemy_spawns: Array[Vector2i] = []
## Height index of the highest block per column (for rendering and picking).
var column_top: Dictionary = {}
var error: String = ""


## Loads and parses a map scene; the instantiated nodes are freed.
static func load_scene(path: String) -> MapDef:
	var packed := load(path) as PackedScene
	if packed == null:
		var d := MapDef.new()
		d.error = "Cannot load map %s" % path
		return d
	var root := packed.instantiate()
	var def := from_node(root)
	root.free()
	return def


static func from_node(root: Node) -> MapDef:
	var def := MapDef.new()
	var gm := root.get_node_or_null(TERRAIN_NODE) as GridMap
	if gm == null or gm.mesh_library == null:
		def.error = "Map has no GridMap named '%s' with a MeshLibrary" % TERRAIN_NODE
		return def
	var used := gm.get_used_cells()
	if used.is_empty():
		def.error = "Map GridMap is empty"
		return def
	var w := 0
	var h := 0
	for c in used:
		if c.x < 0 or c.z < 0:
			def.error = "Map cell %s has a negative x or z; paint from (0, 0) upwards" % str(c)
			return def
		w = maxi(w, c.x + 1)
		h = maxi(h, c.z + 1)
		var key := Vector2i(c.x, c.z)
		if not def.column_top.has(key) or c.y > def.column_top[key]:
			def.column_top[key] = c.y
	var bf := Battlefield.new()
	bf.width = w
	bf.height = h
	bf.terrain.resize(w * h)
	bf.elevation.resize(w * h)
	for y in h:
		for x in w:
			var i := y * w + x
			var key := Vector2i(x, y)
			if not def.column_top.has(key):
				bf.terrain[i] = Enums.TerrainKind.BLOCKED
				bf.elevation[i] = 0
				continue
			var top: int = def.column_top[key]
			var item := gm.get_cell_item(Vector3i(x, top, y))
			var item_name := gm.mesh_library.get_item_name(item)
			bf.terrain[i] = kind_for_name(item_name)
			bf.elevation[i] = 0 if bf.terrain[i] == Enums.TerrainKind.BLOCKED else top
	def.battlefield = bf
	var spawns := root.get_node_or_null(SPAWNS_NODE)
	if spawns != null:
		var markers: Array[Node] = spawns.get_children()
		markers.sort_custom(func(a: Node, b: Node) -> bool: return String(a.name) < String(b.name))
		for m in markers:
			if not m is Node3D:
				continue
			var cell := _marker_cell(root, gm, m as Node3D)
			if String(m.name).begins_with("P"):
				def.player_spawns.append(cell)
			elif String(m.name).begins_with("E"):
				def.enemy_spawns.append(cell)
	return def


static func kind_for_name(item_name: String) -> int:
	var n := item_name.to_lower()
	if n.begins_with("wall"):
		return Enums.TerrainKind.BLOCKED
	if n.begins_with("rough"):
		return Enums.TerrainKind.DIFFICULT
	return Enums.TerrainKind.NORMAL


## Marker position in the GridMap's space, then to a grid cell. Works for scenes outside the tree.
static func _marker_cell(root: Node, gm: GridMap, marker: Node3D) -> Vector2i:
	var t := Transform3D.IDENTITY
	var n: Node = marker
	while n != null and n != root:
		t = (n as Node3D).transform * t
		n = n.get_parent()
	var local := gm.transform.affine_inverse() * t.origin
	var cell := gm.local_to_map(local)
	return Vector2i(cell.x, cell.z)
