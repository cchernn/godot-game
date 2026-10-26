class_name InterruptEffect
extends SkillEffect
## Adds interruption points to the skill the target is in the middle of (see that skill's stability). Only lands if the stage's damage landed.

@export_range(0, 99) var points: int = 1


func to_dict() -> Dictionary:
	return {"type": "interrupt", "on": on, "points": points}


func problems() -> Array[String]:
	return ["an interrupt effect needs points above 0"] if points <= 0 else []
