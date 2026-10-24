class_name SignInScreen
extends VBoxContainer
## The sign-in form. It knows nothing about the network: it announces what the player typed and the
## coordinator (AccountFlow) does the rest.

signal sign_in_pressed(email: String, password: String)
signal create_account_pressed(email: String, password: String)

@onready var _email: LineEdit = %EmailEdit
@onready var _password: LineEdit = %PasswordEdit


func _ready() -> void:
	%SignInButton.pressed.connect(func() -> void: sign_in_pressed.emit(_email.text.strip_edges(), _password.text))
	%CreateAccountButton.pressed.connect(func() -> void: create_account_pressed.emit(_email.text.strip_edges(), _password.text))
	_password.text_submitted.connect(func(_t: String) -> void: sign_in_pressed.emit(_email.text.strip_edges(), _password.text))


## Fills the email box (e.g. with the last account used) unless the player already typed something.
func prefill_email(email: String) -> void:
	if _email.text == "":
		_email.text = email


func clear_password() -> void:
	_password.text = ""
