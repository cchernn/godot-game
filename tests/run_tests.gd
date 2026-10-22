extends SceneTree
## Minimal headless test runner. Usage:
##   scripts/godot.sh --headless --path . --script res://tests/run_tests.gd
## Test files: tests/unit/test_*.gd extending TestCase; methods named test_*.

var _failures := 0
var _passed := 0


func _initialize() -> void:
	await process_frame # scene-tree tests (board, units) need a running tree
	var dir := DirAccess.open("res://tests/unit")
	var files: Array[String] = []
	for f in dir.get_files():
		if f.begins_with("test_") and f.ends_with(".gd"):
			files.append(f)
	files.sort()
	for f in files:
		var script: GDScript = load("res://tests/unit/" + f)
		var tc: TestCase = script.new()
		for m in script.get_script_method_list():
			var name: String = m["name"]
			if not name.begins_with("test_"):
				continue
			tc.failed = []
			tc.call(name)
			if tc.failed.is_empty():
				_passed += 1
			else:
				_failures += 1
				for msg in tc.failed:
					printerr("FAIL %s::%s — %s" % [f, name, msg])
	print("%d passed, %d failed" % [_passed, _failures])
	quit(1 if _failures > 0 else 0)
