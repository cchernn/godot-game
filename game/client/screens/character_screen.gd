class_name CharacterScreen
extends VBoxContainer
## Your character in this world (one per player per world). Reached from the hub; read-only for now.

signal back_pressed

@onready var _world: Label = %WorldLabel
@onready var _character: Label = %CharacterLabel


func _ready() -> void:
	%CharacterBackButton.pressed.connect(func() -> void: back_pressed.emit())


func show_checking(world_name: String) -> void:
	_world.text = "World: %s" % world_name
	_character.text = "Loading your character…"


func show_character(c: Dictionary) -> void:
	_character.text = "%s\nLevel %d %s (%s)\n%d XP" % [c["name"], c["level"], c["class"], c["origin"], c["xp"]]


## When the character could not be loaded (the reason goes to the flow's status line).
func show_unavailable() -> void:
	_character.text = ""
