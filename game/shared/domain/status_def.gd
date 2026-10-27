class_name StatusDef
extends Resource
## A timed condition on a combatant (a buff, a debuff, bleeding, a stun). Make one as a resource in game/content/statuses/ and
## drag it into an Apply Status effect. It lasts a number of TURNS (rounds), not beats. PROVISIONAL numbers, none ship yet.

enum Kind { BUFF, DEBUFF, OTHER }
## REFRESH: applying again restarts the timer. STACK: applying again adds a stack (up to max_stacks) and restarts the timer.
## IGNORE: applying again does nothing while it lasts.
enum Stacking { REFRESH, STACK, IGNORE }

## The key the rules use to tell statuses apart. Unique, no spaces.
@export var id: String = ""
@export var display_name: String = ""
@export_multiline var hint: String = ""
## The icon shown over the unit on the board. Drop a texture here (a small square image) when there is one; until then the glyph below is shown.
@export var icon: Texture2D
## What the unit card shows, and what the board shows while there is no icon: a short glyph (1-2 characters) in this colour.
@export var glyph: String = "*"
@export var color: Color = Color(1, 1, 1)
## Buff, debuff or other. Cleanse effects can remove "all debuffs" or "all buffs".
@export var kind: Kind = Kind.OTHER
## How many turns it lasts. A status applied mid-turn counts the rest of that turn as its first turn.
@export_range(1, 99) var duration_turns: int = 2
@export var stacking: Stacking = Stacking.REFRESH
@export_range(1, 99) var max_stacks: int = 3

@export_group("Stat changes (per stack)")
@export var armor: int = 0
@export var power: int = 0
@export var accuracy: int = 0
@export var evasion: int = 0
## Also changes AP (from the next turn).
@export var dexterity: int = 0
## Also changes tiles moved per AP.
@export var agility: int = 0

@export_group("Each turn")
## Run on the bearer once at the start of every turn it lasts, once per stack (damage, heal or shield effects only; the target is always the bearer).
@export var tick_effects: Array[SkillEffect] = []

@export_group("Conditions")
## The bearer takes no actions while this lasts (not an interruption).
@export var stunned: bool = false
## The bearer cannot move.
@export var rooted: bool = false
## The bearer cannot use attacks or skills (it can still move, defend and use items).
@export var maimed: bool = false


## The plain view the battle rules read (also what the client shows).
func to_dict() -> Dictionary:
	var ticks: Array[Dictionary] = []
	for e in tick_effects:
		if e != null:
			ticks.append(e.to_dict())
	return {"id": id, "name": display_name if display_name != "" else id, "hint": hint, "glyph": glyph,
		"color": color.to_html(false), "kind": kind, "duration": duration_turns, "stacking": stacking,
		"max_stacks": max_stacks,
		"mods": {"armor": armor, "power": power, "accuracy": accuracy, "evasion": evasion, "dexterity": dexterity, "agility": agility},
		"ticks": ticks, "stunned": stunned, "rooted": rooted, "maimed": maimed}


func problems() -> Array[String]:
	var out: Array[String] = []
	if id == "" or id.contains(" "):
		out.append("a status needs an id without spaces")
	for e in tick_effects:
		if e == null:
			out.append("status '%s': an effect slot is empty" % id)
			continue
		if not (e is DamageEffect or e is HealEffect or e is ShieldEffect):
			out.append("status '%s': each-turn effects can only be damage, heal or shield" % id)
		if e is DamageEffect and ((e as DamageEffect).can_miss or (e as DamageEffect).can_crit):
			out.append("status '%s': each-turn damage cannot miss or crit (statuses use no random numbers)" % id)
		out.append_array(e.problems())
	return out
