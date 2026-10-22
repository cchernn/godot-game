class_name Persistence
extends RefCounted
## Boundary between gameplay and durable storage. Gameplay code only ever sees this interface;
## the implementation talks to the FastAPI service, never to the database directly.


## Returns {ok, user_id, character: Dictionary or null, error}. Identity is derived from the token.
func verify_session(_token: String) -> Dictionary:
	return {"ok": false, "error": "Persistence is not configured"}


## participants: [{character_id, outcome, xp}]. Idempotent per key. Returns {ok, duplicate, error}.
func commit_result(_key: String, _outcome: String, _rounds: int, _participants: Array) -> Dictionary:
	return {"ok": true, "duplicate": false}


## Returns {ok, instance: {status, roster: [{id, user_id, name}]}, error}.
func get_instance(_instance_id: String) -> Dictionary:
	return {"ok": false, "error": "Persistence is not configured"}


## Win completes the instance (applying its world changes atomically); anything else cancels it.
## Idempotent. Returns {ok, world_changed, error}.
func finish_instance(_instance_id: String, _success: bool) -> Dictionary:
	return {"ok": true, "world_changed": false}
