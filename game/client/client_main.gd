extends Control
## Browser/desktop client: connection screen, 3D board, planning UI and combat log. All of the layout is in
## client_main.tscn (and account_flow.tscn); this script only fills it in and reacts to it.
## The client only builds and previews plans; the server validates and resolves everything.
##   Optional command-line args (after `--`): --url=ws://host:9080 --name=Alice

## The strip of cards under the board (game/content/ui/unit_card.tscn): your party, and the enemies in sight.
@export var unit_card_scene: PackedScene
## The abilities list in the side panel is made of this scene (game/content/ui/action_button.tscn), one per ability.
@export var action_button_scene: PackedScene
## Turn off to always use the plain guest connect screen, even when client_env.json exists.
@export var account_mode_enabled: bool = true

var net: NetClient
var skills: SkillDb
var snap: Dictionary = {}
var me: Dictionary = {}
var plan: Array[Dictionary] = []
var _plan_round: int = -1
## Planning countdown colours: amber at or under the first, red at or under the second (seconds).
@export var timer_warn_seconds: int = 30
@export var timer_urgent_seconds: int = 10
var _log_round: int = -1
var _log_beat: int = -1
var _round_tally: Dictionary = {}
var _prev_plan: Array[Dictionary] = []
## Where the action menu was opened (-1, -1 when it is closed), who stood there, and the entry under the mouse.
var _menu_cell: Vector2i = Vector2i(-1, -1)
var _menu_unit: String = ""
var _preview: Dictionary = {}
## The ability picked in the list (its reach stays shaded and the next click on a valid target queues it), or "".
var _armed: String = ""
var _ability_sig: int = 0
var _card_text: String = ""
var _cfg: GameConfig
var _snap_time_ms: int = 0
var _in_battle: bool = false
var _selftest: bool = false
var _selftest_round: int = -1
var _objects_map: String = "<unset>"
## Escape asks twice (a second press within this many seconds confirms), so a stray click cannot abandon the fight.
@export var escape_confirm_seconds: float = 4.0
var _escape_armed_until_ms: int = 0
var _state: String = "menu"
var _last_hover: Vector2i = Vector2i(-1, -1)
var _preview_sig: int = 0

# The layout lives in client_main.tscn; nodes are found by their unique names (%Name), so
# you can move or restyle them in the editor as long as the names stay.
@onready var board: Board3D = $BoardHolder/Viewport/Board3D
@onready var account: AccountFlow = %AccountFlow
@onready var url_edit: LineEdit = %UrlEdit
@onready var name_edit: LineEdit = %NameEdit
@onready var menu_background: MenuBackground = %MenuBackground
@onready var banner: Label = %Banner
@onready var status_label: Label = %StatusLabel
@onready var ap_label: Label = %ApLabel
@onready var queue_list: ItemList = %QueueList
@onready var ready_btn: Button = %ReadyButton
@onready var escape_btn: Button = %RetreatButton
@onready var menu: ActionMenu = %ActionMenu
@onready var ability_list: GridContainer = %AbilityList
@onready var hover_card: HoverCard = %HoverCard
@onready var facing_row: Control = %FacingRow
@onready var error_label: Label = %ErrorLabel
@onready var log_view: RichTextLabel = %LogView
@onready var board_holder: Control = %BoardHolder
@onready var side_panel: Control = %SidePanel
@onready var hover_label: Label = %HoverLabel
@onready var beats_label: Label = %BeatsLabel
@onready var unit_strip: Control = %UnitStrip
@onready var party_cards: HBoxContainer = %PartyCards
@onready var enemy_cards: HBoxContainer = %EnemyCards
@onready var story_player: StoryPlayer = %StoryPlayer
## Party chat, over the top left of the lobby, story and battle screens.
@onready var party_chat: ChatPanel = %PartyChat
@onready var result_panel: Control = %ResultPanel
@onready var result_title: Label = %ResultTitle
@onready var result_detail: Label = %ResultDetail
## The panel in the middle of the screen: the guest connect screen, or the account flow.
var connect_panel: Control
var connect_status: Label


func _ready() -> void:
	skills = SkillDb.load_file()
	_cfg = GameConfig.load_file()
	net = NetClient.new()
	add_child(net)
	connect_panel = %ConnectPanel
	connect_status = %ConnectStatus
	net.connection_changed.connect(_on_connection)
	net.welcomed.connect(_on_welcome)
	net.snapshot.connect(_on_snapshot)
	net.events.connect(_on_events)
	net.plan_result.connect(_on_plan_result)
	net.notice.connect(func(t: String) -> void:
		connect_status.text = t
		if _state == "battle" or _state == "story":
			banner.text = t) # e.g. an event's "the way ahead opens"; cleared when the next step begins
	net.lobby.connect(_on_lobby)
	net.result.connect(_on_result)
	net.story.connect(_on_story)
	net.chat.connect(_on_chat)
	party_chat.submitted.connect(func(text: String) -> void: net.send_chat(text))
	story_player.continue_pressed.connect(func() -> void: net.send_story_continue())
	story_player.choice_chosen.connect(func(id: String) -> void: net.send_story_choice(id))
	net.rejected.connect(func(t: String) -> void:
		_set_state("menu")
		_set_battle_view(false)
		connect_status.text = t
		connect_panel.show())
	_wire_ui()
	var url := _default_url()
	var nm := "Guest%d" % (randi() % 900 + 100)
	var auto := false
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--url="):
			url = arg.substr(6)
			auto = true
		elif arg.begins_with("--name="):
			nm = arg.substr(7)
		elif arg.begins_with("--token="): # Supabase access token (API mode), for scripted runs
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
	elif account_mode_enabled and not env.is_empty():
		_enter_account_mode(env)


