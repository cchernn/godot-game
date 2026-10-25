class_name WorldHubScreen
extends VBoxContainer
## The main menu of a world: where you go from here. Shows who you are, whether you are in a party, and the
## doors to Overworld, your Character, Settings and (for the host) World management.

signal overworld_pressed
signal character_pressed
signal management_pressed
signal settings_pressed
## Rejoin the battle your party is fighting.
signal resume_pressed
signal switch_world_pressed

@onready var _world: Label = %HubWorldLabel
@onready var _character: Label = %HubCharacterLabel
@onready var _party: Label = %HubPartyLabel
@onready var _resume: Button = %ResumeButton
@onready var _manage: Button = %ManagementButton


func _ready() -> void:
	%OverworldButton.pressed.connect(func() -> void: overworld_pressed.emit())
	%CharacterButton.pressed.connect(func() -> void: character_pressed.emit())
	_manage.pressed.connect(func() -> void: management_pressed.emit())
	%SettingsButton.pressed.connect(func() -> void: settings_pressed.emit())
	_resume.pressed.connect(func() -> void: resume_pressed.emit())
	%SwitchWorldButton.pressed.connect(func() -> void: switch_world_pressed.emit())


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


## The party you are in (a party view from the API; every character is in one).
func show_party(party: Dictionary) -> void:
	var run: Variant = party["instance"]
	var others := (party["members"] as Array).size() - 1
	_party.text = "Your party: %s%s, at %s%s" % [_party_leader_name(party), "" if others == 0 else " +%d" % others, party["node_name"],
		"" if run == null else " (in %s)" % run["activity_name"]]
	_resume.text = "Return to battle"
	_resume.visible = run != null and run["status"] == "active"


func _party_leader_name(party: Dictionary) -> String:
	var leader: Variant = party.get("leader")
	return "you" if party["relation"] == "leader" else (leader["name"] if leader != null else "?")
