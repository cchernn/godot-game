class_name HealEffect
extends SkillEffect
## Restores HP, never above the maximum. Does nothing to a downed unit (reviving is its own skill). No hit roll. PROVISIONAL numbers.

@export_range(0, 999) var amount: int = 0


func to_dict() -> Dictionary:
	return {"type": "heal", "on": on, "amount": amount}


func problems() -> Array[String]:
	return ["a heal effect needs an amount above 0"] if amount <= 0 else []
