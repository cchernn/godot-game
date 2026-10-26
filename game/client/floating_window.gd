class_name FloatingWindow
extends PanelContainer
## A window over the game view: a title bar, a close button (X) and a scrolling body. The layout is
## game/content/ui/floating_window.tscn; instance it, tick "Editable Children" and put your controls under Layout/Scroll/Body.
## Where it sits is decided by its anchors and offsets in the scene. It opens, closes itself and says when it was closed
## (so a toggle button elsewhere can pop back up).

signal closed

@export var title: String = "Window":
	set(value):
		title = value
		if is_node_ready():
			_title.text = value
## How big the scrolling body is at least; the window is the body plus its title bar.
@export var body_min_size: Vector2 = Vector2(320, 240):
	set(value):
		body_min_size = value
		if is_node_ready():
			_scroll.custom_minimum_size = value

@onready var _title: Label = $Layout/TitleBar/TitleLabel
@onready var _scroll: ScrollContainer = $Layout/Scroll


func _ready() -> void:
	_title.text = title
	_scroll.custom_minimum_size = body_min_size
	$Layout/TitleBar/CloseButton.pressed.connect(close)


func open() -> void:
	show()
	move_to_front()


func close() -> void:
	hide()
	closed.emit()
