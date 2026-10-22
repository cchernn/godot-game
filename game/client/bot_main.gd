extends Node
## Headless scripted player used for end-to-end checks: connects as a guest, plans a simple
## advance-and-strike turn each round, and reports what it sees. Not part of the shipped client.
##   --url=ws://127.0.0.1:9080 --name=Bot1 [--drop-at-round=2]

var net: NetClient
var skills: SkillDb
var snap: Dictionary = {}
var _planned_round: int = -1
var _dropped: bool = false
var _drop_round: int = -1
var _drop_plan_round: int = -1
var _dropped_plan: bool = false
var _welcomes: int = 0
var _finished: bool = false


func _ready() -> void:
	skills = SkillDb.load_file()
	var url := "ws://127.0.0.1:9080"
	var nm := "Bot"
	var access := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--url="):
			url = arg.substr(6)
		elif arg.begins_with("--name="):
			nm = arg.substr(7)
		elif arg.begins_with("--token="):
			access = arg.substr(8)
		elif arg.begins_with("--drop-at-planning="):
			_drop_plan_round = int(arg.get_slice("=", 1))
		elif arg.begins_with("--drop-at-round="):
			_drop_round = int(arg.get_slice("=", 1))
	net = NetClient.new()
	net.persist_token = false
	net.access_token = access
	add_child(net)
	net.welcomed.connect(func(i: Dictionary) -> void:
		_welcomes += 1
		print("[%s] welcomed #%d as %s" % [nm, _welcomes, i["combatant_id"]]))
	net.notice.connect(func(t: String) -> void: print("[%s] notice: %s" % [nm, t]))
	net.rejected.connect(func(t: String) -> void:
		print("[%s] rejected: %s" % [nm, t])
		if t.begins_with("Sign-in failed") or t.begins_with("Create a character") or t.begins_with("Guest access"):
			get_tree().create_timer(0.3).timeout.connect(func() -> void: get_tree().quit(3)))
	net.plan_result.connect(func(ok: bool, e: String) -> void:
		if not ok:
			print("[%s] plan error: %s" % [nm, e]))
	net.events.connect(func(list: Array) -> void:
		for e: Dictionary in list:
			print("[%s] LOG r%d b%d %s" % [nm, e["round"], e["beat"], e["text"]]))
	net.snapshot.connect(_on_snapshot)
	net.start(url, nm)
	# Safety net so a stuck run never hangs CI.
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("[%s] TIMEOUT" % nm)
		get_tree().quit(2))


func _on_snapshot(s: Dictionary) -> void:
	snap = s
	var me := _me()
	if _drop_round > 0 and not _dropped and s["round"] == _drop_round and s["phase"] == Enums.RoundPhase.RESOLVING:
		_dropped = true
		print("[%s] dropping connection mid-resolution (round %d beat %d)" % [name, s["round"], s["beat"]])
		net.simulate_drop()
		return
	if _drop_plan_round > 0 and not _dropped_plan and s["round"] == _drop_plan_round \
			and s["phase"] == Enums.RoundPhase.PLANNING and not me.is_empty() and me["ready"]:
		_dropped_plan = true
		print("[%s] dropping connection during planning (round %d, plan locked: %s)" % [name, s["round"], str(s["plan"])])
		net.simulate_drop()
		return
	if s["phase"] == Enums.RoundPhase.FINISHED and not _finished:
		_finished = true
		print("[bot] FINISHED outcome=%d round=%d me=%s" % [s["outcome"], s["round"], str(me.get("hp", "-"))])
		get_tree().create_timer(0.5).timeout.connect(func() -> void: get_tree().quit(0))
		return
	if s["phase"] == Enums.RoundPhase.PLANNING and _planned_round != s["round"] and not me.is_empty() \
			and me["active"] and not me["ready"]:
		_planned_round = s["round"]
		net.send_plan(_make_plan(s, me))
		net.send_ready(true)
	elif s["phase"] == Enums.RoundPhase.PLANNING and _planned_round == s["round"] and not me.is_empty() and me["ready"] == false and me["active"]:
		net.send_ready(true) # e.g. after a reconnect


func _me() -> Dictionary:
	for u: Dictionary in snap.get("units", []):
		if u["id"] == snap["you"]:
			return u
	return {}


func _make_plan(s: Dictionary, me: Dictionary) -> Array:
	var bf := Battlefield.from_arrays(s["map"]["w"], s["map"]["h"], s["map"]["terrain"], s["map"]["elev"])
	var enemies: Array[Dictionary] = []
	var blocked := {}
	for u: Dictionary in s["units"]:
		blocked[u["cell"]] = true
		if u["team"] == Enums.Team.ENEMIES and u["life"] != Enums.LifeState.ELIMINATED:
			enemies.append(u)
	var cell: Vector2i = me["cell"]
	var plan: Array = []
	var goal := Vector2i(bf.width - 2, bf.height / 2)
	var target: Dictionary = {}
	if not enemies.is_empty():
		enemies.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return Enums.manhattan(a["cell"], cell) < Enums.manhattan(b["cell"], cell))
		target = enemies[0]
		goal = target["cell"]
	var res := Pathfinder.search(bf, cell, blocked, 1)
	var best := cell
	var best_d := Enums.manhattan(cell, goal)
	var budget: int = me["ap_capacity"] - (1 if not target.is_empty() else 0)
	for c: Vector2i in (res["cost"] as Dictionary).keys():
		var p := Pathfinder.path_to(res, cell, c)
		if Pathfinder.ap_cost(bf, p, me["tiles_per_ap"], 1) > budget:
			continue
		var d := Enums.manhattan(c, goal)
		if d < best_d:
			best_d = d
			best = c
	if best != cell:
		plan.append({"skill": "move", "path": Pathfinder.path_to(res, cell, best)})
	if not target.is_empty():
		plan.append({"skill": "strike", "target": target["id"]})
	return plan