func _default_url() -> String:
	if OS.has_feature("web"):
		var proto: String = JavaScriptBridge.eval("window.location.protocol")
		var host: String = JavaScriptBridge.eval("window.location.hostname")
		return ("wss://%s" % host) if proto == "https:" else ("ws://%s:9080" % host)
	return "ws://127.0.0.1:9080"


## Connects the scene's buttons to the game logic.
func _wire_ui() -> void:
	board.cell_clicked.connect(_on_cell_clicked)
	%FaceNorth.pressed.connect(_set_last_move_facing.bind(Enums.Facing.NORTH))
	%FaceEast.pressed.connect(_set_last_move_facing.bind(Enums.Facing.EAST))
	%FaceSouth.pressed.connect(_set_last_move_facing.bind(Enums.Facing.SOUTH))
	%FaceWest.pressed.connect(_set_last_move_facing.bind(Enums.Facing.WEST))
	%UndoButton.pressed.connect(_undo)
	%ClearButton.pressed.connect(_clear_plan)
	ready_btn.toggled.connect(_on_ready_toggled)
	escape_btn.pressed.connect(_on_escape_pressed)
	menu.chosen.connect(_on_option_chosen)
	menu.previewed.connect(_on_option_previewed)
	menu.closed.connect(_on_menu_closed)
	%ConnectButton.pressed.connect(_connect)
	%ContinueButton.pressed.connect(_on_continue_pressed)
	_set_battle_view(false)
	_set_state("menu")
	banner.text = ""
	status_label.text = ""
	ap_label.text = ""
	error_label.text = ""
	connect_status.text = ""


## Replaces the guest connect screen with Supabase sign-in, world and character selection.
func _enter_account_mode(env: Dictionary) -> void:
	connect_panel.hide()
	account.show()
	account.setup(env)
	connect_panel = account
	connect_status = account.status.menu
	account.entered.connect(func(server_url: String, token: String, display_name: String, world_id: String, instance_id: String) -> void:
		net.access_token = token
		net.world_id = world_id
		net.instance_id = instance_id
		net.start(server_url, display_name))
	account.token_refreshed.connect(func(token: String) -> void: net.access_token = token)
	account.backed_out.connect(func() -> void:
		net.stop()
		_set_state("menu"))


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
	_log_round = -1
	_log_beat = -1
	_round_tally.clear()
	_plan_round = -1
	banner.text = ""
	board.reset() # an event's next battle starts on a clean board
	if not _in_battle:
		connect_panel.show()


func _on_snapshot(s: Dictionary) -> void:
	snap = s
	_snap_time_ms = Time.get_ticks_msec()
	connect_panel.hide()
	_set_battle_view(true)
	if _state != "result":
		_set_state("battle")
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
		menu.close()
		_armed = ""
	_register_map_objects(str(s["map"].get("id", "")))
	board.set_snapshot(s)
	_refresh()
	if _selftest:
		_run_selftest()


## The map objects' actions are skills too ("ctx:<object>:<action>"); the client reads the same map scene as the server to know them.
func _register_map_objects(map_id: String) -> void:
	if map_id == _objects_map:
		return
	_objects_map = map_id
	if map_id == "" or map_id.length() > 40 or not ResourceLoader.exists(Board3D.MAP_DIR + map_id + ".tscn"):
		return
	for o: Dictionary in MapDef.load_scene(Board3D.MAP_DIR + map_id + ".tscn").objects:
		skills.add_context(o["id"], o["def"])


func _on_events(list: Array) -> void:
	var slots := {} # unit id -> floating texts already started for it in this batch
	for e: Dictionary in list:
		var round_no: int = e.get("round", 0)
		var beat_no: int = e.get("beat", 0)
		if e["type"] == "round_start":
			_append_recap()
		elif beat_no > 0 and (round_no != _log_round or beat_no != _log_beat):
			log_view.append_text("[color=#6f7a8c]— Round %d · Beat %d —[/color]\n" % [round_no, beat_no])
		_log_round = round_no
		_log_beat = beat_no
		_round_tally[e["type"]] = int(_round_tally.get(e["type"], 0)) + 1
		var col := "#c8c8c8"
		match e["type"]:
			"hit", "eliminated", "downed": col = "#ff7b6b"
			"miss", "skip", "cancel", "move_stop": col = "#9a9a9a"
			"interrupt", "reaction", "reaction_ready": col = "#ffcf5a"
			"revived", "heal": col = "#7be08a"
			"shield": col = "#7fd6ff"
			"status_apply", "stunned": col = "#d9a0ff"
			"status_end": col = "#9a9a9a"
			"round_start", "resolution_start": col = "#7fb2ff"
			"victory": col = "#ffffff"
			"trigger", "wake", "appear": col = "#ffcf5a"
			"removed": col = "#9a9a9a"
		if "unseen" in String(e["text"]):
			col = "#b69af0" # something happened out of sight
		log_view.append_text("[color=%s]%s[/color]\n" % [col, e["text"]])
		board.show_event(e, slots)


## One line summing up the round that just resolved, from the event types seen since the last recap.
func _append_recap() -> void:
	var parts: Array[String] = []
	for t: String in ["hit", "miss", "downed", "eliminated", "revived", "heal", "shield", "interrupt", "stunned"]:
		var n: int = _round_tally.get(t, 0)
		if n > 0:
			parts.append("%d %s" % [n, t])
	_round_tally.clear()
	if not parts.is_empty():
		log_view.append_text("[color=#7fb2ff]Last round: %s[/color]\n" % ", ".join(parts))


