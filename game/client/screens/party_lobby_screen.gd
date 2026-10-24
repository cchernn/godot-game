class_name PartyLobbyScreen
extends VBoxContainer
## Your party before the battle: who is in it, and (for the leader) who is asking to join and the Start button.
## It asks the coordinator to refresh itself on a timer while it is visible.

signal start_pressed
signal leave_pressed
signal back_pressed
signal refresh_requested
signal make_leader_requested(character_id: String)
signal decision_made(request_id: String, approve: bool, row: JoinRequestRow)

## One of these per player asking to join.
@export var row_scene: PackedScene

@onready var _title: Label = %PartyTitleLabel
@onready var _hint: Label = %PartyHintLabel
@onready var _roster: ItemList = %RosterList
@onready var _make_leader: Button = %MakeLeaderButton
@onready var _requests_box: VBoxContainer = %RequestsBox
@onready var _request_rows: VBoxContainer = %PartyRequestRows
@onready var _start: Button = %StartButton
@onready var _timer: Timer = %PartyTimer


func _ready() -> void:
	_start.pressed.connect(func() -> void: start_pressed.emit())
	%PartyLeaveButton.pressed.connect(func() -> void: leave_pressed.emit())
	%PartyBackButton.pressed.connect(func() -> void: back_pressed.emit())
	_roster.item_selected.connect(func(_i: int) -> void: _make_leader.disabled = _selected_member() == "")
	_make_leader.pressed.connect(func() -> void:
		var id := _selected_member()
		if id != "":
			make_leader_requested.emit(id))
	_timer.timeout.connect(func() -> void: refresh_requested.emit())
	visibility_changed.connect(func() -> void:
		if not is_visible_in_tree():
			_timer.stop())


func show_loading() -> void:
	_title.text = "Loading your party…"
	_hint.text = ""
	_roster.clear()
	_make_leader.hide()
	_start.hide()
	_requests_box.hide()
	_clear_requests()
	_timer.start()


## party: the API's party view ({activity_name, members, leader, relation, max_players, status}).
func show_party(party: Dictionary) -> void:
	var members: Array = party["members"]
	_title.text = "%s (%d/%d)" % [party["activity_name"], members.size(), party["max_players"]]
	var kept := _selected_member()  # the lobby refreshes on a timer: keep the leader's pick
	_roster.clear()
	var leader: Variant = party.get("leader")
	for m: Dictionary in members:
		var is_leader: bool = leader != null and m["id"] == leader["id"]
		var i := _roster.add_item("%s - %s%s" % [m["name"], m["class"], " (leader)" if is_leader else ""])
		_roster.set_item_metadata(i, "" if is_leader else str(m["id"]))
		if not is_leader and str(m["id"]) == kept:
			_roster.select(i)
	var is_leading: bool = party["relation"] == "leader"
	_make_leader.visible = is_leading
	_make_leader.disabled = _selected_member() == ""
	_start.visible = is_leading
	_requests_box.visible = is_leading
	_hint.text = "Let players in, then start the battle." if is_leading \
		else "Waiting for %s to start the battle." % (leader["name"] if leader != null else "the leader")
	if not is_leading:
		_clear_requests()


## Leader only: the players asking to join.
func show_requests(requests: Array) -> void:
	_clear_requests()
	for req: Dictionary in requests:
		var row := row_scene.instantiate() as JoinRequestRow
		_request_rows.add_child(row)
		row.setup("%s (%s)" % [req["name"], req["class"]])
		row.approved.connect(func() -> void: decision_made.emit(str(req["id"]), true, row))
		row.rejected.connect(func() -> void: decision_made.emit(str(req["id"]), false, row))


func finish_decision(row: JoinRequestRow) -> void:
	row.queue_free()


func row_failed(row: JoinRequestRow) -> void:
	row.set_busy(false)


func set_start_busy(busy: bool) -> void:
	_start.disabled = busy


func _selected_member() -> String:
	var sel := _roster.get_selected_items()
	return "" if sel.is_empty() else str(_roster.get_item_metadata(sel[0]))


func _clear_requests() -> void:
	for row in _request_rows.get_children():
		row.queue_free()
