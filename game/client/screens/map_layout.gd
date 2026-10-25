class_name MapLayout
extends Resource
## Where each overworld node sits on the map, as fractions (0-1) of the map area, keyed by the node's id in the
## world template. Edit `positions` in the inspector (game/content/overworld/map_layout.tres). A node missing
## from here is still shown: unplaced nodes are spread around a ring, so new template nodes never vanish.

@export var positions: Dictionary = {}


func position_of(node_id: String, index: int, count: int) -> Vector2:
	if positions.has(node_id):
		return positions[node_id]
	var a := TAU * float(index) / float(maxi(count, 1))
	return Vector2(0.5 + 0.4 * cos(a), 0.5 + 0.4 * sin(a))
