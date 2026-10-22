extends TestCase

const AREA := AABB(Vector3(0, 0, 0), Vector3(10, 2, 8))


func _rig() -> CameraRig:
	var rig := CameraRig.new()
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	rig.add_child(cam)
	rig.camera = cam
	rig._ready()
	rig.frame(AREA)
	return rig


func test_frame_centres_on_the_map_and_fits_distance() -> void:
	var rig := _rig()
	assert_eq(rig.focus, Vector3(5, 1, 4))
	assert_true(rig.distance >= rig.distance_min and rig.distance <= rig.distance_max)
	rig.free()


func test_orbit_changes_yaw_and_clamps_pitch() -> void:
	var rig := _rig()
	var yaw := rig.yaw_deg
	rig.orbit(Vector2(100, 0))
	assert_true(rig.yaw_deg < yaw, "dragging right turns the view")
	rig.orbit(Vector2(0, 100000))
	assert_true(rig.pitch_deg >= rig.pitch_min_deg and rig.pitch_deg <= rig.pitch_max_deg)
	rig.orbit(Vector2(0, -100000))
	assert_true(rig.pitch_deg >= rig.pitch_min_deg and rig.pitch_deg <= rig.pitch_max_deg)
	rig.free()


func test_zoom_is_limited() -> void:
	var rig := _rig()
	var d := rig.distance
	rig.zoom(1.0)
	assert_true(rig.distance < d, "wheel up zooms in")
	for i in 100:
		rig.zoom(1.0)
	assert_eq(rig.distance, rig.distance_min)
	for i in 100:
		rig.zoom(-1.0)
	assert_eq(rig.distance, rig.distance_max)
	rig.free()


func test_pan_moves_the_focus_but_stays_near_the_map() -> void:
	var rig := _rig()
	var before := rig.focus
	rig.pan(Vector2(50, 0))
	assert_true(rig.focus != before)
	for i in 500:
		rig.pan(Vector2(400, 400))
	assert_true(rig.bounds.grow(rig.pan_margin + 0.01).has_point(Vector3(rig.focus.x, 1.0, rig.focus.z)))
	rig.free()


func test_quarter_turns_and_reset() -> void:
	var rig := _rig()
	var yaw := rig.yaw_deg
	rig.turn(1)
	assert_eq(rig.yaw_deg, yaw + 90.0)
	rig.turn(-2)
	assert_eq(rig.yaw_deg, yaw - 90.0)
	rig.reset_view()
	assert_eq(rig.yaw_deg, rig.start_yaw_deg)
	rig.free()


func test_input_events_drive_the_camera() -> void:
	var rig := _rig()
	var yaw := rig.yaw_deg
	var drag := InputEventMouseMotion.new()
	drag.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	drag.relative = Vector2(40, 0)
	rig._unhandled_input(drag)
	assert_true(rig.yaw_deg != yaw, "middle-drag orbits")
	var focus := rig.focus
	var pan := InputEventMouseMotion.new()
	pan.button_mask = MOUSE_BUTTON_MASK_MIDDLE
	pan.shift_pressed = true
	pan.relative = Vector2(30, 0)
	rig._unhandled_input(pan)
	assert_true(rig.focus != focus, "shift + middle-drag pans")
	var plain := InputEventMouseMotion.new()
	plain.relative = Vector2(60, 60)
	var y2 := rig.yaw_deg
	rig._unhandled_input(plain)
	assert_eq(rig.yaw_deg, y2, "moving without the middle button does nothing")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	var dist := rig.distance
	rig._unhandled_input(wheel)
	assert_true(rig.distance < dist, "wheel zooms")
	var key := InputEventKey.new()
	key.keycode = KEY_E
	key.pressed = true
	var y3 := rig.yaw_deg
	rig._unhandled_input(key)
	assert_eq(rig.yaw_deg, y3 + 90.0, "E turns a quarter")
	rig.free()


func test_camera_follows_the_targets_after_processing() -> void:
	var rig := _rig()
	rig.yaw_deg = 135.0
	rig.distance = 20.0
	for i in 60:
		rig._process(0.1)
	assert_true(absf(rig.rotation.y - deg_to_rad(135.0)) < 0.01)
	assert_true(absf(rig.camera.position.z - 20.0) < 0.05)
	rig.free()
