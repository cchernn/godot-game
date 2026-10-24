class_name WorldManagementScreen
extends VBoxContainer
## The host's tools for the world. For now that is the list of people asking to join, one row (join_request_row.tscn) each.

signal decision_made(request_id: String, approve: bool, row: JoinRequestRow)
signal back_pressed

## One of these per pending request.
@export var row_scene: PackedScene

@onready var _label: Label = %ManagementLabel
@onready var _rows: VBoxContainer = %RequestRows


func _ready() -> void:
	%ManagementBackButton.pressed.connect(func() -> void: back_pressed.emit())


func show_loading() -> void:
	for row in _rows.get_children():
		row.queue_free()
	_label.text = "Loading requests…"


func show_requests(requests: Array) -> void:
	for row in _rows.get_children():
		row.queue_free()
	_label.text = "Join requests" if not requests.is_empty() else "No pending join requests."
	for req: Dictionary in requests:
		var row := row_scene.instantiate() as JoinRequestRow
		_rows.add_child(row)
		var who: Variant = req.get("requester_label")
		row.setup(str(who) if who != null and str(who) != "" else "Player %s" % str(req["user_id"]).left(8))
		row.approved.connect(func() -> void: decision_made.emit(str(req["id"]), true, row))
		row.rejected.connect(func() -> void: decision_made.emit(str(req["id"]), false, row))


## The decision was stored: remove the row.
func finish_decision(row: JoinRequestRow) -> void:
	row.queue_free()
	await get_tree().process_frame
	if _rows.get_child_count() == 0:
		_label.text = "No pending join requests."


func row_failed(row: JoinRequestRow) -> void:
	row.set_busy(false)
