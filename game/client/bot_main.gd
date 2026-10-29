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
var _escape_round: int = -1
var _escaped: bool = false
## --event: play a story or a chain of steps (stories and battles) to the end instead of stopping after one battle.
var _multi: bool = false
var _timeout: float = 150.0
var _pick: int = 0 # --story-choice=n: which option to take at a story choice
var _name: String = "Bot"
var _last_slide: String = ""


func _ready() -> void:
	skills = SkillDb.load_file()
	var url := "ws://127.0.0.1:9080"
	var nm := "Bot"
	var access := ""
	var world := ""
	var party := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--url="):
			url = arg.substr(6)
		elif arg.begins_with("--name="):
			nm = arg.substr(7)
		elif arg.begins_with("--token="):
			access = arg.substr(8)
		elif arg.begins_with("--world-id="):
			world = arg.substr(11)
		elif arg.begins_with("--instance-id="):
			party = arg.substr(14)
		elif arg.begins_with("--drop-at-planning="):
			_drop_plan_round = int(arg.get_slice("=", 1))
		elif arg.begins_with("--escape-at-round="):
			_escape_round = int(arg.get_slice("=", 1))
		elif arg == "--event":
			_multi = true
		elif arg.begins_with("--timeout="):
			_timeout = float(arg.get_slice("=", 1))
		elif arg.begins_with("--story-choice="):
			_pick = int(arg.get_slice("=", 1))
		elif arg.begins_with("--drop-at-round="):
			_drop_round = int(arg.get_slice("=", 1))
	_name = nm
	net = NetClient.new()
	net.persist_token = false
	net.access_token = access
	net.world_id = world
	net.instance_id = party
	add_child(net)
	net.welcomed.connect(func(i: Dictionary) -> void:
		_welcomes += 1
		_planned_round = -1 # a new step may start at round 1 again
		print("[%s] welcomed #%d as %s" % [nm, _welcomes, i["combatant_id"]]))
	net.notice.connect(func(t: String) -> void: print("[%s] notice: %s" % [nm, t]))
	net.lobby.connect(func(i: Dictionary) -> void: print("[%s] lobby: %s (need %d)" % [nm, str(i["players"]), i["needed"]]))
	net.result.connect(func(i: Dictionary) -> void:
		print("[bot] RESULT %s you=%s saved=%s rewards=%s" % [i["outcome"], i["you"], str(i["saved"]), str(i.get("rewards", {}))])
		if _multi and i["saved"] and ["story_complete", "event_complete", "event_failed"].has(i["outcome"]):
			get_tree().create_timer(0.5).timeout.connect(func() -> void: get_tree().quit(0)))
	net.story.connect(_on_story)
	net.rejected.connect(func(t: String) -> void:
		print("[%s] rejected: %s" % [nm, t])
		if t.begins_with("Sign-in failed") or t.begins_with("Create a character") or t.begins_with("Guest access") \
				or t.begins_with("Choose a world") or t.begins_with("Choose a party") or t.begins_with("This server does not"):
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
	get_tree().create_timer(_timeout).timeout.connect(func() -> void:
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
	if _escape_round > 0 and not _escaped and s["round"] == _escape_round and s["phase"] == Enums.RoundPhase.PLANNING and not me.is_empty():
		_escaped = true
		print("[%s] escaping (round %d)" % [name, s["round"]])
		net.send_escape()
		return
	if _escaped and not s.get("escaped", false) and s["phase"] != Enums.RoundPhase.FINISHED:
		print("[%s] ERROR still in the fight after escaping" % name)
	if s["phase"] == Enums.RoundPhase.FINISHED and _multi:
		return # one step of a longer run is over; the next one (or the final result) follows
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
	var attack := ""
	for id: String in me.get("skills", []):
		var sk := skills.get_skill(id)
		if sk != null and sk.slot() == Enums.ActionSlot.ATTACK:
			attack = id
			break
	if not target.is_empty() and attack != "":
		plan.append({"skill": attack, "target": target["id"]})
	return plan


## Reads each slide the server shows and presses Continue, or picks an option when the slide offers choices and this bot is the leader.
func _on_story(state: Dictionary) -> void:
	if state["finished"]:
		return
	var story := StoryDef.load_story(str(state["story"]))
	if story == null:
		print("[%s] ERROR unknown story %s" % [_name, state["story"]])
		return
	var slide := story.slides[(state["path"] as Array).back() as int]
	if _last_slide != "%s/%s" % [state["story"], str((state["path"] as Array).size())]:
		_last_slide = "%s/%s" % [state["story"], str((state["path"] as Array).size())]
		print("[%s] STORY %s: %s" % [_name, slide.actor.display_name if slide.actor != null else "-", slide.text.left(60)])
	if not slide.choices.is_empty():
		if state["can_choose"]:
			net.send_story_choice(slide.choices[mini(_pick, slide.choices.size() - 1)].id)
	elif not state["you_continued"]:
		net.send_story_continue()
