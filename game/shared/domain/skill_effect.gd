class_name SkillEffect
extends Resource
## One thing a skill stage does. Pick the subclass in the Inspector (Damage, Heal, Shield, Interrupt) and fill in its numbers.
## Nothing in the rules distinguishes friend from foe: an effect lands on whoever it is aimed at.

enum On { TARGET, CASTER }

## Who receives the effect: whoever the skill is aimed at, or the one using it.
@export var on: On = On.TARGET


## The plain view the battle rules read: {type, on, ...numbers}.
func to_dict() -> Dictionary:
	return {"type": "", "on": on}


func problems() -> Array[String]:
	return []
