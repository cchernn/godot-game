class_name ChatPanel
extends PanelContainer
## A small chat box: a title that folds it away, the lines said so far and a line to type in. The layout is chat_panel.tscn
## (restyle it there); the owner feeds it with add_line() and listens for `submitted`.
## Enter focuses the input, Enter again sends, Esc leaves it.

## A line was written and sent (already trimmed, never empty).
signal submitted(text: String)

@export var title: String = "Chat":
	set(value):
		title = value
		if is_node_ready():
			_refresh_title()
## Oldest lines are dropped beyond this many.
@export var max_lines: int = 80
@export var speaker_color: Color = Color(0.95, 0.8, 0.25)
@export var mine_color: Color = Color(0.55, 0.85, 1.0)
@export var system_color: Color = Color(0.7, 0.7, 0.75)

@onready var _fold: Button = %FoldButton
@onready var _body: Control = %Body
@onready var _log: RichTextLabel = %Log
@onready var _line: LineEdit = %Input

var _folded: bool = false


func _ready() -> void:
	_fold.pressed.connect(func() -> void: set_folded(not _folded))
	_line.text_submitted.connect(_on_text_submitted)
	_line.max_length = int(GameConfig.load_file().get_value("chat", "max_length"))
	_refresh_title()


func _refresh_title() -> void:
	_fold.text = "%s %s" % ["▸" if _folded else "▾", title]


func set_folded(on: bool) -> void:
	_folded = on
	_body.visible = not on
	_refresh_title()


func clear() -> void:
	_log.clear()


## `speaker` is who said it; "" with system = true is a line from the game itself.
func add_line(speaker: String, text: String, mine: bool = false, system: bool = false) -> void:
	if not mine and not system and speaker != "":
		AudioDirector.cue("chat")
	var safe := text.replace("[", "[lb]")
	if system or speaker == "":
		_log.append_text("[color=#%s][i]%s[/i][/color]\n" % [system_color.to_html(false), safe])
	else:
		var col := mine_color if mine else speaker_color
		_log.append_text("[color=#%s]%s:[/color] %s\n" % [col.to_html(false), speaker.replace("[", "[lb]"), safe])
	while _log.get_paragraph_count() > max_lines:
		_log.remove_paragraph(0)


func is_typing() -> bool:
	return _line.has_focus()


func _on_text_submitted(text: String) -> void:
	var line := text.strip_edges()
	_line.clear()
	_line.release_focus()
	if line != "":
		submitted.emit(line)


func _unhandled_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or _folded:
		return
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER:
		_line.grab_focus()
		get_viewport().set_input_as_handled()


func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_ESCAPE and _line.has_focus():
		_line.release_focus()
		get_viewport().set_input_as_handled()
