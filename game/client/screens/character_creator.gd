class_name CharacterCreator
extends VBoxContainer
## Character creation. Keep this screen as elaborate as you like: it only has to emit `create_requested`.

signal create_requested(character_name: String, origin: String, class_id: String)
signal back_pressed
signal message(text: String)

## Mirrors services/api/app/rules.py (provisional); the API rejects anything else.
const ORIGINS: Array[String] = ["outcast", "soldier", "scholar"]
const CLASSES: Array[String] = ["warrior", "ranger", "cleric", "rogue"]

@onready var _name: LineEdit = %CharacterNameEdit
@onready var _origin: OptionButton = %OriginOption
@onready var _class: OptionButton = %ClassOption


func _ready() -> void:
	for o in ORIGINS:
		_origin.add_item(o.capitalize())
	for c in CLASSES:
		_class.add_item(c.capitalize())
	%CreateCharacterButton.pressed.connect(_on_create_pressed)
	%CreateBackButton.pressed.connect(func() -> void: back_pressed.emit())


func reset() -> void:
	_name.text = ""
	_origin.select(0)
	_class.select(0)


func _on_create_pressed() -> void:
	var n := _name.text.strip_edges()
	if n == "":
		message.emit("Enter a name")
		return
	create_requested.emit(n, ORIGINS[_origin.selected], CLASSES[_class.selected])
