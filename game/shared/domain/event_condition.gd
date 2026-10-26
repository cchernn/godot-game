class_name EventCondition
extends UnlockCondition
## Met once the character has the named event flag. Flags are set by the game (a story event, a quest); the API stores them.

## Lower-case with no spaces, e.g. "met_the_hermit".
@export var flag: String = ""


func met(ctx: Dictionary) -> bool:
	return flag != "" and flag in (ctx.get("flags", []) as Array)


func problem() -> String:
	return "" if flag != "" and flag == flag.to_lower() and not " " in flag else "event flag must be lower-case with no spaces (got '%s')" % flag
