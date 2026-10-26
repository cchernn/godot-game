class_name UnlockCondition
extends Resource
## One requirement for a skill unlock (see SkillUnlock). Pick a subclass in the Inspector: LevelCondition, AttributeCondition or
## EventCondition. Not usable by itself.


## `ctx` = {level: int, attributes: {name: int}, flags: Array[String]}.
func met(_ctx: Dictionary) -> bool:
	return false


## What is wrong with this condition, if anything (empty = fine).
func problem() -> String:
	return "pick a condition type (level, attribute or event)"
