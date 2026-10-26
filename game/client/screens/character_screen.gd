class_name CharacterScreen
extends VBoxContainer
## Your character in this world (one per player per world): overview with stats and skills, recent battles, and everyone's
## characters. Stats and skills are read from the class resource (game/content/stats/classes), so editing it there changes this page.

signal back_pressed
signal retire_requested

const RESULT_TEXT := {"players_win": "Victory", "players_lose": "Defeat", "draw": "Draw", "escaped": "Escaped"}

## Off when the page lives in a window of its own (the in-game Character window closes with its X).
@export var show_back_button: bool = true

@onready var _world: Label = %WorldLabel
@onready var _character: Label = %CharacterLabel
@onready var _xp: Label = %XpLabel
@onready var _stats: Label = %StatsLabel
@onready var _skills: ItemList = %SkillsList
@onready var _confirm: LineEdit = %RetireConfirmEdit
@onready var _retire: Button = %RetireButton
@onready var _battles_label: Label = %BattlesLabel
@onready var _battles: ItemList = %BattlesList
@onready var _roster: ItemList = %RosterList
@onready var _fallen: ItemList = %FallenList

var _name := ""


func _ready() -> void:
	%CharacterBackButton.visible = show_back_button
	%CharacterBackButton.pressed.connect(func() -> void: back_pressed.emit())
	_confirm.text_changed.connect(func(_t: String) -> void: _sync_retire())
	_retire.pressed.connect(func() -> void:
		if not _retire.disabled:
			retire_requested.emit())


func show_checking(world_name: String) -> void:
	_world.text = "World: %s" % world_name
	_character.text = "Loading your character…"
	_xp.text = ""
	_stats.text = ""
	_skills.clear()
	_battles.clear()
	_roster.clear()
	_fallen.clear()
	_name = ""
	_confirm.text = ""
	_sync_retire()


func show_character(c: Dictionary) -> void:
	_name = str(c["name"])
	_character.text = "%s\nLevel %d %s" % [c["name"], c["level"], str(c["class"]).capitalize()]
	_xp.text = "%d XP" % c["xp"]
	_confirm.text = ""
	_sync_retire()
	_skills.clear()
	_stats.text = ""
	var path := "res://game/content/stats/classes/%s.tres" % c["class"]
	var t := load(path) as UnitTemplate if ResourceLoader.exists(path) else null
	if t == null:
		return
	_stats.text = "HP %d   Dexterity %d   Power %d   Armor %d   Accuracy %d   Evasion %d" \
		% [t.max_hp, t.dexterity, t.power, t.armor, t.accuracy, t.evasion]
	for sk in t.skills:
		_skills.add_item("%s - %s" % [sk.display_name, sk.hint] if sk.hint != "" else sk.display_name)


## battles: the API's /characters/me/battles rows, newest first.
func show_battles(battles: Array) -> void:
	_battles.clear()
	_battles_label.text = "Recent battles" if not battles.is_empty() else "No battles yet."
	for b: Dictionary in battles:
		_battles.add_item("%s  %s - %s, +%d XP" % [str(b["created_at"]).left(10), RESULT_TEXT.get(b["result"], b["result"]),
			b["outcome"], b["xp_awarded"]])


## rows: the API's /characters list. Active ones and fallen (retired) ones go in separate lists, each with its owner.
func show_world_characters(rows: Array) -> void:
	_roster.clear()
	_fallen.clear()
	for r: Dictionary in rows:
		var who := "%s - %s, %s%s" % [r["name"], str(r["class"]).capitalize(), r["owner"], " (you)" if r["mine"] else ""]
		if r["status"] == "active":
			_roster.add_item(who)
		else:
			_fallen.add_item(who)


## When the character could not be loaded (the reason goes to the flow's status line).
func show_unavailable() -> void:
	_character.text = ""
	_xp.text = ""


func _sync_retire() -> void:
	_retire.disabled = _name == "" or _confirm.text != _name
