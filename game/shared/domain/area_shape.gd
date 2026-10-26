class_name AreaShape
extends Resource
## How many tiles a skill covers. Leave a skill's Area empty (or Single) for one target. All sizes are PROVISIONAL.
##  - Radius: every tile within `size` steps of the centre (the aimed tile, or the target's tile when the skill lands).
##  - Line: `size` tiles in a straight line from the user toward the aimed tile.
##  - Cone: `size` rows in front of the user, one tile wider on each side with every row (1, 3, 5 ... tiles).
## Everyone standing on a covered tile is hit, friend or foe, the user too if they are covered.

enum Shape { SINGLE, RADIUS, LINE, CONE }

@export var shape: Shape = Shape.SINGLE
## Radius, line length or cone depth, in tiles.
@export_range(1, 12) var size: int = 1
## Walls (and ground higher than the line of sight) stop the area. A radius is checked from its centre, a line or cone from the user.
@export var requires_los: bool = true


func is_single() -> bool:
	return shape == Shape.SINGLE


## The tiles covered. `caster` is the user's tile, `centre` the aimed tile, `caster_facing` the direction a line or cone takes
## when it is aimed at the user's own tile. Walls themselves are never covered.
func cells(bf: Battlefield, caster: Vector2i, centre: Vector2i, caster_facing: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	match shape:
		Shape.SINGLE:
			if bf.in_bounds(centre):
				out.append(centre)
		Shape.RADIUS:
			for dy in range(-size, size + 1):
				var span := size - absi(dy)
				for dx in range(-span, span + 1):
					var c := centre + Vector2i(dx, dy)
					if _open(bf, c) and (not requires_los or bf.has_los(centre, c)):
						out.append(c)
		Shape.LINE, Shape.CONE:
			var facing := Enums.facing_from_delta(centre - caster) if centre != caster else caster_facing
			var fwd: Vector2i = Enums.DIRS[facing]
			var side := Vector2i(-fwd.y, fwd.x)
			for k in range(1, size + 1):
				var reach := 0 if shape == Shape.LINE else k - 1
				for off in range(-reach, reach + 1):
					var c := caster + fwd * k + side * off
					if _open(bf, c) and (not requires_los or bf.has_los(caster, c)):
						out.append(c)
	return out


func _open(bf: Battlefield, c: Vector2i) -> bool:
	return bf.in_bounds(c) and not bf.is_blocked(c)


func problems() -> Array[String]:
	return []
