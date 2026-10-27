class_name FloatingText
extends Node3D
## A number or word that rises from a unit and fades out (damage, healing, a status). This is a scene
## (content/board/markers/floating_text.tscn): restyle the label there; the script moves and fades it.

@export var label: Label3D
## How far it rises (world units) and how long it lives (seconds).
@export var rise: float = 1.1
@export var duration: float = 1.2
## The share of the lifetime, at the end, spent fading out.
@export_range(0.0, 1.0) var fade_share: float = 0.4

var _age: float = 0.0
var _delay: float = 0.0
var _base: Vector3


## `delay` staggers several texts that start together; `size` scales the font (a crit is bigger).
func play(text: String, color: Color, size: float = 1.0, delay: float = 0.0) -> void:
	label.text = text
	label.modulate = color
	label.font_size = roundi(label.font_size * size)
	_delay = delay
	_base = position
	label.visible = delay <= 0.0


func _process(delta: float) -> void:
	if _delay > 0.0:
		_delay -= delta
		if _delay > 0.0:
			return
		label.visible = true
	_age += delta
	var t := clampf(_age / duration, 0.0, 1.0)
	position = _base + Vector3(0.0, rise * (1.0 - pow(1.0 - t, 2.0)), 0.0) # eases out
	var fade_from := 1.0 - fade_share
	var m := label.modulate
	m.a = 1.0 if t < fade_from else clampf((1.0 - t) / fade_share, 0.0, 1.0)
	label.modulate = m
	if _age >= duration:
		queue_free()
