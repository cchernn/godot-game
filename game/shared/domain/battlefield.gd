class_name Battlefield
extends RefCounted
## Static terrain: blocked tiles, difficult tiles and elevation. Occupancy lives in BattleState.

const WALL_HEIGHT := 99

var width: int = 0
var height: int = 0
var terrain: PackedInt32Array = PackedInt32Array()
var elevation: PackedInt32Array = PackedInt32Array()
## Tiles a map object currently blocks (cell -> true): walkable terrain nobody can enter, but sight passes over it.
var object_blocks: Dictionary = {}


## Legend: '.' flat, '1'..'9' elevation, '~' difficult terrain, '#' blocked (wall/obstacle).
static func from_rows(rows: Array) -> Battlefield:
	var bf := Battlefield.new()
	bf.height = rows.size()
	bf.width = (rows[0] as String).length()
	bf.terrain.resize(bf.width * bf.height)
	bf.elevation.resize(bf.width * bf.height)
	for y in bf.height:
		var row: String = rows[y]
		for x in bf.width:
			var ch := row[x]
			var i := y * bf.width + x
			bf.terrain[i] = Enums.TerrainKind.NORMAL
			bf.elevation[i] = 0
			if ch == "#":
				bf.terrain[i] = Enums.TerrainKind.BLOCKED
			elif ch == "~":
				bf.terrain[i] = Enums.TerrainKind.DIFFICULT
			elif ch.is_valid_int():
				bf.elevation[i] = int(ch)
	return bf


static func from_arrays(w: int, h: int, p_terrain: Array, p_elevation: Array) -> Battlefield:
	var bf := Battlefield.new()
	bf.width = w
	bf.height = h
	bf.terrain = PackedInt32Array(p_terrain)
	bf.elevation = PackedInt32Array(p_elevation)
	return bf


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < width and c.y < height


func terrain_at(c: Vector2i) -> int:
	return terrain[c.y * width + c.x]


func elevation_at(c: Vector2i) -> int:
	return elevation[c.y * width + c.x]


func is_blocked(c: Vector2i) -> bool:
	return not in_bounds(c) or terrain_at(c) == Enums.TerrainKind.BLOCKED or object_blocks.has(c)


func is_difficult(c: Vector2i) -> bool:
	return in_bounds(c) and terrain_at(c) == Enums.TerrainKind.DIFFICULT


## Static legality of a one-tile cardinal step (ignores occupancy).
func can_step(from: Vector2i, to: Vector2i, max_step_height: int) -> bool:
	if not in_bounds(from) or not in_bounds(to) or is_blocked(to):
		return false
	if Enums.manhattan(from, to) != 1:
		return false
	return absi(elevation_at(from) - elevation_at(to)) <= max_step_height


func _height(c: Vector2i) -> float:
	return float(WALL_HEIGHT if terrain_at(c) == Enums.TerrainKind.BLOCKED else elevation_at(c))


## Sight line between tile centres. Eyes sit 1 above ground; walls block; terrain
## higher than the sight line blocks, so higher ground sees over lower obstacles.
func has_los(from: Vector2i, to: Vector2i) -> bool:
	if not in_bounds(from) or not in_bounds(to):
		return false
	var n := maxi(absi(to.x - from.x), absi(to.y - from.y))
	if n <= 1:
		return true
	var eye_a := float(elevation_at(from)) + 1.0
	var eye_b := float(elevation_at(to)) + 1.0
	for i in range(1, n):
		var t := float(i) / float(n)
		var c := Vector2i(roundi(lerpf(from.x, to.x, t)), roundi(lerpf(from.y, to.y, t)))
		if _height(c) > lerpf(eye_a, eye_b, t):
			return false
	return true
