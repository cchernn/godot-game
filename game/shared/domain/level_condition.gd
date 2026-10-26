class_name LevelCondition
extends UnlockCondition
## Met once the character has reached this level.

@export_range(1, 99) var min_level: int = 2


func met(ctx: Dictionary) -> bool:
	return int(ctx.get("level", 1)) >= min_level


func problem() -> String:
	return ""