## The board and side panel only exist while a battle is on; before and after, the screen is the menu.
func _set_battle_view(on: bool) -> void:
	menu_background.set_playing(not on)
	board_holder.visible = on
	side_panel.visible = on
	unit_strip.visible = on
	if not on:
		result_panel.hide()
	if on:
		story_player.hide()


## Publishes the screen the player is on ("menu", "lobby", "battle", "result") as window.unnamedState in the
## browser, so automated tests can wait for it. Harmless elsewhere.
func _set_state(state: String) -> void:
	_state = state
	party_chat.visible = state != "menu" # party chat is for the party's activity: the lobby, story, battle and result
	if state == "menu":
		party_chat.clear()
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.unnamedState = '%s'" % state)


## A line of party chat: it goes in the log, and over the speaker's head if they are on the board (so only units you can see speak).
func _on_chat(m: Dictionary) -> void:
	var system: bool = m.get("system", false)
	party_chat.add_line(m["from"], m["text"], m["mine"], system)
	if not system and m["unit"] != "" and board_holder.visible:
		board.say(m["unit"], m["text"])


func _on_lobby(info: Dictionary) -> void:
	_set_state("lobby")
	connect_panel.show()
	if account != null and connect_panel == account:
		account.status.text = ""
		account.show_lobby(info)
	else:
		connect_status.text = "Waiting for players (%d/%d): %s" % [(info["players"] as Array).size(), info["needed"],
			", ".join(PackedStringArray(info["players"]))]


## The party's story: the visual-novel screen takes over until the story ends (then the result panel shows what it paid).
func _on_story(state: Dictionary) -> void:
	if _state != "result":
		_set_state("story")
	connect_panel.hide()
	menu_background.set_playing(false)
	board_holder.hide() # an event can lead from a battle into a story
	side_panel.hide()
	unit_strip.hide()
	story_player.show()
	story_player.show_state(state)


func _on_result(info: Dictionary) -> void:
	_set_state("result")
	var titles := {"players_win": "VICTORY", "players_lose": "DEFEAT", "draw": "DRAW", "escaped": "ESCAPED", "story_complete": "STORY COMPLETE",
		"event_complete": "EVENT COMPLETE", "event_failed": "EVENT FAILED"}
	result_title.text = titles.get(info["outcome"], "BATTLE OVER")
	var lines: Array[String] = []
	if not ["story_complete", "event_complete", "event_failed"].has(info["outcome"]):
		lines.append("Round %d" % info["rounds"])
	if info["you"] == "escaped":
		lines.append("You escaped.")
	elif info["you"] != "survived":
		lines.append("You were %s." % info["you"])
	lines.append_array(reward_lines(info.get("rewards", {}), skills))
	result_detail.text = "\n".join(lines)
	result_panel.show()


## What the battle paid this player, one line each: gold, then items by name. (Event flags are not shown; they unlock things quietly.)
static func reward_lines(rewards: Dictionary, db: SkillDb) -> Array[String]:
	var out: Array[String] = []
	if int(rewards.get("gold", 0)) > 0:
		out.append("+%d gold" % int(rewards["gold"]))
	var items: Dictionary = rewards.get("items", {})
	for id: String in items:
		var def: ItemDef = db.items.get(id) if db != null else null
		out.append("+%d %s" % [int(items[id]), def.display_name if def != null else id.replace("_", " ")])
	if not (rewards.get("gear", []) as Array).is_empty():
		var gear := GearSet.load_file()
		for id: String in rewards["gear"]:
			var g := gear.get_gear(id)
			out.append("+ %s" % (g.display_name if g != null else id.replace("_", " ")))
	return out


## Leaves the finished battle and returns to the menu (the character screen when signed in).
func _on_continue_pressed() -> void:
	_set_state("menu")
	story_player.hide()
	story_player.story_id = ""
	net.stop()
	snap = {}
	me = {}
	plan.clear()
	_prev_plan.clear()
	menu.close()
	_armed = ""
	_plan_round = -1
	_in_battle = false
	_objects_map = "<unset>"
	log_view.clear()
	_log_round = -1
	_log_beat = -1
	_round_tally.clear()
	error_label.text = ""
	banner.text = ""
	board.reset()
	_set_battle_view(false)
	connect_panel.show()
	if account != null and connect_panel == account:
		account.return_to_menu()
	else:
		connect_status.text = ""


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
	if sk == null: # a map object this client could not read
		return 0
	if sk.kind == Enums.SkillKind.MOVE:
		var path: Array[Vector2i] = []
		path.assign(a["path"])
		return Pathfinder.ap_cost(board.bf, path, me["tiles_per_ap"], 1)
	return sk.total_ap()


## Beats an action takes in the queue (see TargetingPreview.action_beats).
func _action_beats(a: Dictionary) -> int:
	var path_len := (a["path"] as Array).size() if a["skill"] == "move" else 0
	var sk := skills.get_skill(a["skill"])
	return TargetingPreview.action_beats(sk, path_len, me.get("tiles_per_ap", 1)) if sk != null else 1


