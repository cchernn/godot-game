class_name SettingsScreen
extends VBoxContainer
## Placeholder: the settings menu is not designed yet. Add the options to settings_screen.tscn when they exist.

signal back_pressed


func _ready() -> void:
	%SettingsBackButton.pressed.connect(func() -> void: back_pressed.emit())
