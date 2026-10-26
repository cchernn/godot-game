class_name SettingsScreen
extends VBoxContainer
## Settings. For now only the account: who you are signed in as, the name other players see, change password and sign out. Add other options to
## settings_screen.tscn when the features they control exist.

signal back_pressed
signal sign_out_pressed
signal change_password_requested(new_password: String)
signal display_name_requested(display_name: String)

@onready var _email: Label = %AccountEmailLabel
@onready var _password: LineEdit = %NewPasswordEdit
@onready var _name: LineEdit = %DisplayNameEdit


func _ready() -> void:
	%SettingsBackButton.pressed.connect(func() -> void: back_pressed.emit())
	%SettingsSignOutButton.pressed.connect(func() -> void: sign_out_pressed.emit())
	%SaveNameButton.pressed.connect(func() -> void: display_name_requested.emit(_name.text))
	%ChangePasswordButton.pressed.connect(func() -> void: change_password_requested.emit(_password.text))


func show_account(email: String) -> void:
	_email.text = "Signed in as %s" % (email if email != "" else "(unknown)")
	_password.text = ""


## The name other players see instead of the email address (empty until one is chosen).
func show_display_name(display_name: String) -> void:
	_name.text = display_name