## Shades the board: the entry under the mouse in the menu or in the ability list, else the armed ability, else (with a menu open) what the
## clicked target offers, else what is under the mouse. Also fills the hover card and the hint in the side panel.
func _update_overlays() -> void:
	var sig := hash([board.hover, board.hover_unit, _menu_cell, _preview.get("id", ""), _armed, plan, snap["round"], snap["phase"],
		me.get("cell"), me.get("ready"), snap["units"]])
	if sig == _preview_sig:
		return
	_preview_sig = sig
	board.range_cells.clear()
	board.valid_cells.clear()
	board.area_cells.clear()
	board.path_cells.clear()
	board.selected_cell = _menu_cell
	board.selected_unit = _menu_unit
	hover_label.text = ""
	_card_text = ""
	var hovered_cell := board.hover
	var in_bounds := board.bf != null and board.bf.in_bounds(hovered_cell)
	var fog := in_bounds and not board.is_seen(hovered_cell)
	if not _can_edit():
		if not _hover_on_menu() and in_bounds:
			_card_text = _unit_card_text(_unit_at(hovered_cell), false) + ("\n[color=#9a9a9a]Fog: not visible to your team[/color]" if fog else "")
		return
	var from := _predicted_cell()
	var ap_left: int = me["ap_capacity"] - _plan_cost()
	if not _preview.is_empty():
		_show_preview_of_option(from, ap_left)
		return
	if _armed != "":
		_show_armed(from, ap_left, hovered_cell if in_bounds else Vector2i(-1, -1), fog)
		return
	if _menu_cell != Vector2i(-1, -1):
		_show_for_target(from, ap_left, _menu_cell) # the reach and the walk stay on while you pick from the menu
		return
	if _hover_on_menu():
		return
	hover_label.text = "Fog: not visible to your team" if fog else "Click a tile or a unit to choose an action, or pick an ability from the list"
	if in_bounds:
		_card_text = _show_for_target(from, ap_left, hovered_cell) + ("\n[color=#9a9a9a]Fog: not visible to your team[/color]" if fog else "")


## The walk and reach for a tile or unit: where you can walk and the way to an empty tile, or what your basic attack reaches for a unit.
## Returns the hover card text for it.
func _show_for_target(from: Vector2i, ap_left: int, cell: Vector2i) -> String:
	var u := _unit_at(cell)
	var blocked := _blocked_cells(from)
	if u.is_empty():
		board.range_cells.assign(TargetingPreview.reachable(board.bf, from, blocked, me["tiles_per_ap"], 1, ap_left))
		var path := Pathfinder.path_to(Pathfinder.search(board.bf, from, blocked, 1), from, cell)
		board.path_cells.assign(path)
		return _tile_card_text(cell, path, ap_left)
	if u["id"] == me["id"]:
		board.range_cells.assign(TargetingPreview.reachable(board.bf, from, blocked, me["tiles_per_ap"], 1, ap_left))
		return _unit_card_text(u, true)
	var attack := skills.get_skill(_basic_attack_id())
	if attack != null and u["team"] != me["team"]:
		board.range_cells.assign(TargetingPreview.tiles_in_range(board.bf, from, attack.attack_range, attack.requires_los))
		if TargetingPreview.target_problem(board.bf, me, u, attack, from) == "":
			board.valid_cells.append(u["cell"])
	return _unit_card_text(u, true)


## While an ability from the list is armed: its reach and valid targets stay shaded, and over the board you see what a click would do.
func _show_armed(from: Vector2i, ap_left: int, cell: Vector2i, fog: bool) -> void:
	var sk := skills.get_skill(_armed)
	if sk == null:
		return
	_shade_skill(sk, from, ap_left, cell)
	hover_label.text = "%s armed: %s. Esc or click it again to cancel." % [sk.display_name, "click a tile to walk" if sk.kind == Enums.SkillKind.MOVE else sk.hint]
	if cell == Vector2i(-1, -1):
		return
	var u := _unit_at(cell)
	if sk.kind == Enums.SkillKind.MOVE:
		var blocked := _blocked_cells(from)
		var path := Pathfinder.path_to(Pathfinder.search(board.bf, from, blocked, 1), from, cell)
		board.path_cells.assign(path)
		_card_text = _tile_card_text(cell, path, ap_left) if u.is_empty() else _unit_card_text(u, false)
	else:
		_card_text = _unit_card_text(u, true) if not u.is_empty() else ""
	if fog:
		_card_text += "\n[color=#9a9a9a]Fog: not visible to your team[/color]"


## Shades the reach, the targets that can be hit and (aimed at tiles) the area of a skill.
func _shade_skill(sk: SkillDef, from: Vector2i, ap_left: int, aim: Vector2i) -> void:
	if sk.kind == Enums.SkillKind.MOVE:
		board.range_cells.assign(TargetingPreview.reachable(board.bf, from, _blocked_cells(from), me["tiles_per_ap"], 1, ap_left))
		return
	if sk.kind == Enums.SkillKind.REACTION or sk.targeting == Enums.Targeting.SELF or sk.targeting == Enums.Targeting.NONE:
		return
	board.range_cells.assign(TargetingPreview.tiles_in_range(board.bf, from, sk.attack_range, sk.requires_los))
	for id: String in TargetingPreview.valid_targets(board.bf, snap["units"], me, sk, from):
		board.valid_cells.append(_unit_at_id(id).get("cell", Vector2i(-1, -1)))
	if sk.targeting == Enums.Targeting.TILE and aim != Vector2i(-1, -1):
		board.area_cells.assign(TargetingPreview.area_cells(board.bf, sk, from, aim, int(me.get("facing", Enums.Facing.SOUTH))))


