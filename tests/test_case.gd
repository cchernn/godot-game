class_name TestCase
extends RefCounted

var failed: Array[String] = []


func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> void:
	if actual != expected:
		failed.append("expected %s, got %s %s" % [str(expected), str(actual), msg])


func assert_true(cond: bool, msg: String = "") -> void:
	if not cond:
		failed.append("expected true " + msg)


func V(x: int, y: int) -> Vector2i:
	return Vector2i(x, y)
