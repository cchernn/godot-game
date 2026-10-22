class_name SkillStage
extends Resource
## One step of a skill. Multi-stage skills (like Power Strike: wind up, then smash) list several; each stage is
## paid for with its own action points and can be interrupted between stages.

## Shown in the combat log, e.g. "wind-up" or "smash".
@export var stage_name: String = ""
## Action points this stage costs.
@export_range(0, 9) var ap: int = 1
## Damage dealt when this stage lands (before the unit's power, armor and the hit roll). 0 = no damage.
@export_range(0, 999) var damage: int = 0
## Interruption points this stage adds to a victim it hits (see the target's skill "stability").
@export_range(0, 99) var interrupt: int = 0


## The shape the battle rules read (kept so the rules code does not depend on resources).
func to_dict() -> Dictionary:
	return {"name": stage_name, "ap": ap, "damage": damage, "interrupt": interrupt}
