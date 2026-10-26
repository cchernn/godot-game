class_name PlanValidator
extends RefCounted
## Static validation of a queued plan and its AP cost. Execution re-validates everything.

const MAX_ACTIONS := 16


static func tiles_per_ap(cfg: GameConfig, c: Combatant) -> int:
	return cfg.tiles_per_ap(c.stat("dexterity"))


## Returns {ok, error, costs: Array[int]}. `team_sees` reports whether the cell is visible to the planner's team.
static func validate(battle: Battle, c: Combatant, actions: Array[PlannedAction]) -> Dictionary:
	var cfg := battle.cfg
	var bf := battle.bf
	var costs: Array[int] = []
	if actions.size() > MAX_ACTIONS:
		return _fail("Too many actions")
	var pos := c.cell
	var queued := {} # item id -> copies planned so far
	var total := 0
	var beats := 0
	var max_step: int = cfg.get_value("combat", "max_step_height")
	var tpa := tiles_per_ap(cfg, c)
	var surcharge: int = cfg.get_value("movement", "difficult_terrain_surcharge")
	for a in actions:
		var sk := battle.skills.get_skill(a.skill_id)
		if a.item_id != "":
			if sk == null or not battle.skills.items.has(a.item_id):
				return _fail("Unknown item")
			queued[a.item_id] = int(queued.get(a.item_id, 0)) + 1
			if int(queued[a.item_id]) > c.items.get(a.item_id, 0) - c.items_used.get(a.item_id, 0):
				return _fail("You do not have enough of that item")
		elif sk == null or not c.skills.has(a.skill_id) or a.skill_id.begins_with("item:"):
			return _fail("Unknown skill")
		var cost := 0
		match sk.kind:
			Enums.SkillKind.MOVE:
				if a.path.is_empty() or a.path.size() > 24:
					return _fail("Invalid path")
				var cur := pos
				for step in a.path:
					if not bf.can_step(cur, step, max_step):
						return _fail("Invalid path")
					cur = step
				cost = Pathfinder.ap_cost(bf, a.path, tpa, surcharge)
				beats += ceili(float(a.path.size()) / float(tpa))
				pos = cur
			_:
				if sk.targeting == Enums.Targeting.CHARACTER:
					var t := battle.state.get_c(a.target_id)
					if t == null or not battle.team_can_see_combatant(c.team, t): # anyone visible, friend or foe, even yourself
						return _fail("Invalid target")
				elif sk.targeting == Enums.Targeting.TILE:
					if not a.has_cell or not bf.in_bounds(a.target_cell):
						return _fail("Invalid target")
				cost = sk.total_ap()
				beats += sk.stages.size()
		total += cost
		costs.append(cost)
	if total > c.ap_capacity:
		return _fail("Not enough AP (%d/%d)" % [total, c.ap_capacity])
	if beats > battle.beats_per_round:
		return _fail("Plan is too long for one round")
	return {"ok": true, "error": "", "costs": costs}


static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg, "costs": [] as Array[int]}
