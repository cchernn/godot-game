class_name ChatBubble
extends Node3D
## What a unit just said, floating over its head in a box that grows with the text. This is a scene
## (content/board/markers/chat_bubble.tscn): restyle the label and the box there; the script sizes the box, keeps it
## up for as long as the line takes to read and fades it out. The scene's origin is the bubble's bottom edge.

@export var label: Label3D
@export var background: MeshInstance3D
## Space between the text and the edge of the box (world units).
@export var padding: Vector2 = Vector2(0.14, 0.08)
## It stays up this long, plus a little more for every character, then fades for `fade_seconds`.
@export var seconds_base: float = 3.0
@export var seconds_per_char: float = 0.04
@export var fade_seconds: float = 0.6

var _age: float = 0.0
var _lifetime: float = 0.0
var _wait_for_layout: bool = true
var _box_material: StandardMaterial3D
var _box_alpha: float = 1.0


func _ready() -> void:
	# The scene's meshes and materials are shared by every bubble; each one needs its own to size and fade independently.
	var mesh := background.mesh.duplicate() as QuadMesh
	background.mesh = mesh
	if background.material_override is StandardMaterial3D:
		_box_material = (background.material_override as StandardMaterial3D).duplicate()
		background.material_override = _box_material
		_box_alpha = _box_material.albedo_color.a


## Starts showing `text`. The box is sized on the next frame, once the label has measured itself.
func play(text: String) -> void:
	label.text = text
	_lifetime = seconds_base + seconds_per_char * text.length() + fade_seconds
	_age = 0.0
	_wait_for_layout = true
	visible = false


func _process(delta: float) -> void:
	if _wait_for_layout:
		_layout()
		return
	_age += delta
	var left := _lifetime - _age
	var alpha := clampf(left / fade_seconds, 0.0, 1.0) if fade_seconds > 0.0 else 1.0
	_set_alpha(alpha)
	if left <= 0.0:
		queue_free()


## Which text is showing (for tests and for replacing a bubble).
func text() -> String:
	return label.text


func box_size() -> Vector2:
	return (background.mesh as QuadMesh).size


func _layout() -> void:
	var text_box := label.get_aabb().size
	if text_box.x <= 0.0 or text_box.y <= 0.0:
		return # not measured yet; try again next frame
	var size := Vector2(text_box.x, text_box.y) + padding * 2.0
	(background.mesh as QuadMesh).size = size
	background.position = Vector3(0.0, size.y * 0.5, 0.0)
	label.position = Vector3(0.0, size.y * 0.5, 0.0)
	_wait_for_layout = false
	visible = true


func _set_alpha(alpha: float) -> void:
	var c := label.modulate
	c.a = alpha
	label.modulate = c
	var o := label.outline_modulate
	o.a = alpha
	label.outline_modulate = o
	if _box_material != null:
		var b := _box_material.albedo_color
		_box_material.albedo_color = Color(b.r, b.g, b.b, alpha * _box_alpha)

