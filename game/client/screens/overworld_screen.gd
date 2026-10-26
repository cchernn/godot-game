class_name OverworldScreen
extends Control
## The game view of a world: the map fills the screen and windows float over it, opened from the dock at the bottom.
##   Activity  - the place you picked on the map: what can be done there, Start and Travel.
##   Party     - your party (roster, leader tools, join requests) and the other parties standing here to ask to join.
##   Character - your character page.
##   Menu      - Settings, World management (host), Choose another world, Sign out.
## The party leader travels and starts activities; everyone else watches. It only reports what the player asked for;
## the coordinator calls the API and feeds the answers back.

signal travel_requested(node_id: String)
signal start_requested(activity_id: String)
signal leave_requested
signal make_leader_requested(character_id: String)
signal join_requested(party: Dictionary)
signal cancel_join_requested(party: Dictionary)
signal decision_made(request_id: String, approve: bool, row: JoinRequestRow)
## Rejoin the battle your party is fighting.
signal resume_pressed
## Asked on a timer while the screen is visible, so the map and parties stay current.
signal refresh_requested
## The Character window was opened (the coordinator loads the page).
signal character_requested
signal settings_pressed
signal management_pressed
signal switch_world_pressed
signal sign_out_pressed

## One of these per player asking to join.
@export var row_scene: PackedScene

var _overview: Dictionary = {}
var _mine: Dictionary = {}
var _others: Array = []
var _selected_node: String = ""
var _place_activities: Array = []

@onready var _map: MapCanvas = %MapCanvas
@onready var _party_title: Label = %PartyTitleLabel
@onready var _party_status: Label = %PartyStatusLabel
@onready var _roster: ItemList = %RosterList
@onready var _make_leader: Button = %MakeLeaderButton
@onready var _leave: Button = %PartyLeaveButton
@onready var _requests_box: VBoxContainer = %RequestsBox
@onready var _request_rows: VBoxContainer = %PartyRequestRows
@onready var _resume: Button = %ReturnButton
@onready var _place: Label = %PlaceLabel
@onready var _activity_list: ItemList = %ActivityList
@onready var _start: Button = %StartButton
@onready var _travel: Button = %TravelButton
@onready var _place_hint: Label = %PlaceHintLabel
@onready var _others_label: Label = %OthersLabel
@onready var _others_list: ItemList = %OthersList
@onready var _ask: Button = %AskButton
@onready var _timer: Timer = %OverworldTimer
@onready var _hud: Label = %HudLabel
@onready var _manage: Button = %ManagementButton
@onready var _party_toggle: Button = %PartyToggle
@onready var _toggles: Dictionary = {
	"activity": [%ActivityToggle, %ActivityWindow], "party": [%PartyToggle, %PartyWindow],
	"character": [%CharacterToggle, %CharacterWindow], "menu": [%MenuToggle, %MenuWindow]}
## The character page inside the Character window.
@onready var character_screen: CharacterScreen = %CharacterScreen
## The message line over the map (errors and notices). The coordinator writes it through its StatusLine.
@onready var toast_box: Control = %ToastBox
@onready var toast_label: Label = %ToastLabel

var _pending_requests: int = 0


func _ready() -> void:
	for key: String in _toggles:
		var toggle: Button = _toggles[key][0]
		var window: FloatingWindow = _toggles[key][1]
		toggle.toggled.connect(func(on: bool) -> void:
			if on:
				_close_others(key) # the windows share one spot, so only one category is open at a time
				window.open()
				if key == "character":
					character_requested.emit()
			else:
				window.hide())
		window.closed.connect(func() -> void: toggle.set_pressed_no_signal(false))
	_map.node_pressed.connect(func(id: String) -> void:
		_selected_node = id
		_refresh_view()
		open_window("activity"))
	%SettingsButton.pressed.connect(func() -> void: settings_pressed.emit())
	_manage.pressed.connect(func() -> void: management_pressed.emit())
	%SwitchWorldButton.pressed.connect(func() -> void: switch_world_pressed.emit())
	%SignOutButton.pressed.connect(func() -> void: sign_out_pressed.emit())
	_roster.item_selected.connect(func(_i: int) -> void: _refresh_party_buttons())
	_activity_list.item_selected.connect(func(_i: int) -> void: _refresh_place_buttons())
	_others_list.item_selected.connect(func(_i: int) -> void: _refresh_others_buttons())
	_make_leader.pressed.connect(func() -> void:
		var id := _selected_member()
		if id != "":
			make_leader_requested.emit(id))
	_leave.pressed.connect(func() -> void: leave_requested.emit())
	_resume.pressed.connect(func() -> void: resume_pressed.emit())
	_travel.pressed.connect(func() -> void: travel_requested.emit(_selected_node))
	_start.pressed.connect(func() -> void:
		var id := _selected_activity()
		if id != "":
			start_requested.emit(id))
	_ask.pressed.connect(_on_ask_pressed)
	_timer.timeout.connect(func() -> void: refresh_requested.emit())
	visibility_changed.connect(func() -> void:
		if not is_visible_in_tree():
			_timer.stop()) # never keep refreshing a screen nobody sees


