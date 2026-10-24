class_name WorldPickerScreen
extends VBoxContainer
## The world picker shown after every sign-in: every world with the player's standing in it.

signal open_world_requested(world: Dictionary)
signal create_world_requested(world_name: String)
signal refresh_requested
signal sign_out_requested
## Something to tell the player (shown in the flow's status line).
signal message(text: String)

const STANDING_TEXT := {"member": "joined", "pending": "request pending", "rejected": "request declined",
	"removed": "removed", "none": "not joined"}

var _worlds: Array = []

@onready var _header: Label = %SignedInLabel
@onready var _list: ItemList = %WorldList
@onready var _new_world: LineEdit = %NewWorldEdit


func _ready() -> void:
	%PlayButton.pressed.connect(_open_selected)
	_list.item_activated.connect(_open_index) # double-click or Enter on a row
	%CreateWorldButton.pressed.connect(_on_create_pressed)
	%RefreshWorldsButton.pressed.connect(func() -> void: refresh_requested.emit())
	%WorldsSignOutButton.pressed.connect(func() -> void: sign_out_requested.emit())


## Shown while the list is being fetched.
func begin_loading(user_email: String) -> void:
	_header.text = "Signed in as %s. Choose a world." % user_email
	_list.clear()
	_worlds = []


func show_worlds(worlds: Array, user_email: String) -> void:
	_worlds = worlds
	_header.text = "Signed in as %s. Choose a world." % user_email
	_list.clear()
	for w: Dictionary in _worlds:
		var standing: String = "host" if w.get("is_host", false) else STANDING_TEXT.get(w["status"], w["status"])
		_list.add_item("%s  -  %s  (%d player%s)" % [w["name"], standing, w["members"], "" if w["members"] == 1 else "s"])
	if _worlds.is_empty():
		_header.text = "Signed in as %s. There are no worlds yet; create one below." % user_email


func clear_new_world() -> void:
	_new_world.text = ""


func _open_selected() -> void:
	var sel := _list.get_selected_items()
	if sel.is_empty():
		message.emit("Select a world first")
		return
	_open_index(sel[0])


func _open_index(index: int) -> void:
	message.emit("")
	open_world_requested.emit(_worlds[index])


func _on_create_pressed() -> void:
	var n := _new_world.text.strip_edges()
	if n == "":
		message.emit("Enter a world name")
		return
	create_world_requested.emit(n)
