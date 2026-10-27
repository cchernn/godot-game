class_name ApplyStatusEffect
extends SkillEffect
## Puts a status on whoever the effect is aimed at. When it follows a damage effect aimed at the target, it only lands if that damage
## connected. No roll of its own (statuses never use the battle's random numbers).

@export var status: StatusDef
## 0 = use the status's own duration; otherwise last this many turns.
@export_range(0, 99) var duration_turns: int = 0
## The chance (percent) it lands, once the damage before it has connected. 100 = always. Uses the battle's seeded random numbers.
@export_range(1, 100) var chance_percent: int = 100


func to_dict() -> Dictionary:
	return {"type": "apply_status", "on": on, "status": status.to_dict() if status != null else {}, "duration": duration_turns, "chance": chance_percent}


func problems() -> Array[String]:
	if status == null:
		return ["an apply-status effect needs a status"]
	return status.problems()
