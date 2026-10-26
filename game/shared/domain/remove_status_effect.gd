class_name RemoveStatusEffect
extends SkillEffect
## Takes statuses off whoever the effect is aimed at (a cleanse).

enum Mode { ONE, BUFFS, DEBUFFS, ALL }

## ONE removes only the status below; the others remove every status of that kind (or all of them).
@export var mode: Mode = Mode.DEBUFFS
@export var status: StatusDef


func to_dict() -> Dictionary:
	return {"type": "remove_status", "on": on, "mode": mode, "status_id": status.id if status != null else ""}


func problems() -> Array[String]:
	if mode == Mode.ONE and status == null:
		return ["a remove-status effect set to One needs a status"]
	return []
