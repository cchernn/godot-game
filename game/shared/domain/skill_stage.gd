class_name SkillStage
extends Resource
## One step of a skill. Multi-stage skills (like Power Strike: wind up, then smash) list several; each stage is
## paid for with its own action points and can be interrupted between stages.

## Shown in the combat log, e.g. "wind-up" or "smash".
@export var stage_name: String = ""
## Action points this stage costs.
@export_range(0, 9) var ap: int = 1
## What happens when this stage lands, in order. Empty = a preparation step (a wind-up).
@export var effects: Array[SkillEffect] = []


## The shape the battle rules read (kept so the rules code does not depend on resources). `damage` and `interrupt` are the
## sums of the damage and interrupt effects aimed at the target, for the AI and quick checks.
func to_dict() -> Dictionary:
	var fx: Array[Dictionary] = []
	var damage := 0
	var interrupt := 0
	for e in effects:
		if e == null:
			continue
		var d := e.to_dict()
		fx.append(d)
		if e.on == SkillEffect.On.TARGET:
			if e is DamageEffect:
				damage += (e as DamageEffect).base
			elif e is InterruptEffect:
				interrupt += (e as InterruptEffect).points
	return {"name": stage_name, "ap": ap, "damage": damage, "interrupt": interrupt, "effects": fx}


func problems() -> Array[String]:
	var out: Array[String] = []
	for e in effects:
		if e == null:
			out.append("an effect slot is empty")
		else:
			out.append_array(e.problems())
	return out
