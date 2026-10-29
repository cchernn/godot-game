class_name Persistence
extends RefCounted
## Boundary between gameplay and durable storage. Gameplay code only ever sees this interface;
## the implementation talks to the FastAPI service, never to the database directly.


## Returns {ok, user_id, character: Dictionary or null, instance: Dictionary, error}. Identity is derived from
## the token; the API checks the user is a member of `world_id`, returns their active character there, and
## (for a party) checks the character is on the active party's roster and describes the party.
func verify_session(_token: String, _world_id: String, _instance_id: String = "") -> Dictionary:
	return {"ok": false, "error": "Persistence is not configured"}


## participants: [{character_id, outcome, gold, items_used: {item id: copies}, items_gained: {item id: copies}, flags_set: [flag]}].
## `instance_id` is the activity run this battle was ("" for none): its authored rewards are applied on a win.
## Idempotent per key. Returns {ok, duplicate, rewards: {character id: {gold, items: {item id: copies}, flags}}, error}.
## `step_id` names the event step a battle was (events only): that step's own rewards apply, on a win or on the lose route.
func commit_result(_world_id: String, _key: String, _outcome: String, _rounds: int, _participants: Array, _instance_id: String = "", _step_id: String = "") -> Dictionary:
	return {"ok": true, "duplicate": false, "rewards": {}}


## A story step of an event ended: pays the step's rewards once to `participants` (character ids), plus the flags of the `choice` made.
## Returns {ok, rewards: {character id: {gold, items, flags}}, error}.
func complete_step(_instance_id: String, _step_id: String, _participants: Array, _choice: String = "") -> Dictionary:
	return {"ok": true, "rewards": {}}


## Returns {ok, instance: {status, encounter, max_players, roster: [{id, user_id, name, class}]}, error}.
func get_instance(_instance_id: String) -> Dictionary:
	return {"ok": false, "error": "Persistence is not configured"}


## Win completes the instance (applying its world changes atomically); anything else cancels it.
## `participants` (character ids who reached the end) are paid a story's rewards; empty = the whole roster.
## Idempotent. Returns {ok, world_changed, rewards: {character id: {gold, items, flags}}, error}.
func finish_instance(_instance_id: String, _success: bool, _participants: Array = []) -> Dictionary:
	return {"ok": true, "world_changed": false, "rewards": {}}
