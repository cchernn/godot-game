extends Node
## Design preview: shows the board with a sample battle, no server needed. Open
## board_preview.tscn and press F6. Orbit/pan/zoom with the mouse, click a tile to print its cell.
## Edit the map, tiles or unit scenes, save, and run it again.

@export var players: int = 4
@export var seed_value: int = 1
## Which seat's point of view to show (fog of war follows it).
@export var viewer_seat: int = 0

@onready var board: Board3D = $Board3D


func _ready() -> void:
	var battle := Encounter.build(GameConfig.load_file(), SkillDb.load_file(), players, seed_value)
	board.set_snapshot(battle.snapshot_for("pc%d" % viewer_seat))
	board.cell_clicked.connect(func(cell: Vector2i, unit_id: String) -> void:
		print("clicked cell %s  unit '%s'  elevation %d" % [str(cell), unit_id, board.bf.elevation_at(cell)]))
