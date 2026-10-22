class_name AiPlanner
extends RefCounted
## Tactical-scoring AI. Evaluates (target, skill) candidates, each a move-then-attack plan built
## under the same AP and validation rules as players. Iteration order is fixed, so ties break
## deterministically (first candidate wins).


func plan_for(battle: Battle, c: Combatant) -> Array[PlannedAction]:
	var cfg := battle.cfg
	var bf := battle.bf
	var w: Dictionary = cfg.data["ai"]["weights"]
	var max_step: int = cfg.get_value("combat", "max_step_height")
	var tpa := cfg.tiles_per_ap(c.dexterity)
	var sur: int = cfg.get_value("movement", "difficult_terrain_surcharge")

	var targets: Array[Combatant] = []
	for t in battle.state.team_members(Enums.Team.PLAYERS):
		if t.is_present():
			targets.append(t)
	targets.sort_custom(func(x: Combatant, y: Combatant) -> bool: return x.id < y.id)

	var blocked := {}
	for o: Combatant in battle.state.combatants.values():
		if o != c and o.is_present():
			blocked[o.cell] = true
	var search := Pathfinder.search(bf, c.cell, blocked, max_step)
	var cells: Array = (search["cost"] as Dictionary).keys()
	cells.sort_custom(func(p: Vector2i, q: Vector2i) -> bool:
		var cp: int = search["cost"][p]
		var cq: int = search["cost"][q]
		if cp != cq:
			return cp < cq
		return p.y < q.y or (p.y == q.y and p.x < q.x))

	var best: Array[PlannedAction] = []
	var best_score := -INF
	for t in targets:
		var visible := battle.team_can_see_combatant(c.team, t)
		var options: Array[SkillDef] = []
		if visible:
			for sid in c.skills:
				var sk := battle.skills.get_skill(sid)
				if sk.kind == Enums.SkillKind.ATTACK:
					options.append(sk)
		for sk in options:
			var attack_ap := sk.total_ap()
			if attack_ap > c.ap_capacity:
				continue
			var stand := Vector2i(-1, -1)
			var path: Array[Vector2i] = []
			for cell: Vector2i in cells:
				var p := Pathfinder.path_to(search, c.cell, cell)
				if Pathfinder.ap_cost(bf, p, tpa, sur) > c.ap_capacity - attack_ap:
					continue
				if Enums.manhattan(cell, t.cell) <= sk.attack_range and bf.has_los(cell, t.cell):
					stand = cell
					path = p
					break
			if stand.x < 0:
				continue
			var dmg := 0.0
			for st in sk.stages:
				dmg += float((st.get("damage", 0) as int) + c.power)
			dmg *= cfg.get_value("combat", "base_hit_chance") as float
			var score: float = (w["damage"] as float) * dmg
			if t.life_state == Enums.LifeState.DOWNED or dmg >= t.hp:
				score += (w["objective"] as float) * 8.0
			var adjacent := 0
			for p2 in targets:
				if p2 != t and Enums.manhattan(p2.cell, stand) <= 1:
					adjacent += 1
			score -= (w["survival"] as float) * adjacent
			score -= (w["ap_cost"] as float) * (attack_ap + Pathfinder.ap_cost(bf, path, tpa, sur))
			score += (w["positioning"] as float) * float(bf.elevation_at(stand))
			if score > best_score:
				best_score = score
				best = _build(c, sk, t, path)
	if not best.is_empty():
		return best
	return _approach(battle, c, targets, search, cells, tpa, sur)


func _build(c: Combatant, sk: SkillDef, t: Combatant, path: Array[Vector2i]) -> Array[PlannedAction]:
	var out: Array[PlannedAction] = []
	var at := c.cell
	if not path.is_empty():
		var m := PlannedAction.new()
		m.skill_id = "move"
		m.path = path
		at = path[path.size() - 1]
		m.facing = Enums.facing_from_delta(t.cell - at)
		out.append(m)
	var a := PlannedAction.new()
	a.skill_id = sk.id
	if sk.targeting == Enums.Targeting.CHARACTER:
		a.target_id = t.id
	else:
		a.target_cell = t.cell
		a.has_cell = true
	out.append(a)
	return out


## No attack possible this round: close distance to the nearest player using all AP.
func _approach(battle: Battle, c: Combatant, targets: Array[Combatant], search: Dictionary,
		cells: Array, tpa: int, sur: int) -> Array[PlannedAction]:
	var out: Array[PlannedAction] = []
	if targets.is_empty() or not c.skills.has("move"):
		return out
	var best_cell := c.cell
	var best_dist := 9999
	for cell: Vector2i in cells:
		var p := Pathfinder.path_to(search, c.cell, cell)
		if Pathfinder.ap_cost(battle.bf, p, tpa, sur) > c.ap_capacity:
			continue
		for t in targets:
			var d := Enums.manhattan(cell, t.cell)
			if d < best_dist:
				best_dist = d
				best_cell = cell
	if best_cell != c.cell:
		var m := PlannedAction.new()
		m.skill_id = "move"
		m.path = Pathfinder.path_to(search, c.cell, best_cell)
		out.append(m)
	return out
