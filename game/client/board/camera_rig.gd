class_name CameraRig
extends Node3D
## Orbit camera. The rig sits on the point being looked at; the Camera3D child is pushed back along
## the rig's local +Z by `distance`. All tuning is exported, so adjust it in the Inspector.
##
## Controls: middle mouse drag = orbit, Shift + middle drag = pan, wheel = zoom,
## Q / E = quarter turn, F = reset the view.

@export_group("Start view")
@export_range(-360.0, 360.0) var start_yaw_deg: float = 45.0
@export_range(5.0, 89.0) var start_pitch_deg: float = 52.0
## Extra room around the map when the view is fitted to a map.
@export_range(0.5, 3.0) var fit_margin: float = 0.9

@export_group("Limits")
@export_range(5.0, 89.0) var pitch_min_deg: float = 15.0
@export_range(5.0, 89.0) var pitch_max_deg: float = 85.0
@export var distance_min: float = 4.0
@export var distance_max: float = 45.0
## How far the view can be panned beyond the map edge.
@export var pan_margin: float = 3.0

@export_group("Feel")
@export var orbit_deg_per_pixel: float = 0.3
@export var pan_speed: float = 0.0016   ## world units per pixel, scaled by distance
@export var zoom_factor: float = 1.12   ## distance multiplier per wheel notch
@export var snap_turn_deg: float = 90.0
@export_range(0.0, 40.0) var smoothing: float = 14.0  ## 0 = no smoothing
@export var invert_orbit_y: bool = false
@export var orthographic_size_per_distance: float = 0.55  ## used when the Camera3D is orthographic

@export_group("Nodes")
@export var camera: Camera3D

var yaw_deg: float = 45.0
var pitch_deg: float = 52.0
var distance: float = 14.0
var focus: Vector3 = Vector3.ZERO
## World-space box the focus point is kept inside (set by the board to the map's size).
var bounds: AABB = AABB(Vector3.ZERO, Vector3.ONE)

var _yaw: float = 45.0
var _pitch: float = 52.0
var _dist: float = 14.0
var _pos: Vector3 = Vector3.ZERO


func _ready() -> void:
	if camera == null:
		camera = get_node_or_null("Camera3D") as Camera3D
	yaw_deg = start_yaw_deg
	pitch_deg = start_pitch_deg
	_snap_to_targets()


## Points the rig at a map and fits the view; keeps the player's rotation if `keep_angles`.
func frame(map_bounds: AABB, keep_angles: bool = false) -> void:
	bounds = map_bounds
	focus = map_bounds.get_center()
	distance = clampf(fit_distance(map_bounds), distance_min, distance_max)
	if not keep_angles:
		yaw_deg = start_yaw_deg
		pitch_deg = start_pitch_deg
	_clamp_focus()


## Distance at which the whole map stays in view from any angle (fits its bounding sphere to the
## narrower of the camera's vertical and horizontal field of view).
func fit_distance(map_bounds: AABB) -> float:
	var radius := map_bounds.size.length() * 0.5
	var half_fov := deg_to_rad(40.0) * 0.5
	if camera != null and camera.projection == Camera3D.PROJECTION_PERSPECTIVE:
		half_fov = deg_to_rad(camera.fov) * 0.5
		if camera.is_inside_tree():
			var vp := camera.get_viewport().get_visible_rect().size
			if vp.y > 0.0:
				half_fov = minf(half_fov, atan(tan(half_fov) * vp.x / vp.y))
	return radius * fit_margin / sin(half_fov)


func reset_view() -> void:
	frame(bounds)


func turn(steps: int) -> void:
	yaw_deg += snap_turn_deg * steps


func orbit(delta_px: Vector2) -> void:
	yaw_deg -= delta_px.x * orbit_deg_per_pixel
	var dy := delta_px.y * orbit_deg_per_pixel
	pitch_deg = clampf(pitch_deg + (dy if invert_orbit_y else -dy), pitch_min_deg, pitch_max_deg)


func pan(delta_px: Vector2) -> void:
	var yaw := deg_to_rad(yaw_deg)
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var scale := pan_speed * distance
	focus += (-right * delta_px.x + forward * delta_px.y) * scale
	_clamp_focus()


func zoom(notches: float) -> void:
	distance = clampf(distance * pow(zoom_factor, -notches), distance_min, distance_max)


func _clamp_focus() -> void:
	var lo := bounds.position - Vector3(pan_margin, 0.0, pan_margin)
	var hi := bounds.end + Vector3(pan_margin, 0.0, pan_margin)
	focus = Vector3(clampf(focus.x, lo.x, hi.x), clampf(focus.y, lo.y, maxf(lo.y, hi.y)), clampf(focus.z, lo.z, hi.z))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			if mm.shift_pressed:
				pan(mm.relative)
			else:
				orbit(mm.relative)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				zoom(mb.factor if mb.factor > 0.0 else 1.0)
			elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				zoom(-(mb.factor if mb.factor > 0.0 else 1.0))
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			match k.keycode:
				KEY_Q: turn(-1)
				KEY_E: turn(1)
				KEY_F: reset_view()


func _process(delta: float) -> void:
	var t := 1.0 if smoothing <= 0.0 else 1.0 - exp(-smoothing * delta)
	_yaw = lerp_angle(_yaw, deg_to_rad(yaw_deg), t)
	_pitch = lerpf(_pitch, deg_to_rad(pitch_deg), t)
	_dist = lerpf(_dist, distance, t)
	_pos = _pos.lerp(focus, t)
	_apply()


func _snap_to_targets() -> void:
	_yaw = deg_to_rad(yaw_deg)
	_pitch = deg_to_rad(pitch_deg)
	_dist = distance
	_pos = focus
	_apply()


func _apply() -> void:
	position = _pos
	rotation = Vector3(-_pitch, _yaw, 0.0)
	if camera != null:
		camera.position = Vector3(0.0, 0.0, _dist)
		if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
			camera.size = _dist * orthographic_size_per_distance
