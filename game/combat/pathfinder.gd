class_name Pathfinder
extends RefCounted


## Dijkstra over cardinal steps (difficult terrain costs 2). `blocked` maps cell -> true.
## Returns {cost: Dictionary, prev: Dictionary}.
static func search(bf: Battlefield, start: Vector2i, blocked: Dictionary, max_step: int) -> Dictionary:
	var cost := {start: 0}
	var prev := {}
	var open: Array[Vector2i] = [start]
	while not open.is_empty():
		var best := 0
		for i in open.size():
			var a := open[i]
			var b := open[best]
			var ca: int = cost[a]
			var cb: int = cost[b]
			if ca < cb or (ca == cb and (a.y < b.y or (a.y == b.y and a.x < b.x))):
				best = i
		var cur: Vector2i = open[best]
		open.remove_at(best)
		for d in Enums.DIRS:
			var n := cur + d
			if blocked.has(n) or not bf.can_step(cur, n, max_step):
				continue
			var nc: int = (cost[cur] as int) + (2 if bf.is_difficult(n) else 1)
			if not cost.has(n) or nc < (cost[n] as int):
				cost[n] = nc
				prev[n] = cur
				if not open.has(n):
					open.append(n)
	return {"cost": cost, "prev": prev}


static func path_to(result: Dictionary, start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if goal == start or not (result["prev"] as Dictionary).has(goal):
		return out
	var cur := goal
	while cur != start:
		out.push_front(cur)
		cur = (result["prev"] as Dictionary)[cur]
	return out


## AP needed to walk a path: one AP per `tiles_per_ap` tiles plus a surcharge per difficult tile.
static func ap_cost(bf: Battlefield, path: Array[Vector2i], tiles_per_ap: int, surcharge: int) -> int:
	var cost := ceili(float(path.size()) / float(tiles_per_ap))
	for c in path:
		if bf.is_difficult(c):
			cost += surcharge
	return cost
