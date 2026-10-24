class_name LobbyScreen
extends VBoxContainer
## The waiting room on the battle server: which party members have arrived.

signal leave_pressed

@onready var _label: Label = %WaitLabel
@onready var _list: ItemList = %LobbyList


func _ready() -> void:
	%CancelButton.pressed.connect(func() -> void: leave_pressed.emit())


func show_connecting() -> void:
	_label.text = "Connecting to the battle server…"
	_list.clear()


## info: {players: [names], needed: int}, as sent by the server.
func show_lobby(info: Dictionary) -> void:
	var names: Array = info["players"]
	_label.text = "Waiting for the party (%d/%d here). The battle starts when everyone has arrived." % [names.size(), info["needed"]]
	_list.clear()
	for n in names:
		_list.add_item(str(n))
