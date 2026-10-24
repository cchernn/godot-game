class_name SettingsScreen
extends VBoxContainer
## Settings. For now only the account: who you are signed in as, change password and sign out. Add other options to
## settings_screen.tscn when the features they control exist.

signal back_pressed
signal sign_out_pressed
signal change_password_requested(new_password: String)

@onready var _email: Label = %AccountEmailLabel
@onready var _password: LineEdit = %NewPasswordEdit


func _ready() -> void:
	%SettingsBackButton.pressed.connect(func() -> void: back_pressed.emit())
	%SettingsSignOutButton.pressed.connect(func() -> void: sign_out_pressed.emit())
	%ChangePasswordButton.pressed.connect(func() -> void: change_password_requested.emit(_password.text))


func show_account(email: String) -> void:
	_email.text = "Signed in as %s" % (email if email != "" else "(unknown)")
	_password.text = ""
