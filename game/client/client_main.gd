extends Control
## Browser/desktop client: connection screen, 3D board (BoardHolder in client_main.tscn), planning UI and combat log.
## The client only builds and previews plans; the server validates and resolves everything.
##   Optional command-line args (after `--`): --url=ws://host:9080 --name=Alice

const SKILL_HINTS := {
	"move": "Click a tile to queue a move",
	"strike": "Click an enemy", "power_strike": "Click an enemy (2 stages)",
	"bolt": "Click a tile (it hits whoever stands there)",
	"disrupt": "Queued immediately: reacts to an enemy starting a multi-stage skill",
	"revive": "Click a downed ally",
}

var net: NetClient
var skills: SkillDb
var snap: Dictionary = {}
var me: Dictionary = {}
var plan: Array[Dictionary] = []
var _plan_round: int = -1
var _prev_plan: Array[Dictionary] = []
var mode: String = ""
var _snap_time_ms: int = 0
var _in_battle: bool = false
var _selftest: bool = false
var _selftest_round: int = -1

@onready var board: Board3D = $BoardHolder/Viewport/Board3D
var connect_panel: PanelContainer
var account: AccountFlow
var url_edit: LineEdit
var name_edit: LineEdit
var connect_status: Label
var banner: Label
var status_label: Label
var ap_label: Label
var skill_box: VBoxContainer
var queue_list: ItemList
var ready_btn: Button
var error_label: Label
var log_view: RichTextLabel
var result_label: Label
var _skill_buttons: Dictionary = {}


func _ready() -> void:
	skills = SkillDb.load_file()
	net = NetClient.new()
	add_child(net)
	net.connection_changed.connect(_on_connection)
	net.welcomed.connect(_on_welcome)
	net.snapshot.connect(_on_snapshot)
	net.events.connect(_on_events)
	net.plan_result.connect(_on_plan_result)
	net.notice.connect(func(t: String) -> void: connect_status.text = t)
	net.rejected.connect(func(t: String) -> void:
		connect_status.text = t
		connect_panel.show())
	_build_ui()
	var url := _default_url()
	var nm := "Guest%d" % (randi() % 900 + 100)
	var auto := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--url="):
			url = arg.substr(6)
			auto = true
		elif arg.begins_with("--name="):
			nm = arg.substr(7)
		elif arg.begins_with("--token="): # Supabase access token (API mode); a sign-in UI comes with the web build
			net.access_token = arg.substr(8)
		elif arg == "--selftest": # drives the planning UI programmatically (CI/headless check)
			_selftest = true
	url_edit.text = url
	name_edit.text = nm
	var env := AccountFlow.load_env()
	for arg in OS.get_cmdline_user_args(): # point a desktop client at another stack, e.g. the Docker one
		if arg.begins_with("--api-url="):
			env["api_url"] = arg.substr(10)
		elif arg.begins_with("--server-url="):
			env["server_url"] = arg.substr(13)
	if auto or net.access_token != "":
		if auto:
			_connect()
	elif not env.is_empty():
		_enter_account_mode(env)


func _default_url() -> String:
	if OS.has_feature("web"):
		var proto: String = JavaScriptBridge.eval("window.location.protocol")
		var host: String = JavaScriptBridge.eval("window.location.hostname")
		return ("wss://%s" % host) if proto == "https:" else ("ws://%s:9080" % host)
	return "ws://127.0.0.1:9080"