func _close_others(keep: String) -> void:
	for key: String in _toggles:
		if key != keep:
			(_toggles[key][0] as Button).set_pressed_no_signal(false)
			(_toggles[key][1] as Control).hide()


## Opens one of the windows ("activity", "party", "character" or "menu") as if its dock button was pressed.
func open_window(key: String) -> void:
	var toggle: Button = _toggles[key][0]
	if not toggle.button_pressed:
		toggle.button_pressed = true # its toggled handler opens the window
	else:
		(_toggles[key][1] as FloatingWindow).move_to_front()


func is_window_open(key: String) -> bool:
	return (_toggles[key][1] as Control).visible


## "World - Character, level N class" in the corner.
func set_header(text: String) -> void:
	_hud.text = text


## Only the host sees World management.
func set_host(is_host: bool) -> void:
	_manage.visible = is_host
	_manage.text = "World management"


func set_pending_count(count: int) -> void:
	_manage.text = "World management (%d request%s)" % [count, "" if count == 1 else "s"] if count > 0 else "World management"
	%MenuToggle.text = "Menu (%d)" % count if count > 0 else "Menu"


func show_loading() -> void:
	_overview = {}
	_mine = {}
	_selected_node = ""
	_party_title.text = "Loading the map…"
	_party_status.text = ""
	_roster.clear()
	_activity_list.clear()
	_others_list.clear()
	for b: Button in [_make_leader, _leave, _start, _travel, _ask, _resume]:
		b.hide()
	_requests_box.hide()
	clear_requests()
	_pending_requests = 0
	_party_toggle.text = "Party"
	_timer.start()


## overview: the API's world overview ({nodes, routes, activities}); parties: the API's party views.
func show_world(overview: Dictionary, parties: Array) -> void:
	_overview = overview
	_mine = {}
	_others = []
	for p: Dictionary in parties:
		if p["relation"] == "leader" or p["relation"] == "member":
			_mine = p
		elif p["here"]:
			_others.append(p)
	if _mine.is_empty():
		return
	var known := (overview["nodes"] as Array).any(func(n: Dictionary) -> bool: return n["id"] == _selected_node)
	if _selected_node == "" or not known:
		_selected_node = _mine["node_id"]
	_refresh_view()


## The party you are in right now, or {} before the first refresh.
func my_party() -> Dictionary:
	return _mine


## Leader only: the players asking to join.
func show_requests(requests: Array) -> void:
	clear_requests()
	_requests_box.visible = not requests.is_empty()
	_pending_requests = requests.size()
	_party_toggle.text = "Party (%d)" % _pending_requests if _pending_requests > 0 else "Party"
	for req: Dictionary in requests:
		var row := row_scene.instantiate() as JoinRequestRow
		_request_rows.add_child(row)
		row.setup("%s (%s)" % [req["name"], req["class"]])
		row.approved.connect(func() -> void: decision_made.emit(str(req["id"]), true, row))
		row.rejected.connect(func() -> void: decision_made.emit(str(req["id"]), false, row))


func clear_requests() -> void:
	for row in _request_rows.get_children():
		row.queue_free()


func finish_decision(row: JoinRequestRow) -> void:
	row.queue_free()


func row_failed(row: JoinRequestRow) -> void:
	row.set_busy(false)


## Why the leader cannot travel the party to `target` right now ("" when they can).
static func travel_problem(mine: Dictionary, overview: Dictionary, target: String) -> String:
	if mine.is_empty() or target == "":
		return ""
	if target == mine["node_id"]:
		return "Your party is here."
	if mine["relation"] != "leader":
		return "Only the party leader can travel."
	if mine["instance"] != null:
		return "Your party is in the middle of an activity."
	for r: Dictionary in overview.get("routes", []):
		if (r["from"] == mine["node_id"] and r["to"] == target) or (r["to"] == mine["node_id"] and r["from"] == target):
			return ""
	return "There is no known route from here."


## Why the leader cannot start `activity` right now ("" when they can).
static func start_problem(mine: Dictionary, activity: Dictionary) -> String:
	if mine.is_empty() or activity.is_empty():
		return ""
	if mine["relation"] != "leader":
		return "Only the party leader can start an activity."
	if mine["instance"] != null:
		return "Your party is already in an activity."
	if activity["node"] != mine["node_id"]:
		return "Your party must be here to start this."
	if not activity["available"]:
		return "This is no longer available."
	if (mine["members"] as Array).size() > int(activity["max_players"]):
		return "Your party is too big (max %d)." % activity["max_players"]
	return ""


func _refresh_view() -> void:
	if _overview.is_empty() or _mine.is_empty():
		return
	_map.show_map(_overview["nodes"], _overview["routes"], _mine["node_id"], _selected_node)
	_show_party()
	_show_place()
	_show_others()


