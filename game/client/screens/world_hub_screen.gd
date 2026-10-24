class_name WorldHubScreen
extends VBoxContainer
## The main menu of a world: where you go from here. Shows who you are, whether you are in a party, and the
## doors to Parties, your Character, Settings and (for the host) World management.

signal parties_pressed
signal character_pressed
signal management_pressed
signal settings_pressed
## Open your party's lobby, or rejoin its battle if it has started.
signal resume_pressed
signal switch_world_pressed
signal sign_out_pressed

@onready var _world: Label = %HubWorldLabel
@onready var _character: Label = %HubCharacterLabel
@onready var _party: Label = %HubPartyLabel
@onready var _resume: Button = %ResumeButton
@onready var _manage: Button = %ManagementButton


func _ready() -> void:
	%PartiesButton.pressed.connect(func() -> void: parties_pressed.emit())
	%CharacterButton.pressed.connect(func() -> void: character_pressed.emit())
	_manage.pressed.connect(func() -> void: management_pressed.emit())
	%SettingsButton.pressed.connect(func() -> void: settings_pressed.emit())
	_resume.pressed.connect(func() -> void: resume_pressed.emit())
	%SwitchWorldButton.pressed.connect(func() -> void: switch_world_pressed.emit())
	%HubSignOutButton.pressed.connect(func() -> void: sign_out_pressed.emit())


## Resets the hub while its details load.
func show_loading(world_name: String) -> void:
	_world.text = world_name
	_character.text = ""
	_party.text = ""
	_resume.hide()
	_manage.hide()


func show_character(c: Dictionary) -> void:
	_character.text = "%s, level %d %s" % [c["name"], c["level"], c["class"]]


## Only the host sees World management.
func set_host(is_host: bool) -> void:
	_manage.visible = is_host
	_manage.text = "World management"


func set_pending_count(count: int) -> void:
	_manage.text = "World management (%d request%s)" % [count, "" if count == 1 else "s"] if count > 0 else "World management"


## The party you are in (a party view from the API), or {} when you are in none.
func show_party(party: Dictionary) -> void:
	if party.is_empty():
		_party.text = "You are not in a party."
		_resume.hide()
		return
	var active: bool = party["status"] == "active"
	_party.text = "Your party: %s (%s, %d/%d)" % [party["activity_name"], "battle in progress" if active else "gathering",
		(party["members"] as Array).size(), party["max_players"]]
	_resume.text = "Return to battle" if active else "Open party"
	_resume.show()
