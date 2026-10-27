class_name StatusIcon
extends Node3D
## One status badge over a unit (game/content/board/markers/status_icon.tscn): the status's icon (the Icon texture on its StatusDef in
## content/statuses), or its glyph in its colour until it has one, with the turns left under it. Restyle the scene in the editor.

const DIR := "res://game/content/statuses/"
static var _defs: Dictionary = {}

@export var glyph_label: Label3D
@export var turns_label: Label3D
@export var picture: Sprite3D
## The longest side of an icon texture in world units.
@export var picture_size: float = 0.3


## `s` is a snapshot status: {id, name, glyph, color, turns, stacks, ...}.
func show_status(s: Dictionary) -> void:
	var def := _def_for(str(s.get("id", "")))
	var tex: Texture2D = def.icon if def != null else null
	picture.visible = tex != null
	glyph_label.visible = tex == null
	if tex != null:
		picture.texture = tex
		picture.pixel_size = picture_size / maxf(1.0, float(maxi(tex.get_width(), tex.get_height())))
	else:
		glyph_label.text = str(s.get("glyph", "*"))
		glyph_label.modulate = Color.html(str(s.get("color", "ffffff")))
	var turns := int(s.get("turns", 0))
	var stacks := int(s.get("stacks", 1))
	turns_label.text = ("%d" % turns) + ("×%d" % stacks if stacks > 1 else "")


static func _def_for(id: String) -> StatusDef:
	if id == "" or id != id.to_lower() or not id.is_valid_identifier():
		return null
	if not _defs.has(id):
		var path := DIR + id + ".tres"
		_defs[id] = load(path) as StatusDef if ResourceLoader.exists(path) else null
	return _defs[id]
