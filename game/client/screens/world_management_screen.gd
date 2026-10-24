class_name WorldManagementScreen
extends VBoxContainer
## The host's tools for the world: rename it, decide join requests (one join_request_row.tscn each), remove members,
## and delete it for good.

signal decision_made(request_id: String, approve: bool, row: JoinRequestRow)
signal rename_requested(new_name: String)
signal remove_member_requested(user_id: String)
## Only emitted once the typed name matches the world's name; the server checks it again.
signal delete_requested(confirm_name: String)
signal back_pressed

## One of these per pending request.
@export var row_scene: PackedScene

@onready var _label: Label = %ManagementLabel
@onready var _rows: VBoxContainer = %RequestRows
@onready var _info: Label = %WorldInfoLabel
@onready var _name_edit: LineEdit = %WorldNameEdit
@onready var _members: ItemList = %MembersList
@onready var _remove: Button = %RemoveMemberButton
@onready var _confirm: LineEdit = %DeleteConfirmEdit
@onready var _delete: Button = %DeleteButton

var _world_name := ""


func _ready() -> void:
	%RenameButton.pressed.connect(func() -> void:
		var n := _name_edit.text.strip_edges()
		if n != "" and n != _world_name:
			rename_requested.emit(n))
	_members.item_selected.connect(func(_i: int) -> void: _remove.disabled = _selected_user() == "")
	_remove.pressed.connect(func() -> void:
		var uid := _selected_user()
		if uid != "":
			remove_member_requested.emit(uid))
	_confirm.text_changed.connect(func(_t: String) -> void: _sync_delete())
	_delete.pressed.connect(func() -> void:
		if not _delete.disabled:
			delete_requested.emit(_confirm.text))
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


## The world's current name; also clears the delete confirmation.
func show_world(world_name: String) -> void:
	_world_name = world_name
	_name_edit.text = world_name
	_confirm.text = ""
	_sync_delete()


## info: the API's /info row (read-only facts about the world).
func show_info(info: Dictionary) -> void:
	_info.text = "Template %s v%d, created %s\n%d members, %d characters, %d live parties, %d battles fought" \
		% [info["template_id"], info["definition_version"], str(info["created_at"]).left(10), info["members"],
		info["characters"], info["live_parties"], info["battles"]]


## members: the API's /members rows. The host cannot be removed, so that row is not selectable.
func show_members(members: Array) -> void:
	_members.clear()
	_remove.disabled = true
	for m: Dictionary in members:
		var who: Variant = m.get("character_name")
		if who == null or str(who) == "":
			who = m.get("label")
		var text := str(who) if who != null and str(who) != "" else "Player %s" % str(m["user_id"]).left(8)
		var is_host := str(m.get("role", "")) == "host"
		var i := _members.add_item(text + ("  (host)" if is_host else ""))
		_members.set_item_metadata(i, "" if is_host else str(m["user_id"]))
		_members.set_item_selectable(i, not is_host)


func _selected_user() -> String:
	var sel := _members.get_selected_items()
	return "" if sel.is_empty() else str(_members.get_item_metadata(sel[0]))


func _sync_delete() -> void:
	_delete.disabled = _world_name == "" or _confirm.text != _world_name
