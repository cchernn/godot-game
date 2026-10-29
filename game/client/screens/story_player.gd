class_name StoryPlayer
extends Control
## The visual-novel screen (screens/story_player.tscn): a backdrop, up to two standing portraits, a text box and choices.
## It only draws what the server says and reports presses; the server decides when the story moves on.
##
## state: {story: id, path: [slide indices shown so far], waiting: [names still to continue], you_continued: bool,
##         can_choose: bool, finished: bool}

signal continue_pressed
signal choice_chosen(choice_id: String)

@export_group("Parts")
@export var backdrop_color: ColorRect
@export var backdrop_picture: TextureRect
@export var left_portrait: StoryPortrait
@export var right_portrait: StoryPortrait
@export var speaker_label: Label
@export var text_label: RichTextLabel
@export var choices_box: Container
@export var waiting_label: Label
@export var continue_hint: Control
@export var text_box: Control
## The button scene one choice is made from (a Button). Style it in the editor.
@export var choice_button_scene: PackedScene

@export_group("Look")
## How fast the line is typed out. 0 shows it at once.
@export_range(0.0, 400.0) var characters_per_second: float = 70.0
@export var default_backdrop: Color = Color(0.06, 0.07, 0.1)
@export var waiting_text: String = "Waiting for %s"
@export var leader_picks_text: String = "The party leader chooses"

var story_id: String = ""
var _def: StoryDef
var _shown_index: int = -1
var _typing: bool = false
var _state: Dictionary = {}


func _ready() -> void:
	if text_box != null:
		text_box.gui_input.connect(_on_text_box_input)


func _process(delta: float) -> void:
	if _typing and text_label != null:
		var total := text_label.get_total_character_count()
		if characters_per_second <= 0.0 or total == 0:
			_finish_typing()
			return
		text_label.visible_characters = mini(total, text_label.visible_characters + maxi(1, roundi(characters_per_second * delta)))
		if text_label.visible_characters >= total:
			_finish_typing()


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not event is InputEventKey:
		return
	var k := event as InputEventKey
	if k.pressed and not k.echo and k.keycode in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER]:
		_advance()
		get_viewport().set_input_as_handled()


func show_state(state: Dictionary) -> void:
	_state = state
	if str(state.get("story", "")) != story_id:
		story_id = str(state.get("story", ""))
		_def = StoryDef.load_story(story_id)
		_shown_index = -1
	if _def == null or (state.get("path", []) as Array).is_empty():
		return
	var path: Array = state["path"]
	var index: int = path[path.size() - 1]
	var slide := _def.slides[index]
	var stage := _def.stage_after(path)
	_set_backdrop(stage)
	left_portrait.show_actor(stage["left"], slide.actor != null and slide.side == StorySlide.Stand.LEFT)
	right_portrait.show_actor(stage["right"], slide.actor != null and slide.side == StorySlide.Stand.RIGHT)
	if index != _shown_index:
		_shown_index = index
		speaker_label.text = slide.actor.display_name if slide.actor != null else ""
		speaker_label.visible = slide.actor != null
		text_label.text = slide.text
		text_label.visible_characters = 0
		_typing = true
		_build_choices(slide)
	_refresh_waiting(slide)


func _set_backdrop(stage: Dictionary) -> void:
	backdrop_picture.texture = stage["picture"]
	backdrop_picture.visible = stage["picture"] != null
	var c: Color = stage["color"]
	backdrop_color.color = c if c.a > 0.0 else default_backdrop


func _build_choices(slide: StorySlide) -> void:
	for ch in choices_box.get_children():
		choices_box.remove_child(ch)
		ch.queue_free()
	choices_box.visible = not slide.choices.is_empty()
	for c in slide.choices:
		var b: Button = choice_button_scene.instantiate() if choice_button_scene != null else Button.new()
		b.text = c.text
		b.set_meta("choice_id", c.id)
		b.pressed.connect(func() -> void: choice_chosen.emit(c.id))
		choices_box.add_child(b)


func _refresh_waiting(slide: StorySlide) -> void:
	var is_choice := not slide.choices.is_empty()
	for b in choices_box.get_children():
		(b as Button).disabled = not _state.get("can_choose", false)
	var names: Array = _state.get("waiting", [])
	continue_hint.visible = not is_choice and not _typing and not _state.get("you_continued", false)
	if is_choice:
		waiting_label.text = "" if _state.get("can_choose", false) else leader_picks_text
	elif _state.get("you_continued", false) and not names.is_empty():
		waiting_label.text = waiting_text % ", ".join(PackedStringArray(names))
	else:
		waiting_label.text = ""


func _finish_typing() -> void:
	_typing = false
	text_label.visible_characters = -1
	if _def != null and _shown_index >= 0:
		_refresh_waiting(_def.slides[_shown_index])


func _on_text_box_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_advance()


## A press while the line is still typing shows the whole line; the next one reports Continue.
func _advance() -> void:
	if _def == null or _shown_index < 0:
		return
	if _typing:
		_finish_typing()
	elif _def.slides[_shown_index].choices.is_empty() and not _state.get("you_continued", false):
		continue_pressed.emit()
