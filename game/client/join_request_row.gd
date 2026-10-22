class_name JoinRequestRow
extends HBoxContainer
## One pending join request in the host's list (game/content/ui/join_request_row.tscn).

signal approved
signal rejected


func _ready() -> void:
	%ApproveButton.pressed.connect(func() -> void: approved.emit())
	%RejectButton.pressed.connect(func() -> void: rejected.emit())


func setup(label: String) -> void:
	(%NameLabel as Label).text = label


func set_busy(busy: bool) -> void:
	(%ApproveButton as Button).disabled = busy
	(%RejectButton as Button).disabled = busy
