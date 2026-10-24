class_name PartiesScreen
extends VBoxContainer
## Every live party in the world. Pick one to ask its leader to let you in, or start your own. In the
## overworld this same list becomes a small panel; keep it free of anything that assumes a full screen.

signal request_join_requested(party: Dictionary)
signal cancel_request_requested(party: Dictionary)
signal open_party_requested(party: Dictionary)
signal create_party_pressed
## Asked on a timer while the screen is visible, so the list stays current.
signal refresh_requested
signal back_pressed

const STATUS_TEXT := {"forming": "gathering", "active": "in battle"}

var _parties: Array = []

@onready var _label: Label = %PartiesLabel
@onready var _list: ItemList = %PartyList
@onready var _action: Button = %PartyActionButton
@onready var _timer: Timer = %PartiesTimer


func _ready() -> void:
	_list.item_selected.connect(func(_i: int) -> void: _update_action())
	_list.item_activated.connect(func(i: int) -> void: _act_on(_parties[i]))
	_action.pressed.connect(_on_action_pressed)
	%CreatePartyButton.pressed.connect(func() -> void: create_party_pressed.emit())
	%PartiesRefreshButton.pressed.connect(func() -> void: refresh_requested.emit())
	%PartiesBackButton.pressed.connect(func() -> void: back_pressed.emit())
	_timer.timeout.connect(func() -> void: refresh_requested.emit())
	visibility_changed.connect(func() -> void:
		if not is_visible_in_tree():
			_timer.stop()) # never keep refreshing a screen nobody sees


func show_loading() -> void:
	_label.text = "Loading parties…"
	_list.clear()
	_parties = []
	_update_action()
	_timer.start()


## parties: the API's party views. Keeps the same party selected across refreshes.
func show_parties(parties: Array) -> void:
	var keep: String = _selected_id()
	_parties = parties
	_list.clear()
	for p: Dictionary in _parties:
		var leader: Variant = p.get("leader")
		var text := "%s - led by %s - %d/%d - %s" % [p["activity_name"], leader["name"] if leader != null else "?",
			(p["members"] as Array).size(), p["max_players"], STATUS_TEXT.get(p["status"], p["status"])]
		match p["relation"]:
			"leader", "member": text += "  [your party]"
			"pending": text += "  [request sent]"
		_list.add_item(text)
		if str(p["id"]) == keep:
			_list.select(_list.item_count - 1)
	_label.text = "Parties in this world" if not _parties.is_empty() else "No parties are forming. Start one."
	_update_action()


func _selected_id() -> String:
	var sel := _list.get_selected_items()
	if sel.is_empty() or sel[0] >= _parties.size():
		return ""
	return str((_parties[sel[0]] as Dictionary)["id"])


## The button next to the list does whatever makes sense for the selected party.
func _update_action() -> void:
	var sel := _list.get_selected_items()
	if sel.is_empty() or sel[0] >= _parties.size():
		_action.text = "Request to join"
		_action.disabled = true
		return
	var p: Dictionary = _parties[sel[0]]
	match p["relation"]:
		"leader", "member":
			_action.text = "Return to battle" if p["status"] == "active" else "Open party"
			_action.disabled = false
		"pending":
			_action.text = "Cancel request"
			_action.disabled = false
		_:
			_action.text = "Request to join"
			_action.disabled = not p["open"]


func _on_action_pressed() -> void:
	var sel := _list.get_selected_items()
	if not sel.is_empty():
		_act_on(_parties[sel[0]])


func _act_on(p: Dictionary) -> void:
	match p["relation"]:
		"leader", "member": open_party_requested.emit(p)
		"pending": cancel_request_requested.emit(p)
		_:
			if p["open"]:
				request_join_requested.emit(p)