# ---------- UI construction ----------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.09, 0.11)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	move_child(bg, 0) # behind the board

	board.cell_clicked.connect(_on_cell_clicked)

	var side := PanelContainer.new()
	side.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	side.offset_left = -360
	add_child(side)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	side.add_child(v)
	status_label = Label.new()
	v.add_child(status_label)
	ap_label = Label.new()
	v.add_child(ap_label)
	skill_box = VBoxContainer.new()
	v.add_child(skill_box)
	var face := HBoxContainer.new()
	v.add_child(face)
	var fl := Label.new()
	fl.text = "Facing after move:"
	face.add_child(fl)
	for f in [["N", Enums.Facing.NORTH], ["E", Enums.Facing.EAST], ["S", Enums.Facing.SOUTH], ["W", Enums.Facing.WEST]]:
		var fb := Button.new()
		fb.text = f[0]
		fb.pressed.connect(_set_last_move_facing.bind(f[1]))
		face.add_child(fb)
	queue_list = ItemList.new()
	queue_list.custom_minimum_size = Vector2(0, 110)
	v.add_child(queue_list)
	var row := HBoxContainer.new()
	v.add_child(row)
	var undo := Button.new()
	undo.text = "Undo"
	undo.pressed.connect(_undo)
	row.add_child(undo)
	var clear := Button.new()
	clear.text = "Clear"
	clear.pressed.connect(_clear_plan)
	row.add_child(clear)
	ready_btn = Button.new()
	ready_btn.toggle_mode = true
	ready_btn.text = "Ready"
	ready_btn.toggled.connect(_on_ready_toggled)
	row.add_child(ready_btn)
	error_label = Label.new()
	error_label.modulate = Color(1, 0.5, 0.4)
	error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(error_label)
	log_view = RichTextLabel.new()
	log_view.bbcode_enabled = true
	log_view.scroll_following = true
	log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_view.custom_minimum_size = Vector2(0, 200)
	v.add_child(log_view)

	banner = Label.new()
	banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	banner.modulate = Color(1, 0.7, 0.3)
	add_child(banner)
	result_label = Label.new()
	result_label.add_theme_font_size_override("font_size", 48)
	result_label.set_anchors_preset(Control.PRESET_CENTER)
	result_label.offset_left = -500
	result_label.offset_right = 0
	add_child(result_label)

	connect_panel = PanelContainer.new()
	connect_panel.set_anchors_preset(Control.PRESET_CENTER)
	connect_panel.custom_minimum_size = Vector2(420, 0)
	connect_panel.offset_left = -210
	connect_panel.offset_top = -110
	add_child(connect_panel)
	var cv := VBoxContainer.new()
	connect_panel.add_child(cv)
	var title := Label.new()
	title.text = "Unnamed — connect to server"
	cv.add_child(title)
	url_edit = LineEdit.new()
	cv.add_child(url_edit)
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Display name"
	cv.add_child(name_edit)
	var cb := Button.new()
	cb.text = "Connect"
	cb.pressed.connect(_connect)
	cv.add_child(cb)
	connect_status = Label.new()
	connect_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	cv.add_child(connect_status)


## Replaces the guest connect screen with Supabase sign-in, world and character selection.
func _enter_account_mode(env: Dictionary) -> void:
	connect_panel.queue_free()
	account = AccountFlow.new()
	add_child(account)
	account.setup(env)
	connect_panel = account
	connect_status = account.status
	account.entered.connect(func(server_url: String, token: String, display_name: String) -> void:
		net.access_token = token
		net.start(server_url, display_name))
	account.token_refreshed.connect(func(token: String) -> void: net.access_token = token)
	account.backed_out.connect(func() -> void: net.stop())


func _connect() -> void:
	connect_status.text = "Connecting…"
	net.start(url_edit.text.strip_edges(), name_edit.text.strip_edges())


# ---------- Network events ----------

func _on_connection(ok: bool) -> void:
	banner.text = "" if ok else "Connection lost — reconnecting…"
	if ok:
		connect_status.text = "Connected. Waiting for the party…"


func _on_welcome(info: Dictionary) -> void:
	_in_battle = info["in_battle"]
	log_view.clear() # the server replays the visible history after (re)connecting
	_plan_round = -1
	if not _in_battle:
		connect_panel.show()


func _on_snapshot(s: Dictionary) -> void:
	snap = s
	_snap_time_ms = Time.get_ticks_msec()
	connect_panel.hide()
	me = {}
	for u: Dictionary in s["units"]:
		if u["id"] == s["you"]:
			me = u
	if s["round"] != _plan_round:
		_plan_round = s["round"]
		plan.clear()
		for d: Dictionary in s["plan"]:
			var copy := d.duplicate()
			copy.erase("reserved")
			plan.append(copy)
		_prev_plan = plan.duplicate(true)
		mode = ""
	board.set_snapshot(s)
	_refresh()
	if _selftest:
		_run_selftest()


func _on_events(list: Array) -> void:
	for e: Dictionary in list:
		var col := "#c8c8c8"
		match e["type"]:
			"hit", "eliminated", "downed": col = "#ff7b6b"
			"miss", "skip", "cancel", "move_stop": col = "#9a9a9a"
			"interrupt", "reaction", "reaction_ready": col = "#ffcf5a"
			"revived": col = "#7be08a"
			"round_start", "resolution_start": col = "#7fb2ff"
			"victory": col = "#ffffff"
		log_view.append_text("[color=%s]%s[/color]\n" % [col, e["text"]])


