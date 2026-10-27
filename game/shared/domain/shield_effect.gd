class_name ShieldEffect
extends SkillEffect
## Gives a pool of points that soaks damage after armor and before HP. It does not stack: a new shield only replaces a lower one
## of the same length. No hit roll. PROVISIONAL numbers.

enum Lasts { ROUND, BEAT }

@export_range(0, 999) var amount: int = 0
## Round: until the end of the round. Beat: only until the beat it was raised in is over (a brace against what lands in that beat).
@export var lasts: Lasts = Lasts.ROUND


func to_dict() -> Dictionary:
	return {"type": "shield", "on": on, "amount": amount, "lasts": lasts}


func problems() -> Array[String]:
	return ["a shield effect needs an amount above 0"] if amount <= 0 else []
