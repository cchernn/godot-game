@tool
class_name SkillDef
extends Resource
## One skill, edited in the Inspector (game/content/skills/*.tres). All numbers are PROVISIONAL.
## The battle rules read the plain views at the bottom (stages, reaction), so they do not depend on resources.

@export_group("Identity")
## Lower-case id: the file name, and what units list and plans refer to.
@export var id: String = ""
## Shown on buttons and in the combat log.
@export var display_name: String = ""
## One line shown as the button tooltip and under the skill list when the skill is picked.
@export var hint: String = ""
## Where it sits in the action bar. Moves always sit on Move; most skills are in the Attack list; the default Defend sits on Defend.
@export var action_slot: Enums.ActionSlot = Enums.ActionSlot.ATTACK
@export var kind: Enums.SkillKind = Enums.SkillKind.ATTACK:
	set(v):
		kind = v
		notify_property_list_changed()

@export_group("Targeting")
## What the player clicks: a character (the skill follows them), a tile (it hits whatever is there when it lands),
## yourself (no click), or nothing (moves, reactions). Anyone can be aimed at, friend or foe.
@export var targeting: Enums.Targeting = Enums.Targeting.NONE
## Reach in tiles (Manhattan distance) for attacks and revives.
@export_range(0, 20) var attack_range: int = 1

@export_group("Area")
## Empty (or Single) = hits one target. Otherwise everyone on the covered tiles is hit, friend or foe. A character-targeted skill
## covers its area around the target's tile when it lands; a tile-targeted skill around the aimed tile, which the player sees while planning.
@export var area: AreaShape

@export_group("Timing")
## Higher resolves first within a beat.
@export_range(0, 20) var speed: int = 5
## Once per turn, or as often as the unit has action points for.
@export var frequency: Enums.Frequency = Enums.Frequency.ONCE_PER_TURN
## Interruption points needed to cancel this skill while it is in progress.
@export_range(0, 20) var stability: int = 1

@export_group("Stages")
## The steps of the skill, in order. Each costs its own AP.
@export var stage_defs: Array[SkillStage] = []:
	set(v):
		stage_defs = v
		_stages_dirty = true

@export_group("Reaction")
## Reactions only: how far away an enemy's action triggers it.
@export_range(0, 20) var reaction_range: int = 0
## Reactions only: how many beats the prepared reaction stays ready.
@export_range(0, 40) var reaction_duration_beats: int = 0
## Reactions only: interruption points it adds to the enemy it triggers on.
@export_range(0, 20) var reaction_interrupt: int = 0

var _stages_view: Array[Dictionary] = []
var _stages_dirty: bool = true


func _validate_property(property: Dictionary) -> void:
	if str(property["name"]).begins_with("reaction_") and kind != Enums.SkillKind.REACTION:
		property["usage"] = PROPERTY_USAGE_NO_EDITOR
	elif str(property["name"]) in ["targeting", "attack_range"] and kind in [Enums.SkillKind.MOVE, Enums.SkillKind.REACTION]:
		property["usage"] = PROPERTY_USAGE_NO_EDITOR
	elif str(property["name"]) == "area" and kind not in [Enums.SkillKind.ATTACK, Enums.SkillKind.SUPPORT]:
		property["usage"] = PROPERTY_USAGE_NO_EDITOR


# ---- views the battle rules read ----

## True when the skill covers more than one tile.
func is_area() -> bool:
	return area != null and not area.is_single()


func slot() -> Enums.ActionSlot:
	return Enums.ActionSlot.MOVE if kind == Enums.SkillKind.MOVE else action_slot



## Each stage as {name, ap, damage, interrupt}.
var stages: Array[Dictionary]:
	get:
		if _stages_dirty:
			_stages_view = []
			for s in stage_defs:
				_stages_view.append(s.to_dict())
			_stages_dirty = false
		return _stages_view

## Reactions only: {range, duration_beats, interrupt}; empty for every other kind.
var reaction: Dictionary:
	get:
		if kind != Enums.SkillKind.REACTION:
			return {}
		return {"range": reaction_range, "duration_beats": reaction_duration_beats, "interrupt": reaction_interrupt}


func total_ap() -> int:
	var t := 0
	for s in stages:
		t += s["ap"] as int
	return t


func is_multistage() -> bool:
	return stages.size() > 1


## What is wrong with this skill, if anything (empty = fine).
func problems() -> Array[String]:
	var out: Array[String] = []
	if id == "" or id != id.to_lower() or " " in id:
		out.append("skill id must be lower-case with no spaces (got '%s')" % id)
	if display_name == "":
		out.append("%s: display_name is empty" % id)
	if stage_defs.is_empty():
		out.append("%s: has no stages" % id)
	for s in stage_defs:
		if s == null:
			out.append("%s: a stage slot is empty" % id)
	for s in stage_defs:
		if s != null:
			for p in s.problems():
				out.append("%s: %s" % [id, p])
	if kind in [Enums.SkillKind.ATTACK, Enums.SkillKind.SUPPORT] and targeting == Enums.Targeting.NONE:
		out.append("%s: needs a target type (character, tile or self)" % id)
	if area != null:
		out.append_array(area.problems())
		if not area.is_single() and kind not in [Enums.SkillKind.ATTACK, Enums.SkillKind.SUPPORT]:
			out.append("%s: only attack and support skills can have an area" % id)
	if kind == Enums.SkillKind.REVIVE and targeting != Enums.Targeting.CHARACTER:
		out.append("%s: a revive targets a character" % id)
	if kind == Enums.SkillKind.REACTION and (reaction_duration_beats < 1 or reaction_range < 1):
		out.append("%s: a reaction needs a range and a duration of at least 1" % id)
	return out
