class_name EncounterTrigger
extends Resource
## Something that happens in a battle once: enemies wake up, arrive, or fall away. Edited in the Inspector on the encounter's Triggers list.
## Enemies are named by their place in the encounter's Enemies list (0 = the first). An enemy that a Wake trigger names starts dormant (on the
## map but inert); one that an Appear trigger names starts off the map. Both still count as enemies left to defeat.

enum When { ROUND_REACHED, ENEMY_DEFEATED }
enum Effect { WAKE, APPEAR, REMOVE }

## What sets it off: a round beginning, or one of the enemies being defeated.
@export var when: When = When.ROUND_REACHED
## ROUND_REACHED only: it fires when this round begins (2 = after the first round).
@export_range(1, 99) var at_round: int = 2
## ENEMY_DEFEATED only: the enemy (its place in the Enemies list) whose defeat sets it off.
@export_range(0, 31) var enemy: int = 0
## What it does to the enemies in Targets: wake them, bring them onto the map (on their spawn marker, or the nearest free tile), or take them off it.
@export var effect: Effect = Effect.WAKE
## The enemies it acts on (their places in the Enemies list).
@export var targets: PackedInt32Array = PackedInt32Array()
## Shown in the combat log when it fires (leave empty for none).
@export_multiline var message: String = ""


func problems(enemy_count: int) -> Array[String]:
	var out: Array[String] = []
	if when == When.ENEMY_DEFEATED and (enemy < 0 or enemy >= enemy_count):
		out.append("a trigger watches enemy %d but there are %d enemies" % [enemy, enemy_count])
	if targets.is_empty():
		out.append("a trigger has no targets")
	for t in targets:
		if t < 0 or t >= enemy_count:
			out.append("a trigger acts on enemy %d but there are %d enemies" % [t, enemy_count])
		elif when == When.ENEMY_DEFEATED and t == enemy and effect != Effect.REMOVE:
			out.append("a trigger acts on the enemy it watches")
	return out