## While the menu is open: shades the reach, the valid targets and the area of the entry under the mouse.
func _show_preview_of_option(from: Vector2i, ap_left: int) -> void:
	var sk := skills.get_skill(_preview["id"])
	if sk == null:
		return
	hover_label.text = "%s: %s" % [_preview["label"], _preview["summary"] if _preview["enabled"] else _preview["reason"]]
	_shade_skill(sk, from, ap_left, _menu_cell if _menu_cell != Vector2i(-1, -1) else board.hover)
	if sk.kind == Enums.SkillKind.MOVE:
		board.path_cells.assign(_preview.get("path", []))


## ---------- The ability list ----------

## Your abilities in the order Move, attacks, skills, Defend, then items, each with its cost and, when it cannot be used now, why.
func _ability_entries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var ap_left: int = me["ap_capacity"] - _plan_cost()
	var planned: Array = []
	for a in plan:
		planned.append(a["skill"])
	var ranked: Array[Array] = []
	for id: String in me.get("skills", []):
		var sk := skills.get_skill(id)
		if sk == null:
			continue
		var rank := 0
		match sk.slot():
			Enums.ActionSlot.MOVE: rank = 0
			Enums.ActionSlot.ATTACK: rank = 1
			Enums.ActionSlot.SKILL: rank = 2
			Enums.ActionSlot.DEFEND: rank = 3
		ranked.append([rank, id])
	ranked.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	for pair: Array in ranked:
		var sk := skills.get_skill(pair[1])
		var cost := 1 if sk.kind == Enums.SkillKind.MOVE else sk.total_ap()
		var why := ""
		if sk.kind != Enums.SkillKind.MOVE and me.get("maimed", false) and sk.is_attack_or_skill():
			why = "maimed: no attacks or skills"
		elif sk.kind != Enums.SkillKind.MOVE and planned.has(sk.id) and sk.once_per_turn():
			why = "already planned this round"
		elif cost > ap_left:
			why = "needs %d AP, %d left" % [cost, ap_left]
		var label := "Move  1 AP/%d tile%s" % [me["tiles_per_ap"], "" if me["tiles_per_ap"] == 1 else "s"] if sk.kind == Enums.SkillKind.MOVE else "%s  %d AP" % [sk.display_name, cost]
		out.append({"id": sk.id, "label": label, "name": sk.display_name, "enabled": why == "", "reason": why,
			"summary": TargetingPreview.effect_summary(sk, int(me.get("power", 0)), 0, _cfg),
			"hint": sk.description if sk.description != "" else sk.hint})
	for it: Dictionary in me.get("items", []):
		var sk := skills.get_skill(ItemDef.skill_id_for(it["id"]))
		if sk == null:
			continue
		var left := _items_left(it["id"])
		var why := "none left" if left <= 0 else ("needs %d AP, %d left" % [sk.total_ap(), ap_left] if sk.total_ap() > ap_left else "")
		out.append({"id": sk.id, "label": "%s ×%d  %d AP" % [sk.display_name, left, sk.total_ap()], "name": sk.display_name, "enabled": why == "",
			"reason": why, "summary": TargetingPreview.effect_summary(sk, 0, 0, _cfg), "hint": sk.description if sk.description != "" else sk.hint})
	return out


func _rebuild_abilities() -> void:
	if action_button_scene == null or me.is_empty():
		return
	var entries := _ability_entries()
	var sig := hash([entries, _armed, _can_edit()])
	if sig == _ability_sig:
		return
	_ability_sig = sig
	for ch in ability_list.get_children():
		ability_list.remove_child(ch)
		ch.queue_free()
	var can := _can_edit()
	for e in entries:
		var b := action_button_scene.instantiate() as Button
		b.text = e["label"]
		b.toggle_mode = true
		b.button_pressed = e["id"] == _armed
		b.disabled = not can or not e["enabled"]
		var tip: Array[String] = []
		for part: String in [str(e["hint"]), str(e["summary"]), "" if e["enabled"] else "Not now: %s" % e["reason"]]:
			if part != "":
				tip.append(part)
		b.tooltip_text = "\n".join(tip)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_ability_pressed.bind(e["id"]))
		b.mouse_entered.connect(_on_ability_hover.bind(e))
		b.mouse_exited.connect(_on_ability_hover.bind({}))
		ability_list.add_child(b)


## Hovering an ability shades its reach, like hovering an entry of the menu.
func _on_ability_hover(entry: Dictionary) -> void:
	_preview = entry if not entry.is_empty() and entry["enabled"] else {}
	if not _preview.is_empty():
		_preview = {"id": entry["id"], "label": entry["name"], "summary": entry["summary"], "enabled": true, "reason": ""}
	_preview_sig = 0
	if not snap.is_empty():
		_update_overlays()


## Picking an ability: one that needs no aim is queued at once; any other is armed, and the next click on a valid target queues it.
func _on_ability_pressed(id: String) -> void:
	if not _can_edit():
		return
	var sk := skills.get_skill(id)
	if sk == null:
		return
	menu.close()
	if _armed == id:
		_disarm()
		return
	if sk.kind != Enums.SkillKind.MOVE and (sk.kind == Enums.SkillKind.REACTION or sk.targeting == Enums.Targeting.SELF or sk.targeting == Enums.Targeting.NONE):
		_disarm()
		_prev_plan = plan.duplicate(true)
		plan.append(_new_action(id))
		error_label.text = ""
		_push_plan()
		return
	_armed = id
	error_label.text = ""
	_preview_sig = 0
	_ability_sig = 0
	_refresh()


func _disarm() -> void:
	_armed = ""
	_preview_sig = 0
	_ability_sig = 0
	if not snap.is_empty():
		_refresh()


