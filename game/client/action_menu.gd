class_name ActionMenu
extends PanelContainer
## The menu that opens where you click on the board: one entry per action that makes sense there (see ActionOptions). Layout and look
## are in game/content/ui/action_menu.tscn and action_button.tscn. The menu only reports what was chosen or hovered.

signal chosen(option: Dictionary)
## The option under the mouse or keyboard focus; empty when the pointer leaves the entries.
signal previewed(option: Dictionary)
signal closed

@export var entry_scene: PackedScene
@export var title_label: Label
@export var entries: VBoxContainer
## Space kept between the menu and the edge of the window, and the offset from the click.
@export var edge_margin: float = 8.0
@export var click_offset: Vector2 = Vector2(14, 10)

var _options: Array[Dictionary] = []


## Shows the menu for `opts` near `at`, kept inside `bounds` (both in this node's parent's coordinates).
func open(opts: Array[Dictionary], title: String, at: Vector2, bounds: Rect2) -> void:
	_clear()
	_options = opts
	title_label.text = title
	for o in opts:
		var b := entry_scene.instantiate() as Button
		b.text = _text_for(o)
		b.icon = o.get("icon") as Texture2D
		b.disabled = not o["enabled"]
		b.tooltip_text = _tooltip_for(o)
		b.pressed.connect(_on_pressed.bind(o))
		b.mouse_entered.connect(previewed.emit.bind(o))
		b.focus_entered.connect(previewed.emit.bind(o))
		b.mouse_exited.connect(previewed.emit.bind({}))
		entries.add_child(b)
	show()
	reset_size()
	var sz := get_combined_minimum_size()
	var pos := at + click_offset
	pos.x = clampf(pos.x, bounds.position.x + edge_margin, maxf(bounds.position.x + edge_margin, bounds.end.x - sz.x - edge_margin))
	pos.y = clampf(pos.y, bounds.position.y + edge_margin, maxf(bounds.position.y + edge_margin, bounds.end.y - sz.y - edge_margin))
	position = pos


func close() -> void:
	if visible:
		hide()
		_clear()
		closed.emit()


func is_open() -> bool:
	return visible


func entry_count() -> int:
	return entries.get_child_count()


func _clear() -> void:
	for ch in entries.get_children():
		entries.remove_child(ch)
		ch.queue_free()
	_options = []


func _on_pressed(option: Dictionary) -> void:
	close()
	chosen.emit(option)


func _text_for(o: Dictionary) -> String:
	var line := "%s   %d AP" % [o["label"], o["ap"]]
	if not o["enabled"]:
		return "%s   (%s)" % [line, o["reason"]]
	return line + ("   %s" % o["summary"] if o["summary"] != "" else "")


func _tooltip_for(o: Dictionary) -> String:
	var parts: Array[String] = []
	for key: String in ["hint", "summary"]:
		if str(o[key]) != "":
			parts.append(str(o[key]))
	if not o["enabled"]:
		parts.append("Not now: %s" % o["reason"])
	return "\n".join(parts)
