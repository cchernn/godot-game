class_name BoardMarker
extends Node3D
## A symbol standing on a tile: a ring and a small number above it. This is a scene (content/board/markers/*.tscn): change the ring's
## mesh and material or the label's font and colour in the editor; the script only sets the text and spins the ring.

@export var ring: Node3D
@export var label: Label3D
## Radians per second; 0 keeps the ring still.
@export var spin_speed: float = 1.0


func set_text(text: String) -> void:
	if label != null:
		label.text = text
		label.visible = text != ""


func _process(delta: float) -> void:
	if ring != null and spin_speed != 0.0:
		ring.rotate_y(spin_speed * delta)
