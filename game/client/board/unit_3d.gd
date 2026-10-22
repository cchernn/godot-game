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

@export_group("Picking")
@export var pick_height: float = 0.6
@export var pick_radius: float = 0.5

var unit_id: String = ""
var downed: bool = false
var _body_material: StandardMaterial3D
var _fill_material: StandardMaterial3D
var _last_pos: Vector3
var _moving_for: float = 0.0


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
		elif not enemy and u["ready"]:
			status_label.text = "ready"
		else:
			status_label.text = ""
	if downed:
		_play("downed")


func set_world_position(p: Vector3, delta: float) -> void:
	var moved := p.distance_to(position) > 0.001
	position = p
	_moving_for = 0.15 if moved else maxf(_moving_for - delta, 0.0)
	if not downed:
		_play("walk" if _moving_for > 0.0 else "idle")


func _play(anim: String) -> void:
	if animation_player != null and animation_player.has_animation(anim) and animation_player.current_animation != anim:
		animation_player.play(anim)
