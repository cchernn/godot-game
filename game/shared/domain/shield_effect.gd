class_name ShieldEffect
extends SkillEffect
## Gives a pool of points that soaks damage after armor and before HP. It lasts until the end of the round and does not stack:
## a new shield only replaces a lower one. No hit roll. PROVISIONAL numbers.

@export_range(0, 999) var amount: int = 0


func to_dict() -> Dictionary:
	return {"type": "shield", "on": on, "amount": amount}


func problems() -> Array[String]:
	return ["a shield effect needs an amount above 0"] if amount <= 0 else []
