class_name CreatePartyScreen
extends VBoxContainer
## Choose the activity a new party will run. You become its leader.

signal create_requested(activity_id: String)
signal back_pressed
signal message(text: String)

const KIND_TEXT := {"minor": "", "major": " [major]"}

var _activities: Array = []

@onready var _label: Label = %CreatePartyLabel
@onready var _list: ItemList = %ActivityList


func _ready() -> void:
	%StartPartyButton.pressed.connect(_on_start_pressed)
	_list.item_activated.connect(func(i: int) -> void: create_requested.emit(str(_activities[i]["id"])))
	%CreatePartyBackButton.pressed.connect(func() -> void: back_pressed.emit())


func show_loading() -> void:
	_label.text = "Loading activities…"
	_list.clear()
	_activities = []


## activities: the world overview's activity list; only the ones that can be run are shown.
func show_activities(activities: Array) -> void:
	_activities = activities.filter(func(a: Dictionary) -> bool: return a["available"])
	_list.clear()
	for a: Dictionary in _activities:
		_list.add_item("%s%s - up to %d players" % [a["name"], KIND_TEXT.get(a["kind"], ""), a["max_players"]])
	_label.text = "Choose an activity" if not _activities.is_empty() else "There is nothing to run right now."


func _on_start_pressed() -> void:
	var sel := _list.get_selected_items()
	if sel.is_empty():
		message.emit("Select an activity first")
		return
	message.emit("")
	create_requested.emit(str(_activities[sel[0]]["id"]))
