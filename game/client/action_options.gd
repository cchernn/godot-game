class_name ActionOptions
extends RefCounted
## What you can do with a click on the board: the entries of the action menu. Clicking a tile or a unit lists every action that
## makes sense there (a walk, attacks, skills, items, a map object's actions), each with its cost, what it does, and, when it cannot
## be used right now, why not. Pure functions over the snapshot; the server still validates every plan.
##
## An option is {kind: move|skill|context, id (the skill id), label, ap, enabled, reason, summary, hint, cell, unit, object, action}.


## `ctx` carries: bf, skills (SkillDb), cfg (GameConfig), me (your unit), units (snapshot units), objects (snapshot objects),
## from (where you will stand), ap_left, planned (skill ids already in your plan), items_left (item id -> copies left),
## blocked (cells a walk cannot pass), cell and unit (the click).
static func build(ctx: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var bf: Battlefield = ctx["bf"]
	var skills: SkillDb = ctx["skills"]
	var me: Dictionary = ctx["me"]
	var from: Vector2i = ctx["from"]
	var cell: Vector2i = ctx["cell"]
	var unit_id: String = ctx["unit"]
	var ap_left: int = ctx["ap_left"]
	var clicked: Dictionary = {}
	for u: Dictionary in ctx["units"]:
		if u["id"] == unit_id:
			clicked = u
	var on_me: bool = unit_id == me["id"]
	var armor: int = clicked.get("armor", 0)
	var move_id := ""
	var other: Array[Dictionary] = []
	for id: String in me.get("skills", []):
		var sk := skills.get_skill(id)
		if sk == null:
			continue
		if sk.kind == Enums.SkillKind.MOVE:
			move_id = id
			continue
		var problem := _skill_problem(ctx, sk, clicked, on_me)
		if problem == "-":
			continue # does not apply to this click
		other.append(_option(ctx, sk, sk.display_name, problem, armor, cell, unit_id))
	for it: Dictionary in me.get("items", []):
		var sk := skills.get_skill(ItemDef.skill_id_for(it["id"]))
		if sk == null:
			continue
		var problem := _skill_problem(ctx, sk, clicked, on_me)
		if problem == "-":
			continue
		var left: int = (ctx["items_left"] as Dictionary).get(it["id"], it["count"])
		if problem == "" and left <= 0:
			problem = "none left"
		other.append(_option(ctx, sk, "%s ×%d" % [sk.display_name, left], problem, armor, cell, unit_id))
	if move_id != "" and unit_id == "" and cell != from:
		out.append(_move_option(ctx, skills.get_skill(move_id)))
	out.append_array(other)
	for o: Dictionary in ctx["objects"]:
		if o["cell"] != cell and not on_me:
			continue
		var dist := Enums.manhattan(from, o["cell"])
		for a: Dictionary in o["actions"]:
			var sk := skills.get_skill(ContextAction.skill_id_for(o["id"], a["id"]))
			if sk == null:
				continue
			var problem := "" if dist <= int(o["reach"]) else "out of reach: move closer"
			if on_me and problem != "":
				continue # only list what is in reach when you click yourself
			if problem == "" and sk.total_ap() > ap_left:
				problem = "needs %d AP, %d left" % [sk.total_ap(), ap_left]
			var opt := _option(ctx, sk, "%s: %s" % [o["name"], a["name"]], problem, 0, cell, unit_id)
			opt["kind"] = "context"
			opt["object"] = o["id"]
			opt["action"] = a["id"]
			opt["hint"] = a["hint"]
			out.append(opt)
	return out


## "-" = the skill has nothing to do with this click (so it is not listed); "" = usable; otherwise why it cannot be used.
static func _skill_problem(ctx: Dictionary, sk: SkillDef, clicked: Dictionary, on_me: bool) -> String:
	var bf: Battlefield = ctx["bf"]
	var from: Vector2i = ctx["from"]
	var cell: Vector2i = ctx["cell"]
	match sk.targeting:
		Enums.Targeting.CHARACTER:
			if clicked.is_empty():
				return "-"
			var why := TargetingPreview.target_problem(bf, ctx["me"], clicked, sk, from)
			if why != "":
				return why
		Enums.Targeting.TILE:
			var d := Enums.manhattan(from, cell)
			if d > sk.attack_range:
				return "out of range (%d tiles, reach %d)" % [d, sk.attack_range]
			if sk.requires_los and not bf.has_los(from, cell):
				return "no line of sight"
		_: # yourself, or nothing to aim
			if not on_me:
				return "-"
	if ctx["me"].get("maimed", false) and sk.is_attack_or_skill():
		return "maimed: no attacks or skills"
	if (ctx["planned"] as Array).has(sk.id) and sk.once_per_turn():
		return "already planned this round"
	if sk.total_ap() > int(ctx["ap_left"]):
		return "needs %d AP, %d left" % [sk.total_ap(), ctx["ap_left"]]
	return ""


static func _option(ctx: Dictionary, sk: SkillDef, label: String, problem: String, armor: int, cell: Vector2i, unit_id: String) -> Dictionary:
	return {"kind": "skill", "id": sk.id, "label": label, "ap": sk.total_ap(), "enabled": problem == "", "reason": problem,
		"summary": TargetingPreview.effect_summary(sk, int(ctx["me"].get("power", 0)), armor, ctx["cfg"]),
		"hint": sk.description if sk.description != "" else sk.hint, "cell": cell, "unit": unit_id, "icon": sk.icon}


static func _move_option(ctx: Dictionary, sk: SkillDef) -> Dictionary:
	var bf: Battlefield = ctx["bf"]
	var from: Vector2i = ctx["from"]
	var cell: Vector2i = ctx["cell"]
	var res := Pathfinder.search(bf, from, ctx["blocked"], 1)
	var path := Pathfinder.path_to(res, from, cell)
	var cost := 0
	var problem := ""
	if path.is_empty():
		problem = "no path there"
	else:
		cost = Pathfinder.ap_cost(bf, path, int(ctx["me"]["tiles_per_ap"]), 1)
		if cost > int(ctx["ap_left"]):
			problem = "needs %d AP, %d left" % [cost, ctx["ap_left"]]
	return {"kind": "move", "id": sk.id, "label": "Move here", "ap": cost, "enabled": problem == "", "reason": problem,
		"summary": "%d tile%s" % [path.size(), "" if path.size() == 1 else "s"] if not path.is_empty() else "",
		"hint": sk.description if sk.description != "" else sk.hint, "cell": cell, "unit": "", "path": path}
