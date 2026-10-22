extends Node
## Dedicated headless server entry point.

func _ready() -> void:
	if "--check" in OS.get_cmdline_user_args(): # boot check without listening
		var cfg := GameConfig.load_file()
		print("[server] ok (Godot %s), beats/round=%d" % [Engine.get_version_info().string, cfg.get_value("combat", "beats_per_round")])
		get_tree().quit()
		return
	add_child(load("res://game/server/server_app.gd").new())