func _on_plan_result(ok: bool, err: String) -> void:
	error_label.text = "" if ok else err
	if ok:
		_prev_plan = plan.duplicate(true)
	else:
		plan = _prev_plan.duplicate(true) # the server kept the previous valid plan
		_refresh()


# ---------- Planning ----------

func _can_edit() -> bool:
	return not snap.is_empty() and snap["phase"] == Enums.RoundPhase.PLANNING and not me.is_empty() \
		and me["active"] and not me["ready"]


func _predicted_cell() -> Vector2i:
	var c: Vector2i = me["cell"]
	for a in plan:
		if a["skill"] == "move":
			c = (a["path"] as Array).back()
	return c


func _action_cost(a: Dictionary) -> int:
	var sk := skills.get_skill(a["skill"])
	if sk.kind == Enums.SkillKind.MOVE:
		var path: Array[Vector2i] = []
		path.assign(a["path"])
		return Pathfinder.ap_cost(board.bf, path, me["tiles_per_ap"], 1)
	return sk.total_ap()


func _plan_cost() -> int:
	var t := 0
	for a in plan:
		t += _action_cost(a)
	return t


func _push_plan() -> void:
	var out: Array = []
	for a in plan:
		out.append(a)
	net.send_plan(out)
	_refresh()


func _on_cell_clicked(cell: Vector2i, unit_id: String) -> void:
	if not _can_edit() or mode == "":
		return
	var sk := skills.get_skill(mode)
	_prev_plan = plan.duplicate(true)
	if sk.kind == Enums.SkillKind.MOVE:
		var blocked := {}
		for u: Dictionary in snap["units"]:
			if u["life"] != Enums.LifeState.ELIMINATED:
				blocked[u["cell"]] = true
		var start := _predicted_cell()
		blocked.erase(start)
		var res := Pathfinder.search(board.bf, start, blocked, 1)
		var path := Pathfinder.path_to(res, start, cell)
		if path.is_empty():
			error_label.text = "No path to that tile"
			return
		var prev := start if path.size() == 1 else path[path.size() - 2]
		plan.append({"skill": "move", "path": path,
			"facing": Enums.facing_from_delta(path.back() - prev)})
	elif sk.targeting == Enums.Targeting.CHARACTER:
		if unit_id == "":
			return
		plan.append({"skill": mode, "target": unit_id})
	elif sk.targeting == Enums.Targeting.TILE:
		plan.append({"skill": mode, "cell": cell})
	else:
		return
	error_label.text = ""
	_push_plan()


func _on_skill_pressed(id: String) -> void:
	if not _can_edit():
		return
	var sk := skills.get_skill(id)
	if sk.kind == Enums.SkillKind.REACTION:
		_prev_plan = plan.duplicate(true)
		plan.append({"skill": id})
		_push_plan()
		return
	mode = id
	error_label.text = SKILL_HINTS.get(id, "")
	_refresh()


func _set_last_move_facing(f: int) -> void:
	if _can_edit() and not plan.is_empty() and plan.back()["skill"] == "move":
		_prev_plan = plan.duplicate(true)
		plan.back()["facing"] = f
		_push_plan()


func _undo() -> void:
	if _can_edit() and not plan.is_empty():
		_prev_plan = plan.duplicate(true)
		plan.pop_back()
		_push_plan()


func _clear_plan() -> void:
	if _can_edit():
		_prev_plan = plan.duplicate(true)
		plan.clear()
		_push_plan()


func _on_ready_toggled(pressed: bool) -> void:
	if snap.is_empty() or snap["phase"] != Enums.RoundPhase.PLANNING or me.is_empty():
		return
	if pressed == me["ready"]:
		return
	net.send_ready(pressed)


# ---------- Display ----------

func _unit_name(id: String) -> String:
	for u: Dictionary in snap.get("units", []):
		if u["id"] == id:
			return u["name"]
	return id


