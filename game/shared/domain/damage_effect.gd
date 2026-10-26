class_name DamageEffect
extends SkillEffect
## Hurts the one it lands on. PROVISIONAL numbers. Order of the rules: hit roll, flanking and crit, minus armor, then any shield, then HP.

## Damage before the unit's power, armor and the hit roll.
@export_range(0, 999) var base: int = 0
## Needs to pass the hit roll (accuracy against evasion).
@export var can_miss: bool = true
## Can crit (and gets the flanking bonus from the side or rear).
@export var can_crit: bool = true
## The attacker's power is added to the base.
@export var uses_power: bool = true


func to_dict() -> Dictionary:
	return {"type": "damage", "on": on, "base": base, "can_miss": can_miss, "can_crit": can_crit, "uses_power": uses_power}


func problems() -> Array[String]:
	return ["a damage effect needs a base above 0"] if base <= 0 else []
