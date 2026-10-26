class_name PlannedAction
extends RefCounted
## One queued action. Parsed defensively: network input is untrusted.

var skill_id: String = ""
## Set when the action uses an item; skill_id is then the item's skill ("item:<id>").
var item_id: String = ""
var path: Array[Vector2i] = []
var facing: int = -1
var target_id: String = ""
var target_cell: Vector2i = Vector2i(-1, -1)
var has_cell: bool = false
## AP planned at commit time (reserved), still unspent, and already spent.
var reserved: int = 0
var reserved_left: int = 0
var spent: int = 0


static func _to_cell(v: Variant) -> Variant:
	if v is Vector2i:
		return v
	if v is Array and (v as Array).size() == 2 and (v as Array)[0] is int and (v as Array)[1] is int:
		return Vector2i((v as Array)[0], (v as Array)[1])
	return null


## Returns null if malformed.
static func from_dict(d: Variant) -> PlannedAction:
	if not d is Dictionary:
		return null
	var dict: Dictionary = d
	var a := PlannedAction.new()
	if dict.has("item"):
		if not dict["item"] is String or (dict["item"] as String) == "" or (dict["item"] as String).length() > 64:
			return null
		a.item_id = dict["item"]
		a.skill_id = ItemDef.skill_id_for(a.item_id)
	elif dict.get("skill") is String:
		a.skill_id = dict["skill"]
	else:
		return null
	if dict.has("path"):
		if not dict["path"] is Array:
			return null
		for p: Variant in (dict["path"] as Array):
			var c: Variant = _to_cell(p)
			if c == null:
				return null
			a.path.append(c as Vector2i)
	if dict.has("facing"):
		if not dict["facing"] is int or (dict["facing"] as int) < 0 or (dict["facing"] as int) > 3:
			return null
		a.facing = dict["facing"]
	if dict.has("target"):
		if not dict["target"] is String:
			return null
		a.target_id = dict["target"]
	if dict.has("cell"):
		var c2: Variant = _to_cell(dict["cell"])
		if c2 == null:
			return null
		a.target_cell = c2 as Vector2i
		a.has_cell = true
	return a


func to_dict() -> Dictionary:
	var d := {"skill": skill_id}
	if item_id != "":
		d["item"] = item_id
	if not path.is_empty():
		d["path"] = path.duplicate()
	if facing >= 0:
		d["facing"] = facing
	if target_id != "":
		d["target"] = target_id
	if has_cell:
		d["cell"] = target_cell
	d["reserved"] = reserved
	return d