func _refresh() -> void:
	if snap.is_empty():
		return
	var phase_names := ["Planning", "Resolving", "Finished"]
	var secs := ""
	if snap.get("timer_ms", -1) >= 0:
		secs = "  (%ds)" % maxi(0, ceili((snap["timer_ms"] - (Time.get_ticks_msec() - _snap_time_ms)) / 1000.0))
	status_label.text = "Round %d — %s%s   Beat %d/%d" % [snap["round"], phase_names[snap["phase"]], secs,
		snap["beat"], snap["beats_per_round"]]
	if snap["eliminated"]:
		status_label.text += "\nYou were eliminated — spectating."
	elif not me.is_empty() and me["life"] == Enums.LifeState.DOWNED:
		status_label.text += "\nYou are downed. An ally can revive you once."
	elif not me.is_empty() and not me["active"]:
		status_label.text += "\nRevived: you cannot act this round."
	if not me.is_empty():
		var cap: int = me["ap_capacity"]
		if snap["phase"] == Enums.RoundPhase.PLANNING:
			ap_label.text = "AP: %d planned / %d" % [_plan_cost(), cap]
			ap_label.modulate = Color(1, 0.5, 0.4) if _plan_cost() > cap else Color.WHITE
		else:
			ap_label.text = "AP: %d spent, %d reserved, %d forfeited / %d" % [
				me["ap_spent"], me["ap_reserved"], me["ap_forfeited"], cap]
			ap_label.modulate = Color.WHITE
		_rebuild_skill_buttons()
	queue_list.clear()
	for a in plan:
		var sk := skills.get_skill(a["skill"])
		var txt := sk.display_name
		if a["skill"] == "move":
			txt += " %d tile(s)" % (a["path"] as Array).size()
		elif a.has("target"):
			txt += " → " + _unit_name(a["target"])
		elif a.has("cell"):
			txt += " → %s" % str(a["cell"])
		queue_list.add_item("%s  [%d AP]" % [txt, _action_cost(a)])
	board.plan_cells.clear()
	board.plan_marks.clear()
	for a in plan:
		if a["skill"] == "move":
			for c: Vector2i in a["path"]:
				board.plan_cells.append(c)
		elif a.has("cell"):
			board.plan_marks.append(a["cell"])
		elif a.has("target"):
			for u: Dictionary in snap["units"]:
				if u["id"] == a["target"]:
					board.plan_marks.append(u["cell"])
	var can := _can_edit()
	ready_btn.disabled = me.is_empty() or snap["phase"] != Enums.RoundPhase.PLANNING or not me.get("active", false)
	ready_btn.set_pressed_no_signal(not me.is_empty() and me["ready"])
	ready_btn.text = "Withdraw Ready" if ready_btn.button_pressed else "Ready"
	for id: String in _skill_buttons:
		(_skill_buttons[id] as Button).disabled = not can
		(_skill_buttons[id] as Button).set_pressed_no_signal(id == mode)
	var outcome := {Enums.Outcome.PLAYERS_WIN: "VICTORY", Enums.Outcome.PLAYERS_LOSE: "DEFEAT",
		Enums.Outcome.DRAW: "DRAW"}.get(snap["outcome"], "") as String
	result_label.text = outcome


func _rebuild_skill_buttons() -> void:
	var ids: Array = me.get("skills", [])
	if ids.hash() == _skill_buttons.keys().hash() and not _skill_buttons.is_empty():
		return
	for ch in skill_box.get_children():
		ch.queue_free()
	_skill_buttons.clear()
	for id: String in ids:
		var sk := skills.get_skill(id)
		var b := Button.new()
		b.toggle_mode = true
		b.text = "%s  (%d AP)" % [sk.display_name, sk.total_ap()] if sk.kind != Enums.SkillKind.MOVE else "Move  (1 AP per %d tile(s))" % me["tiles_per_ap"]
		b.tooltip_text = SKILL_HINTS.get(id, "")
		b.pressed.connect(_on_skill_pressed.bind(id))
		skill_box.add_child(b)
		_skill_buttons[id] = b


func _process(_delta: float) -> void:
	if not snap.is_empty() and snap.get("timer_ms", -1) >= 0:
		_refresh()


func _run_selftest() -> void:
	if snap["phase"] == Enums.RoundPhase.FINISHED:
		print("[selftest] finished: %s" % result_label.text)
		get_tree().quit(0)
		return
	if snap["phase"] != Enums.RoundPhase.PLANNING or _selftest_round == snap["round"] or not _can_edit():
		return
	_selftest_round = snap["round"]
	_on_skill_pressed("move")
	var target: Vector2i = me["cell"] + Vector2i(1, 0)
	_on_cell_clicked(target, "")
	print("[selftest] round %d queued: %s (AP %d/%d)" % [snap["round"], str(plan), _plan_cost(), me["ap_capacity"]])
	if me["skills"].has("disrupt") and snap["round"] == 1:
		_on_skill_pressed("disrupt")
	_on_ready_toggled(true)
