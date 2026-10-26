class_name TargetingPreview
extends RefCounted
## What the planning UI shows before you click: where a move can reach, which tiles and units a skill can hit, and why a
## hovered tile does not work. Pure functions over the snapshot; the server still validates every plan.


## Tiles the unit can walk to with `ap_left` AP, starting from `start` (occupied tiles are in `blocked`).
static func reachable(bf: Battlefield, start: Vector2i, blocked: Dictionary, tiles_per_ap: int, surcharge: int, ap_left: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if ap_left <= 0:
		return out
	var res := Pathfinder.search(bf, start, blocked, 1)
	for cell: Vector2i in res["cost"]:
		if cell == start:
			continue
		var path := Pathfinder.path_to(res, start, cell)
		if Pathfinder.ap_cost(bf, path, tiles_per_ap, surcharge) <= ap_left:
			out.append(cell)
	return out


## Tiles within the skill's reach that `from` can see.
static func tiles_in_range(bf: Battlefield, from: Vector2i, reach: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in bf.height:
		for x in bf.width:
			var c := Vector2i(x, y)
			var d := Enums.manhattan(from, c)
			if d >= 1 and d <= reach and bf.has_los(from, c):
				out.append(c)
	return out


## Why the skill cannot target this unit from `from`; "" when it can. Anyone can be targeted, friend or foe, and so can you.
static func target_problem(bf: Battlefield, _me: Dictionary, u: Dictionary, sk: SkillDef, from: Vector2i) -> String:
	if sk.kind == Enums.SkillKind.REVIVE:
		if u["life"] != Enums.LifeState.DOWNED:
			return "that unit is not downed"
		if u.get("revived", false):
			return "already revived once"
	var d := Enums.manhattan(from, u["cell"])
	if d > sk.attack_range:
		return "out of range (%d tiles, reach %d)" % [d, sk.attack_range]
	if not bf.has_los(from, u["cell"]):
		return "no line of sight"
	return ""


## Ids of the units the skill can target from `from`.
static func valid_targets(bf: Battlefield, units: Array, me: Dictionary, sk: SkillDef, from: Vector2i) -> Array[String]:
	var out: Array[String] = []
	if sk.targeting != Enums.Targeting.CHARACTER:
		return out
	for u: Dictionary in units:
		if target_problem(bf, me, u, sk, from) == "":
			out.append(u["id"])
	return out


## The tiles a tile-targeted area skill would cover if aimed at `aim` from `from` (empty when it is not an area skill, or `aim` is not
## a legal target). Target-based skills show no area while planning: it is only known when they land.
static func area_cells(bf: Battlefield, sk: SkillDef, from: Vector2i, aim: Vector2i, facing: int) -> Array[Vector2i]:
	if sk == null or not sk.is_area() or sk.targeting != Enums.Targeting.TILE or not bf.in_bounds(aim):
		return []
	if Enums.manhattan(from, aim) > sk.attack_range or not bf.has_los(from, aim):
		return []
	return sk.area.cells(bf, from, aim, facing)


## One line about the hovered tile for the skill being planned ("" when there is nothing to say).
## `reach` is the result of `reachable`, `path_cost` the AP of the walk to the tile (-1 if there is no path).
static func hover_text(sk: SkillDef, units: Array, me: Dictionary, bf: Battlefield, from: Vector2i, hover: Vector2i,
		path_len: int, path_cost: int, ap_left: int) -> String:
	if sk == null or not bf.in_bounds(hover):
		return ""
	if sk.kind == Enums.SkillKind.MOVE:
		if hover == from:
			return ""
		if path_len == 0:
			return "No path to that tile"
		var left := ap_left - path_cost
		if left < 0:
			return "%d tile(s), %d AP: %d more than you have" % [path_len, path_cost, -left]
		return "%d tile(s), %d AP (%d left after)" % [path_len, path_cost, left]
	if sk.targeting == Enums.Targeting.CHARACTER:
		for u: Dictionary in units:
			if u["cell"] == hover:
				var why := target_problem(bf, me, u, sk, from)
				return "%s: %s" % [u["name"], "can be targeted" if why == "" else why]
		return ""
	if sk.targeting == Enums.Targeting.TILE:
		var d := Enums.manhattan(from, hover)
		if d > sk.attack_range:
			return "Out of range (%d tiles, reach %d)" % [d, sk.attack_range]
		if not bf.has_los(from, hover):
			return "No line of sight"
		if sk.is_area():
			var covered := area_cells(bf, sk, from, hover, int(me.get("facing", Enums.Facing.SOUTH)))
			var hit := 0
			for u: Dictionary in units:
				if u["cell"] in covered:
					hit += 1
			return "In range: covers %d tile(s), %d unit(s) in sight" % [covered.size(), hit]
		return "In range"
	return ""


## The beats an action takes in your queue (it resolves one step per beat): a walk is ceil(tiles / tiles_per_ap) beats, a skill one per stage.
static func action_beats(sk: SkillDef, path_len: int, tiles_per_ap: int) -> int:
	if sk.kind == Enums.SkillKind.MOVE:
		return ceili(float(path_len) / float(maxi(1, tiles_per_ap)))
	return sk.stages.size()