## A click on the board while an ability is armed: queue it on that target if it is valid, else say why not.
func _use_armed_on(cell: Vector2i, unit_id: String) -> void:
	var pick: Dictionary = {}
	for o in _options_at(cell, unit_id):
		if o["id"] == _armed:
			pick = o
	if pick.is_empty():
		error_label.text = "%s cannot be used on that" % skills.get_skill(_armed).display_name
		return
	if not pick["enabled"]:
		error_label.text = "%s: %s" % [pick["label"], pick["reason"]]
		return
	_disarm()
	_on_option_chosen(pick)


func _unit_at(cell: Vector2i) -> Dictionary:
	for u: Dictionary in snap.get("units", []):
		if u["cell"] == cell and u["life"] != Enums.LifeState.ELIMINATED:
			return u
	return {}


func _unit_at_id(id: String) -> Dictionary:
	for u: Dictionary in snap.get("units", []):
		if u["id"] == id:
			return u
	return {}


## True while the mouse is over the action menu (the board's hover is stale then).
func _hover_on_menu() -> bool:
	return menu.visible and menu.get_global_rect().has_point(get_global_mouse_position())


## The hover card for a unit: name, health, statuses and, for what you could attack, what the basic Attack would do.
func _unit_card_text(u: Dictionary, show_attack: bool) -> String:
	if u.is_empty():
		return ""
	var lines: Array[String] = []
	var hp := "HP %d/%d" % [u["hp"], u["max_hp"]] + ("  +%d shield" % u["shield"] if u["shield"] > 0 else "")
	var side := "[color=#7fb2ff]you[/color]" if u["id"] == me.get("id", "") else ("[color=#ff7b6b]enemy[/color]" if u["team"] != me.get("team", -1) else "[color=#7be08a]ally[/color]")
	lines.append("[b]%s[/b]  %s" % [u["name"], side])
	lines.append(hp)
	for st: Dictionary in u["statuses"]:
		lines.append("[color=#%s]%s %s[/color] (%d turn%s)" % [str(st["color"]), st["glyph"], st["name"], st["turns"], "" if st["turns"] == 1 else "s"])
	if show_attack and u["team"] != me.get("team", -1) and u["life"] != Enums.LifeState.DOWNED:
		var attack := skills.get_skill(_card_attack_id())
		if attack != null:
			var d := Enums.manhattan(_predicted_cell(), u["cell"])
			var dmg := TargetingPreview.damage_range(attack, int(me.get("power", 0)), int(u.get("armor", 0)), _cfg)
			var reach := "in reach" if TargetingPreview.target_problem(board.bf, me, u, attack, _predicted_cell()) == "" else "out of reach (%d tiles, reach %d)" % [d, attack.attack_range]
			lines.append("%s: %s damage, %d AP, %s" % [attack.display_name, str(dmg.x) if dmg.x == dmg.y else "%d-%d" % [dmg.x, dmg.y], attack.total_ap(), reach])
	return "\n".join(lines)


func _tile_card_text(cell: Vector2i, path: Array[Vector2i], ap_left: int) -> String:
	var lines: Array[String] = []
	if board.bf.is_blocked(cell):
		return "Blocked"
	if cell == _predicted_cell():
		return "You will stand here"
	if board.bf.is_difficult(cell):
		lines.append("Difficult terrain (costs more to enter)")
	if path.is_empty():
		lines.append("No way to walk there")
	else:
		var cost := Pathfinder.ap_cost(board.bf, path, me["tiles_per_ap"], 1)
		lines.append("Walk: %d tile%s, %d AP%s" % [path.size(), "" if path.size() == 1 else "s", cost,
			"" if cost <= ap_left else " (%d more than you have)" % (cost - ap_left)])
	return "\n".join(lines)


## The skill the hover card measures an enemy against: the armed ability if it hits something, else your basic attack.
func _card_attack_id() -> String:
	var sk := skills.get_skill(_armed) if _armed != "" else null
	if sk != null and sk.kind != Enums.SkillKind.MOVE and sk.targeting in [Enums.Targeting.CHARACTER, Enums.Targeting.TILE]:
		return _armed
	return _basic_attack_id()


## The id of your basic attack: the first of your skills that sits in the Attack slot.
func _basic_attack_id() -> String:
	return _slot_skill(Enums.ActionSlot.ATTACK)


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


## A click on the board opens the action menu there: every action that makes sense on that tile or unit.
func _on_cell_clicked(cell: Vector2i, unit_id: String) -> void:
	if not _can_edit():
		return
	if _armed != "":
		_use_armed_on(cell, unit_id)
		return
	var opts := _options_at(cell, unit_id)
	if opts.is_empty():
		menu.close()
		error_label.text = "Nothing to do there"
		return
	error_label.text = ""
	var u := _unit_at_id(unit_id)
	var title := str(u["name"]) if not u.is_empty() else "Tile %d, %d" % [cell.x, cell.y]
	menu.close()
	_menu_cell = cell
	_menu_unit = unit_id
	_preview = {}
	menu.open(opts, title, get_local_mouse_position(), Rect2(Vector2.ZERO, size))
	_preview_sig = 0
	_update_overlays()


func _options_at(cell: Vector2i, unit_id: String) -> Array[Dictionary]:
	var left := {}
	for it: Dictionary in me.get("items", []):
		left[it["id"]] = _items_left(it["id"])
	var planned: Array = []
	for a in plan:
		planned.append(a["skill"])
	var from := _predicted_cell()
	return ActionOptions.build({"bf": board.bf, "skills": skills, "cfg": _cfg, "me": me, "units": snap["units"],
		"objects": snap.get("objects", []), "from": from, "ap_left": me["ap_capacity"] - _plan_cost(), "planned": planned,
		"items_left": left, "blocked": _blocked_cells(from), "cell": cell, "unit": unit_id})


