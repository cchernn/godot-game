extends SceneTree
## Needs frames, so it is not a unit test: a bubble sizes its box to the text once the label has measured itself.
##   scripts/godot.sh --headless --path . --script res://tests/chat_bubble_check.gd


func _initialize() -> void:
	var scene := load("res://game/content/board/markers/chat_bubble.tscn") as PackedScene
	var short := scene.instantiate() as ChatBubble
	var long := scene.instantiate() as ChatBubble
	root.add_child(short)
	root.add_child(long)
	short.play("Hi")
	long.play("This is a much longer line of chat, long enough that it has to wrap onto several lines inside its box.")
	for i in 4:
		await process_frame
	var ok := true
	if not short.visible or not long.visible:
		printerr("FAIL: the bubbles did not appear")
		ok = false
	var a := short.box_size()
	var b := long.box_size()
	print("short box %s, long box %s" % [a, b])
	if not (b.x > a.x and b.y > a.y):
		printerr("FAIL: the longer line should have a bigger box")
		ok = false
	print("chat bubble check: %s" % ("OK" if ok else "FAILED"))
	quit(0 if ok else 1)
