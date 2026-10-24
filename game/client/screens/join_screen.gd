class_name JoinScreen
extends VBoxContainer
## Shown to someone who is not (yet) a member of the chosen world. While a request is pending it asks the
## coordinator to re-check on a timer, so the page moves on by itself once the host approves.

signal request_join_pressed
signal check_pressed
signal back_pressed
signal sign_out_pressed

@onready var _label: Label = %JoinLabel
@onready var _request: Button = %RequestJoinButton
@onready var _poll: Timer = %PollTimer


func _ready() -> void:
	_request.pressed.connect(func() -> void: request_join_pressed.emit())
	%JoinCheckButton.pressed.connect(func() -> void: check_pressed.emit())
	%JoinBackButton.pressed.connect(func() -> void: back_pressed.emit())
	%JoinSignOutButton.pressed.connect(func() -> void: sign_out_pressed.emit())
	_poll.timeout.connect(func() -> void: check_pressed.emit())
	visibility_changed.connect(func() -> void:
		if not is_visible_in_tree():
			_poll.stop()) # never keep polling for a screen nobody sees


## state: pending | rejected | removed | none (see the API's /membership).
func show_state(world_name: String, state: String) -> void:
	_poll.stop() # only a pending request is worth re-checking
	match state:
		"pending":
			_label.text = "Your request to join \"%s\" is waiting for the host's approval. This page checks automatically." % world_name
			_poll.start()
		"rejected":
			_label.text = "The host declined your request to join \"%s\"." % world_name
		"removed":
			_label.text = "You were removed from \"%s\". You can ask to join again." % world_name
		_:
			_label.text = "You are not a member of \"%s\" yet. Ask the host to let you in." % world_name
	_request.visible = state != "pending"
	_request.text = "Ask to join again" if state in ["rejected", "removed"] else "Request to join"


func is_polling() -> bool:
	return not _poll.is_stopped()
