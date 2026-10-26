class_name SetFlagEffect
extends SkillEffect
## Gives the receiving character an event flag (what some skill unlocks wait for). Kept in the battle result and saved with it.

## Lower-case with no spaces, e.g. "opened_the_vault".
@export var flag: String = ""


func to_dict() -> Dictionary:
	return {"type": "set_flag", "on": on, "flag": flag}


func problems() -> Array[String]:
	if flag == "" or flag != flag.to_lower() or " " in flag:
		return ["a set flag effect needs a lower-case flag with no spaces (got '%s')" % flag]
	return []
