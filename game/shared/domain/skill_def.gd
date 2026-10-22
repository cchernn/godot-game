class_name SkillDef
extends RefCounted

var id: String
var display_name: String
var kind: int = Enums.SkillKind.ATTACK
var targeting: int = Enums.Targeting.NONE
var attack_range: int = 1
var speed: int = 5
var frequency: int = Enums.Frequency.ONCE_PER_TURN
## Interruption points needed to cancel this skill while it is in progress.
var stability: int = 1
## Each stage: {name, ap, damage, interrupt}
var stages: Array[Dictionary] = []
## Reactions only: {range, duration_beats, interrupt}
var reaction: Dictionary = {}


func total_ap() -> int:
	var t := 0
	for s in stages:
		t += s["ap"] as int
	return t


func is_multistage() -> bool:
	return stages.size() > 1
