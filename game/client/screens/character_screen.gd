class_name CharacterScreen
extends VBoxContainer
## The player's character in the chosen world, with the button to enter a battle. The host also gets a
## button to the join-request list.

signal enter_pressed
signal manage_requests_pressed
signal back_pressed

@onready var _world: Label = %WorldLabel
@onready var _character: Label = %CharacterLabel
@onready var _enter: Button = %EnterButton
@onready var _manage: Button = %ManageRequestsButton


func _ready() -> void:
	_enter.pressed.connect(func() -> void: enter_pressed.emit())
	_manage.pressed.connect(func() -> void: manage_requests_pressed.emit())
	%CharacterBackButton.pressed.connect(func() -> void: back_pressed.emit())


func show_checking(world_name: String) -> void:
	_world.text = "World: %s" % world_name
	_character.text = "Checking your access…"
	_enter.disabled = true
	_manage.hide()


func show_loading() -> void:
	_character.text = "Loading your character…"
	_enter.disabled = true


func show_character(c: Dictionary) -> void:
	_character.text = "%s — level %d %s (%s), %d XP" % [c["name"], c["level"], c["class"], c["origin"], c["xp"]]
	_enter.disabled = false


## When the character could not be loaded (the reason goes to the flow's status line).
func show_unavailable() -> void:
	_character.text = ""
	_enter.disabled = true


func set_host(is_host: bool) -> void:
	_manage.visible = is_host


func set_pending_count(count: int) -> void:
	_manage.text = "Join requests (%d)" % count
