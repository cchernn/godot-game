class_name ContextObjectDef
extends Resource
## A kind of map object a unit can act on: a chest, a lever, a door, a trap (game/content/objects/*.tres). Put one on a map by
## adding the map_object.tscn scene under the map's Objects node and assigning this resource. Its state lives only for one battle.

@export var id: String = ""
@export var display_name: String = ""
@export_multiline var hint: String = ""
## The state at the start of every battle, e.g. "closed". States are just names you choose.
@export var initial_state: String = "closed"
## How close (Manhattan tiles) a unit must be to act on it. 1 = next to it; 0 = standing on it.
@export_range(0, 3) var reach: int = 1
## While the object is in one of these states, nobody can walk onto its tile (a closed door, a chest).
@export var blocking_states: Array[String] = []
@export var actions: Array[ContextAction] = []


func action(action_id: String) -> ContextAction:
	for a in actions:
		if a != null and a.id == action_id:
			return a
	return null


func problems() -> Array[String]:
	var out: Array[String] = []
	if id == "" or id != id.to_lower() or " " in id:
		out.append("object id must be lower-case with no spaces (got '%s')" % id)
	if display_name == "":
		out.append("%s: display_name is empty" % id)
	if actions.is_empty():
		out.append("%s: has no actions" % id)
	var states := {initial_state: true}
	for s in blocking_states:
		states[s] = true
	var seen := {}
	for a in actions:
		if a == null:
			out.append("%s: an action slot is empty" % id)
			continue
		out.append_array(a.problems(id))
		if seen.has(a.id):
			out.append("%s: action '%s' is listed twice" % [id, a.id])
		seen[a.id] = true
		if a.sets_state != "":
			states[a.sets_state] = true
	for s: String in states:
		if s == "" or s != s.to_lower() or " " in s:
			out.append("%s: state names must be lower-case with no spaces (got '%s')" % [id, s])
	for a in actions:
		if a != null and a.requires_state != "" and not states.has(a.requires_state):
			out.append("%s/%s: requires state '%s' which the object never has" % [id, a.id, a.requires_state])
	return out
