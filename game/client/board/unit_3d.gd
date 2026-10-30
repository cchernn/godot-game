class_name Unit3D
extends Node3D
## One combatant on the board. This is a scene (units/*.tscn): replace the Body mesh with your own
## model, add an AnimationPlayer with "idle", "walk" and "downed" animations, restyle the labels.
## The script only fills in what the server says (name, health, facing, state).

@export_group("Parts")
@export var body: MeshInstance3D          ## tinted by team when it has a StandardMaterial3D override
@export var facing_pivot: Node3D          ## rotates to the unit's facing
@export var name_label: Label3D
@export var status_label: Label3D
@export var hp_fill: MeshInstance3D       ## scaled horizontally by health
@export var animation_player: AnimationPlayer
## Where the status badges stand (above the head, centred) and the scene each one is made from (content/board/markers/status_icon.tscn).
@export var status_row: Node3D
@export var status_icon_scene: PackedScene
## Chat bubbles stand this high above the unit's feet, clear of the status badges (the bubble scene itself is set on the board).
@export var bubble_height: float = 2.35
## A ring on the ground (and a glow on the body) shown while the mouse is over the unit or its menu is open.
@export var hover_ring: Node3D

@export_group("Look")
## Multiplies the Body's own scale: a quick way to make a unit broader, taller or smaller.
@export var body_scale: Vector3 = Vector3.ONE
@export var hp_width: float = 0.8
@export var team_color: Color = Color(0.35, 0.6, 0.95)
@export var enemy_color: Color = Color(0.9, 0.3, 0.3)
@export var you_color: Color = Color(0.95, 0.8, 0.25)
@export var downed_color: Color = Color(0.5, 0.5, 0.55)
@export var hp_player_color: Color = Color(0.35, 0.85, 0.4)
@export var hp_enemy_color: Color = Color(0.9, 0.35, 0.35)
@export_range(0.0, 1.0) var inactive_darken: float = 0.4
## Distance between neighbouring status badges.
@export var status_icon_spacing: float = 0.34
## How strongly the body glows while hovered (0 = no glow, only the ring).
@export_range(0.0, 2.0) var hover_glow: float = 0.6
@export var hover_glow_color: Color = Color(1, 0.9, 0.5)

@export_group("Picking")
@export var pick_height: float = 0.6
@export var pick_radius: float = 0.5

var unit_id: String = ""
var downed: bool = false
var _body_material: StandardMaterial3D
var _fill_material: StandardMaterial3D
var _last_pos: Vector3
var _moving_for: float = 0.0
var _status_sig: int = 0
var _hovered: bool = false
var _status_icons: Array[StatusIcon] = []
var _bubble: ChatBubble = null


func _ready() -> void:
	if body != null:
		body.scale *= body_scale
	if body != null and body.material_override is StandardMaterial3D:
		_body_material = (body.material_override as StandardMaterial3D).duplicate()
		body.material_override = _body_material
	if hp_fill != null and hp_fill.material_override is StandardMaterial3D:
		_fill_material = (hp_fill.material_override as StandardMaterial3D).duplicate()
		hp_fill.material_override = _fill_material
	_last_pos = position
	_play("idle")


## Shows `text` in a bubble over the unit, replacing the one it had.
func say(bubble_scene: PackedScene, text: String) -> void:
	if is_instance_valid(_bubble):
		_bubble.queue_free()
	_bubble = bubble_scene.instantiate() as ChatBubble
	add_child(_bubble)
	_bubble.position = Vector3(0.0, bubble_height, 0.0)
	_bubble.play(text)


## Applies a snapshot unit dictionary.
func apply(u: Dictionary, is_you: bool) -> void:
	unit_id = u["id"]
	var enemy: bool = u["team"] == Enums.Team.ENEMIES
	downed = u["life"] == Enums.LifeState.DOWNED
	var col := enemy_color if enemy else (you_color if is_you else team_color)
	if downed:
		col = downed_color
	elif not u["active"]:
		col = col.darkened(inactive_darken)
	if _body_material != null:
		_body_material.albedo_color = col
	if name_label != null:
		name_label.text = u["name"]
	if facing_pivot != null:
		var d: Vector2i = Enums.DIRS[u["facing"] as int]
		facing_pivot.rotation.y = atan2(float(d.x), float(d.y))
	var ratio := clampf(float(u["hp"]) / maxf(1.0, float(u["max_hp"])), 0.0, 1.0)
	if hp_fill != null:
		hp_fill.scale.x = maxf(ratio, 0.001)
		hp_fill.position.x = -(1.0 - ratio) * hp_width * 0.5
	if _fill_material != null:
		_fill_material.albedo_color = hp_enemy_color if enemy else hp_player_color
	if status_label != null:
		if u.get("online", true) == false:
			status_label.text = "offline"
		elif u.get("dormant", false):
			status_label.text = "dormant"
		elif not enemy and u["ready"]:
			status_label.text = "ready"
		else:
			status_label.text = ""
	_show_statuses(u.get("statuses", []))
	if downed:
		_play("downed")


## Shows or hides the hover highlight (ring and glow).
func set_hovered(on: bool) -> void:
	if on == _hovered:
		return
	_hovered = on
	if hover_ring != null:
		hover_ring.visible = on
	if _body_material != null:
		_body_material.emission_enabled = on and hover_glow > 0.0
		_body_material.emission = hover_glow_color
		_body_material.emission_energy_multiplier = hover_glow


## One badge per status, side by side above the head, rebuilt only when the statuses change.
func _show_statuses(list: Array) -> void:
	if status_row == null or status_icon_scene == null:
		return
	var sig := hash(list)
	if sig == _status_sig:
		return
	_status_sig = sig
	while _status_icons.size() < list.size():
		var icon := status_icon_scene.instantiate() as StatusIcon
		status_row.add_child(icon)
		_status_icons.append(icon)
	for i in _status_icons.size():
		_status_icons[i].visible = i < list.size()
		if i < list.size():
			_status_icons[i].position = Vector3((i - (list.size() - 1) * 0.5) * status_icon_spacing, 0.0, 0.0)
			_status_icons[i].show_status(list[i])


func set_world_position(p: Vector3, delta: float) -> void:
	var moved := p.distance_to(position) > 0.001
	position = p
	_moving_for = 0.15 if moved else maxf(_moving_for - delta, 0.0)
	if not downed:
		_play("walk" if _moving_for > 0.0 else "idle")


func _play(anim: String) -> void:
	if animation_player != null and animation_player.has_animation(anim) and animation_player.current_animation != anim:
		animation_player.play(anim)