func _on_option_previewed(option: Dictionary) -> void:
	_preview = option
	_preview_sig = 0
	_update_overlays()


func _on_menu_closed() -> void:
	_menu_cell = Vector2i(-1, -1)
	_menu_unit = ""
	_preview = {}
	_preview_sig = 0
	if not snap.is_empty():
		_update_overlays()


## Queues what was picked in the menu.
func _on_option_chosen(option: Dictionary) -> void:
	if not _can_edit() or not option["enabled"]:
		return
	_prev_plan = plan.duplicate(true)
	match option["kind"]:
		"move":
			var path: Array = option["path"]
			var start := _predicted_cell()
			var prev: Vector2i = start if path.size() == 1 else path[path.size() - 2]
			plan.append({"skill": "move", "path": path, "facing": Enums.facing_from_delta(path.back() - prev)})
		"context":
			plan.append({"skill": option["id"], "object": option["object"], "action": option["action"]})
		_:
			var sk := skills.get_skill(option["id"])
			if sk.targeting == Enums.Targeting.CHARACTER:
				plan.append(_new_action(option["id"], {"target": option["unit"]}))
			elif sk.targeting == Enums.Targeting.TILE:
				plan.append(_new_action(option["id"], {"cell": option["cell"]}))
			else:
				plan.append(_new_action(option["id"]))
	error_label.text = ""
	_push_plan()


## Tiles a walk cannot pass: every unit still standing, except the one at `start`.
func _blocked_cells(start: Vector2i) -> Dictionary:
	var blocked := {}
	for u: Dictionary in snap["units"]:
		if u["life"] != Enums.LifeState.ELIMINATED:
			blocked[u["cell"]] = true
	blocked.erase(start)
	return blocked


## A plan entry for a skill, or for an item (its skill is "item:<id>").
func _new_action(id: String, aim: Dictionary = {}) -> Dictionary:
	var a := {"skill": id}
	if id.begins_with("item:"):
		a["item"] = id.substr(5)
	a.merge(aim)
	return a


## The id of the first of your skills in an action-bar slot ("" if you have none).
func _slot_skill(slot: int) -> String:
	for id: String in me.get("skills", []):
		var sk := skills.get_skill(id)
		if sk != null and sk.slot() == slot:
			return id
	return ""


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


func _can_escape() -> bool:
	return not snap.is_empty() and snap["phase"] != Enums.RoundPhase.FINISHED and not me.is_empty() and not me.get("escaping", false)


func _on_escape_pressed() -> void:
	if not _can_escape():
		return
	if Time.get_ticks_msec() > _escape_armed_until_ms:
		_escape_armed_until_ms = Time.get_ticks_msec() + int(escape_confirm_seconds * 1000)
		error_label.text = "Press Retreat again to leave the fight. You will keep watching."
		_refresh()
		return
	_escape_armed_until_ms = 0
	error_label.text = ""
	net.send_escape()


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
	status_label.modulate = Color.WHITE
	if snap.get("timer_ms", -1) >= 0:
		var left := ceili((snap["timer_ms"] - (Time.get_ticks_msec() - _snap_time_ms)) / 1000.0)
		if left <= timer_urgent_seconds:
			status_label.modulate = Color(1, 0.45, 0.4)
		elif left <= timer_warn_seconds:
			status_label.modulate = Color(1, 0.8, 0.35)
	if snap["escaped"]:
		status_label.text += "\nYou escaped — watching until the battle ends."
	elif snap["eliminated"]:
		status_label.text += "\nYou were eliminated — spectating."
	elif not me.is_empty() and me["life"] == Enums.LifeState.DOWNED:
		status_label.text += "\nYou are downed. An ally can revive you once."
	elif not me.is_empty() and not me["active"]:
		status_label.text += "\nRevived: you cannot act this round."
	if not me.is_empty() and me.get("escaping", false):
		status_label.text += "\nEscaping at the end of this beat."
	if not me.is_empty():
		var cap: int = me["ap_capacity"]
		if snap["phase"] == Enums.RoundPhase.PLANNING:
			ap_label.text = "AP: %d planned / %d" % [_plan_cost(), cap]
			ap_label.modulate = Color(1, 0.5, 0.4) if _plan_cost() > cap else Color.WHITE
		else:
			ap_label.text = "AP: %d spent, %d reserved, %d forfeited / %d" % [
				me["ap_spent"], me["ap_reserved"], me["ap_forfeited"], cap]
			ap_label.modulate = Color.WHITE
	queue_list.clear()
	var beat := 1
	for a in plan:
		var sk := skills.get_skill(a["skill"])
		var txt := sk.display_name if sk != null else str(a.get("action", a["skill"]))
		if a.has("object"):
			txt += " (%s)" % _object_name(a["object"])
		elif a["skill"] == "move":
			txt += " %d tile(s)" % (a["path"] as Array).size()
		elif a.has("target"):
			txt += " → " + _unit_name(a["target"])
		elif a.has("cell"):
			txt += " → %s" % str(a["cell"])
		var n := _action_beats(a)
		queue_list.add_item("%s  [%d AP, %s %d%s]" % [txt, _action_cost(a), "beat" if n == 1 else "beats", beat,
			"" if n == 1 else "-%d" % (beat + n - 1)])
		beat += n
	var beats_cap: int = snap["beats_per_round"]
	beats_label.text = "Beats used: %d of %d" % [beat - 1, beats_cap]
	beats_label.modulate = Color(1, 0.5, 0.4) if beat - 1 > beats_cap else Color.WHITE
	board.plan_cells.clear()
	board.plan_marks.clear()
	board.marks.clear()
	var order := 0
	for a in plan:
		order += 1
		if a["skill"] == "move":
			for c: Vector2i in a["path"]:
				board.plan_cells.append(c)
		elif a.has("cell"):
			board.plan_marks.append(a["cell"])
			board.marks.append({"cell": a["cell"], "text": str(order)})
		elif a.has("target"):
			var tu := _unit_at_id(a["target"])
			if not tu.is_empty():
				board.plan_marks.append(tu["cell"])
				board.marks.append({"cell": tu["cell"], "text": str(order)})
	_refresh_cards()
	_update_overlays()
	var can := _can_edit()
	ready_btn.disabled = me.is_empty() or snap["phase"] != Enums.RoundPhase.PLANNING or not me.get("active", false)
	ready_btn.set_pressed_no_signal(not me.is_empty() and me["ready"])
	ready_btn.text = "Withdraw Ready" if ready_btn.button_pressed else "Ready"
	var armed := Time.get_ticks_msec() <= _escape_armed_until_ms
	escape_btn.disabled = not _can_escape()
	escape_btn.text = "Retreating…" if me.get("escaping", false) else ("Really retreat?" if armed else "Retreat")
	facing_row.visible = can and not plan.is_empty() and plan.back()["skill"] == "move" # only a walk can end facing another way
	if not can:
		menu.close()
		_armed = ""
	_rebuild_abilities()


