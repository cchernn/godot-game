class_name MapCanvas
extends Control
## The overworld graph: one button per discovered node, a line per discovered route. Presentation only - the
## screen tells it what to show and hears which node was clicked. Positions come from a MapLayout resource.

signal node_pressed(node_id: String)

@export var layout: MapLayout
@export var node_scene: PackedScene
@export var route_color: Color = Color(0.5, 0.46, 0.38)
@export var route_here_color: Color = Color(0.95, 0.8, 0.4)
@export var route_width: float = 3.0
@export var here_tint: Color = Color(1.0, 0.85, 0.45)
@export var selected_tint: Color = Color(0.6, 0.85, 1.0)
## Keeps the buttons clear of the edges.
@export var margin: Vector2 = Vector2(60, 30)

var _nodes: Array = []
var _routes: Array = []
var _here: String = ""
var _selected: String = ""
var _buttons: Dictionary = {}


func _ready() -> void:
	resized.connect(_place)


## nodes/routes: the API overview lists; here: the node the party stands on; selected: the node being looked at.
func show_map(nodes: Array, routes: Array, here: String, selected: String) -> void:
	_nodes = nodes
	_routes = routes
	_here = here
	_selected = selected
	for id: String in _buttons.keys():
		if not _nodes.any(func(n: Dictionary) -> bool: return n["id"] == id):
			(_buttons[id] as Button).queue_free()
			_buttons.erase(id)
	for n: Dictionary in _nodes:
		var id := str(n["id"])
		if not _buttons.has(id):
			var b := node_scene.instantiate() as Button
			add_child(b)
			b.pressed.connect(func() -> void: node_pressed.emit(id))
			_buttons[id] = b
		var b: Button = _buttons[id]
		b.text = "%s%s" % ["* " if id == _here else "", n["name"]]
		b.tooltip_text = str(n.get("kind", ""))
		b.modulate = here_tint if id == _here else (selected_tint if id == _selected else Color.WHITE)
	_place()


func button_for(node_id: String) -> Button:
	return _buttons.get(node_id)


func _centre(index: int, id: String) -> Vector2:
	var p := layout.position_of(id, index, _nodes.size()) if layout != null else Vector2(0.5, 0.5)
	return margin + p * (size - margin * 2.0)


func _place() -> void:
	for i in _nodes.size():
		var id := str(_nodes[i]["id"])
		var b: Button = _buttons.get(id)
		if b != null:
			b.size = b.get_combined_minimum_size()
			b.position = (_centre(i, id) - b.size / 2.0).round()
	queue_redraw()


func _draw() -> void:
	var centres := {}
	for i in _nodes.size():
		centres[str(_nodes[i]["id"])] = _centre(i, str(_nodes[i]["id"]))
	for r: Dictionary in _routes:
		if centres.has(r["from"]) and centres.has(r["to"]):
			var touches_here: bool = r["from"] == _here or r["to"] == _here
			draw_line(centres[r["from"]], centres[r["to"]], route_here_color if touches_here else route_color, route_width, true)
