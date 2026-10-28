class_name HttpPersistence
extends Persistence
## Persistence over HTTPS to the FastAPI service, authenticated with a service key.

var host: Node
var base_url: String
var api_key: String


func _init(p_host: Node, p_base_url: String, p_api_key: String) -> void:
	host = p_host
	base_url = p_base_url.rstrip("/")
	api_key = p_api_key


func _post(path: String, body: Dictionary) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 10.0
	host.add_child(req)
	var err := req.request(base_url + path, ["Content-Type: application/json", "Authorization: Bearer " + api_key],
		HTTPClient.METHOD_POST, JSON.stringify(body))
	if err != OK:
		req.queue_free()
		return {"ok": false, "status": 0, "body": {}, "error": "request failed (%d)" % err}
	var res: Array = await req.request_completed
	req.queue_free()
	var status: int = res[1]
	var parsed: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	var data: Dictionary = parsed if parsed is Dictionary else {}
	var detail: String = str(data.get("detail", "HTTP %d" % status))
	return {"ok": status >= 200 and status < 300, "status": status, "body": data, "error": detail}


func verify_session(token: String, world_id: String, instance_id: String = "") -> Dictionary:
	var body := {"token": token, "world_id": world_id}
	if instance_id != "":
		body["instance_id"] = instance_id
	var r := await _post("/internal/auth/session", body)
	if not r["ok"]:
		return {"ok": false, "error": "Sign-in failed: %s" % r["error"]}
	var b: Dictionary = r["body"]
	return {"ok": true, "user_id": b["user_id"], "character": b["character"], "instance": b.get("instance", {})}


func commit_result(world_id: String, key: String, outcome: String, rounds: int, participants: Array, instance_id: String = "") -> Dictionary:
	var body := {"idempotency_key": key, "world_id": world_id, "outcome": outcome, "rounds": rounds, "participants": participants}
	if instance_id != "":
		body["instance_id"] = instance_id
	var r := await _post("/internal/combat-results", body)
	var b: Dictionary = r["body"]
	return {"ok": r["ok"], "duplicate": b.get("duplicate", false), "rewards": b.get("rewards", {}), "error": r["error"]}


func get_instance(instance_id: String) -> Dictionary:
	var req := HTTPRequest.new()
	req.timeout = 10.0
	host.add_child(req)
	if req.request("%s/internal/instances/%s" % [base_url, instance_id], ["Authorization: Bearer " + api_key]) != OK:
		req.queue_free()
		return {"ok": false, "error": "request failed"}
	var res: Array = await req.request_completed
	req.queue_free()
	var parsed: Variant = JSON.parse_string((res[3] as PackedByteArray).get_string_from_utf8())
	if res[1] != 200 or not parsed is Dictionary:
		return {"ok": false, "error": "HTTP %d" % res[1]}
	return {"ok": true, "instance": parsed}


func finish_instance(instance_id: String, success: bool) -> Dictionary:
	var r := await _post("/internal/instances/%s/%s" % [instance_id, "complete" if success else "cancel"], {})
	return {"ok": r["ok"], "world_changed": (r["body"] as Dictionary).get("world_changed", false), "error": r["error"]}