## One card per visible unit, reused between snapshots: allies (you first) in the party row, enemies in sight above it.
func _refresh_cards() -> void:
	var allies: Array[Dictionary] = []
	var enemies: Array[Dictionary] = []
	for u: Dictionary in snap["units"]:
		if u["team"] == Enums.Team.PLAYERS:
			if u["id"] == snap["you"]:
				allies.push_front(u)
			else:
				allies.append(u)
		else:
			enemies.append(u)
	_fill_cards(party_cards, allies)
	_fill_cards(enemy_cards, enemies)


func _fill_cards(row: HBoxContainer, units: Array[Dictionary]) -> void:
	var have := {}
	for card in row.get_children():
		have[card.name] = card
	var wanted := {}
	for i in units.size():
		var u := units[i]
		wanted[u["id"]] = true
		var card := have.get(u["id"]) as UnitCard
		if card == null:
			card = unit_card_scene.instantiate() as UnitCard
			card.name = u["id"]
			row.add_child(card)
		row.move_child(card, i)
		card.show_unit(u, snap["phase"], u["id"] == snap["you"])
	for id: String in have:
		if not wanted.has(id):
			(have[id] as Node).queue_free()


## Copies of an item you can still plan: what you carry minus the ones already in your queue.
func _items_left(id: String) -> int:
	var left := 0
	for it: Dictionary in me.get("items", []):
		if it["id"] == id:
			left = int(it["count"])
	for a in plan:
		if a.get("item", "") == id:
			left -= 1
	return left


func _object_name(object_id: String) -> String:
	for o: Dictionary in snap.get("objects", []):
		if o["id"] == object_id:
			return str(o["name"])
	return object_id


func _process(_delta: float) -> void:
	if not snap.is_empty():
		if board.hover != _last_hover:
			_last_hover = board.hover
			_update_overlays()
		_follow_hover_card()
	if not snap.is_empty() and (snap.get("timer_ms", -1) >= 0 or (escape_btn.text == "Really retreat?" and Time.get_ticks_msec() > _escape_armed_until_ms)):
		_refresh()


## The hover card stays next to the mouse while it is over the board, and hides when it is not (or the menu is in the way).
func _follow_hover_card() -> void:
	var mouse := get_local_mouse_position()
	var over_board := board_holder.visible and board_holder.get_rect().has_point(mouse) and not menu.visible
	if _card_text == "" or not over_board:
		hover_card.hide()
		return
	hover_card.show_card(_card_text, mouse, Rect2(Vector2.ZERO, size))


## Keys: Esc closes the menu, Backspace or Ctrl+Z undoes the last queued action, Enter toggles Ready.
func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo or _state != "battle" or snap.is_empty():
		return
	match k.keycode:
		KEY_ESCAPE:
			if menu.visible:
				menu.close()
			elif _armed != "":
				_disarm()
		KEY_BACKSPACE:
			_undo()
		KEY_Z:
			if k.ctrl_pressed or k.meta_pressed:
				_undo()
		KEY_ENTER, KEY_KP_ENTER:
			if not ready_btn.disabled:
				_on_ready_toggled(not me["ready"])


func _run_selftest() -> void:
	if snap["phase"] == Enums.RoundPhase.FINISHED:
		print("[selftest] finished: outcome %d" % snap["outcome"])
		get_tree().quit(0)
		return
	if snap["phase"] != Enums.RoundPhase.PLANNING or _selftest_round == snap["round"] or not _can_edit():
		return
	_selftest_round = snap["round"]
	var target: Vector2i = me["cell"] + Vector2i(1, 0)
	for o in _options_at(target, ""):
		if o["kind"] == "move" and o["enabled"]:
			_on_option_chosen(o)
			break
	print("[selftest] round %d queued: %s (AP %d/%d)" % [snap["round"], str(plan), _plan_cost(), me["ap_capacity"]])
	_on_ready_toggled(true)