func _show_party() -> void:
	var members: Array = _mine["members"]
	_party_title.text = "Your party (%d/%d)" % [members.size(), _mine["max_size"]]
	var kept := _selected_member()  # refreshed on a timer: keep the leader's pick
	_roster.clear()
	var leader: Variant = _mine.get("leader")
	for m: Dictionary in members:
		var is_leader: bool = leader != null and m["id"] == leader["id"]
		var i := _roster.add_item("%s - %s%s" % [m["name"], m["class"], " (leader)" if is_leader else ""])
		_roster.set_item_metadata(i, "" if is_leader else str(m["id"]))
		if not is_leader and str(m["id"]) == kept:
			_roster.select(i)
	var run: Variant = _mine["instance"]
	if run != null:
		_party_status.text = "In an activity: %s" % run["activity_name"]
	elif _mine["relation"] == "leader":
		_party_status.text = "You lead. Pick a place on the map to travel, or an activity to start."
	else:
		_party_status.text = "%s leads the party." % (leader["name"] if leader != null else "Someone")
	_resume.visible = run != null
	if _mine["relation"] != "leader" or run != null:
		_requests_box.hide()
		clear_requests()
		_pending_requests = 0
		_party_toggle.text = "Party"
	_refresh_party_buttons()


func _refresh_party_buttons() -> void:
	var idle: bool = _mine["instance"] == null
	_make_leader.visible = _mine["relation"] == "leader" and (_mine["members"] as Array).size() > 1 and idle
	_make_leader.disabled = _selected_member() == ""
	_leave.visible = (_mine["members"] as Array).size() > 1 and idle


func _show_place() -> void:
	var node: Dictionary = {}
	for n: Dictionary in _overview["nodes"]:
		if n["id"] == _selected_node:
			node = n
	_place.text = "%s%s" % [node.get("name", "?"), "  (your party is here)" if _selected_node == _mine["node_id"] else ""]
	var kept := _selected_activity()
	_place_activities = (_overview["activities"] as Array).filter(func(a: Dictionary) -> bool: return a["node"] == _selected_node)
	_activity_list.clear()
	for a in _place_activities:
		var i := _activity_list.add_item("%s%s" % [a["name"], "" if a["available"] else " (done)"])
		if a["id"] == kept:
			_activity_list.select(i)
	_refresh_place_buttons()


func _refresh_place_buttons() -> void:
	var tp := travel_problem(_mine, _overview, _selected_node)
	_travel.visible = _selected_node != _mine["node_id"]
	_travel.disabled = tp != ""
	var node_name := _place.text.get_slice("  (", 0)
	_travel.text = "Travel to %s" % node_name
	var act := _activity_by_id(_selected_activity())
	var sp := start_problem(_mine, act)
	_start.visible = _selected_node == _mine["node_id"] and not _place_activities.is_empty()
	_start.disabled = act.is_empty() or sp != ""
	_start.text = "Start: %s" % act["name"] if not act.is_empty() else "Start the selected activity"
	if _selected_node != _mine["node_id"]:
		_place_hint.text = tp
	elif _place_activities.is_empty():
		_place_hint.text = "Nothing to do here yet."
	else:
		_place_hint.text = sp if not act.is_empty() else "Pick an activity."


func _show_others() -> void:
	_others_label.text = "Other parties here" if not _others.is_empty() else "No other parties here."
	var kept := _selected_other()
	_others_list.clear()
	for p: Dictionary in _others:
		var leader: Variant = p.get("leader")
		var state := "asked" if p["relation"] == "pending" else ("in an activity" if p["instance"] != null else "open")
		var i := _others_list.add_item("%s - %d/%d - %s" % [leader["name"] if leader != null else "?",
			(p["members"] as Array).size(), p["max_size"], state])
		if str(p["id"]) == kept:
			_others_list.select(i)
	_refresh_others_buttons()


func _refresh_others_buttons() -> void:
	var p := _other_by_id(_selected_other())
	_ask.visible = not p.is_empty()
	if p.is_empty():
		return
	if p["relation"] == "pending":
		_ask.text = "Cancel request"
		_ask.disabled = false
	else:
		_ask.text = "Ask to join"
		_ask.disabled = not p["open"] or (_mine["members"] as Array).size() > 1 or _mine["instance"] != null


func _on_ask_pressed() -> void:
	var p := _other_by_id(_selected_other())
	if p.is_empty():
		return
	if p["relation"] == "pending":
		cancel_join_requested.emit(p)
	else:
		join_requested.emit(p)


func _selected_member() -> String:
	var sel := _roster.get_selected_items()
	return "" if sel.is_empty() else str(_roster.get_item_metadata(sel[0]))


func _selected_activity() -> String:
	var sel := _activity_list.get_selected_items()
	return "" if sel.is_empty() or sel[0] >= _place_activities.size() else str((_place_activities[sel[0]] as Dictionary)["id"])


func _activity_by_id(id: String) -> Dictionary:
	for a: Dictionary in _place_activities:
		if a["id"] == id:
			return a
	return {}


func _selected_other() -> String:
	var sel := _others_list.get_selected_items()
	return "" if sel.is_empty() or sel[0] >= _others.size() else str((_others[sel[0]] as Dictionary)["id"])


func _other_by_id(id: String) -> Dictionary:
	for p: Dictionary in _others:
		if str(p["id"]) == id:
			return p
	return {}
