class_name SettingsScreen
extends VBoxContainer
## Settings. For now only the account: who you are signed in as, the name other players see, change password and sign out. Add other options to
## settings_screen.tscn when the features they control exist.

signal back_pressed
signal sign_out_pressed
signal change_password_requested(new_password: String)
signal display_name_requested(display_name: String)
## A volume slider moved: the bus ("Music", "Effects" or "UI") and the new volume, 0 to 1.
signal volume_changed(bus: String, value: float)

@onready var _email: Label = %AccountEmailLabel
@onready var _password: LineEdit = %NewPasswordEdit
@onready var _name: LineEdit = %DisplayNameEdit


func _ready() -> void:
	for bus in AudioSettings.BUSES:
		var slider := get_node("%" + bus + "VolumeSlider") as HSlider
		slider.value_changed.connect(func(v: float) -> void: volume_changed.emit(bus, v))
	%SettingsBackButton.pressed.connect(func() -> void: back_pressed.emit())
	%SettingsSignOutButton.pressed.connect(func() -> void: sign_out_pressed.emit())
	%SaveNameButton.pressed.connect(func() -> void: display_name_requested.emit(_name.text))
	%ChangePasswordButton.pressed.connect(func() -> void: change_password_requested.emit(_password.text))


## Puts the sliders where the saved volumes are, without announcing a change.
func show_volumes(volumes: Dictionary) -> void:
	for bus in AudioSettings.BUSES:
		(get_node("%" + bus + "VolumeSlider") as HSlider).set_value_no_signal(float(volumes.get(bus, 1.0)))


func show_account(email: String) -> void:
	_email.text = "Signed in as %s" % (email if email != "" else "(unknown)")
	_password.text = ""


## The name other players see instead of the email address (empty until one is chosen).
func show_display_name(display_name: String) -> void:
	_name.text = display_name
