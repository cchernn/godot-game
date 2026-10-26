extends TestCase

const ROWS: Array[String] = [
	"........",
	"..#.....",
	"........",
	"........"]


func _me() -> Dictionary:
	return {"id": "a", "name": "Aldric", "team": Enums.Team.PLAYERS, "cell": Vector2i(0, 0), "life": Enums.LifeState.ALIVE}


func _foe(id: String, cell: Vector2i) -> Dictionary:
	return {"id": id, "name": id.capitalize(), "team": Enums.Team.ENEMIES, "cell": cell, "life": Enums.LifeState.ALIVE}


func _skill(id: String) -> SkillDef:
	return SkillDb.load_file().get_skill(id)


func test_reachable_tiles_follow_the_ap_left() -> void:
	var bf := Battlefield.from_rows(ROWS)
	var two := TargetingPreview.reachable(bf, Vector2i(0, 0), {}, 1, 1, 2)
	assert_true(Vector2i(2, 0) in two and Vector2i(1, 1) in two)
	assert_true(not Vector2i(3, 0) in two, "three tiles cost 3 AP")
	assert_true(not Vector2i(0, 0) in two, "not the tile you stand on")
	assert_true(not Vector2i(2, 1) in two, "walls are not walkable")
	assert_eq(TargetingPreview.reachable(bf, Vector2i(0, 0), {}, 1, 1, 0).size(), 0)
	var blocked := TargetingPreview.reachable(bf, Vector2i(0, 0), {Vector2i(1, 0): true}, 1, 1, 1)
	assert_true(not Vector2i(1, 0) in blocked, "occupied tiles cannot be entered")


func test_a_faster_walker_reaches_further() -> void:
	var bf := Battlefield.from_rows(ROWS)
	var tiles := TargetingPreview.reachable(bf, Vector2i(0, 0), {}, 2, 1, 1)
	assert_true(Vector2i(2, 0) in tiles and not Vector2i(3, 0) in tiles, "2 tiles per AP")


func test_range_uses_manhattan_distance_and_line_of_sight() -> void:
	var bf := Battlefield.from_rows(ROWS)
	var tiles := TargetingPreview.tiles_in_range(bf, Vector2i(0, 1), 3)
	assert_true(Vector2i(1, 1) in tiles and Vector2i(0, 3) in tiles)
	assert_true(not Vector2i(0, 1) in tiles and not Vector2i(4, 1) in tiles)
	assert_true(not Vector2i(3, 1) in tiles, "the wall at (2,1) blocks the view along the row")


func test_valid_targets_and_the_reason_when_a_target_is_not_valid() -> void:
	var bf := Battlefield.from_rows(ROWS)
	var strike := _skill("strike")
	var near := _foe("near", Vector2i(1, 0))
	var far := _foe("far", Vector2i(5, 0))
	var ally := {"id": "b", "name": "Brea", "team": Enums.Team.PLAYERS, "cell": Vector2i(0, 1), "life": Enums.LifeState.ALIVE}
	var units := [_me(), near, far, ally]
	assert_eq(TargetingPreview.valid_targets(bf, units, _me(), strike, Vector2i(0, 0)), ["a", "near", "b"] as Array[String], "anyone in reach, friend, foe or yourself")
	assert_true(TargetingPreview.target_problem(bf, _me(), far, strike, Vector2i(0, 0)).begins_with("out of range"))
	assert_eq(TargetingPreview.target_problem(bf, _me(), ally, strike, Vector2i(0, 0)), "", "an ally can be struck")
	var revive := _skill("revive")
	assert_eq(TargetingPreview.target_problem(bf, _me(), ally, revive, Vector2i(0, 0)), "that unit is not downed")
	ally["life"] = Enums.LifeState.DOWNED
	assert_eq(TargetingPreview.target_problem(bf, _me(), ally, revive, Vector2i(0, 0)), "")
	near["life"] = Enums.LifeState.DOWNED
	assert_eq(TargetingPreview.target_problem(bf, _me(), near, revive, Vector2i(0, 0)), "", "an enemy that is downed can be revived too")


func test_hover_text_for_walks_and_targets() -> void:
	var bf := Battlefield.from_rows(ROWS)
	var mv := _skill("move")
	assert_eq(TargetingPreview.hover_text(mv, [], _me(), bf, Vector2i(0, 0), Vector2i(2, 0), 2, 2, 3), "2 tile(s), 2 AP (1 left after)")
	assert_eq(TargetingPreview.hover_text(mv, [], _me(), bf, Vector2i(0, 0), Vector2i(3, 0), 3, 3, 2), "3 tile(s), 3 AP: 1 more than you have")
	assert_eq(TargetingPreview.hover_text(mv, [], _me(), bf, Vector2i(0, 0), Vector2i(2, 1), 0, -1, 3), "No path to that tile")
	var strike := _skill("strike")
	var near := _foe("near", Vector2i(1, 0))
	assert_eq(TargetingPreview.hover_text(strike, [near], _me(), bf, Vector2i(0, 0), Vector2i(1, 0), 0, -1, 3), "Near: can be targeted")
	assert_eq(TargetingPreview.hover_text(strike, [near], _me(), bf, Vector2i(0, 0), Vector2i(4, 3), 0, -1, 3), "", "nothing there")
	var bolt := _skill("bolt")
	assert_eq(TargetingPreview.hover_text(bolt, [], _me(), bf, Vector2i(0, 0), Vector2i(7, 3), 0, -1, 3).substr(0, 12), "Out of range")


func test_a_queue_item_takes_one_beat_per_step() -> void:
	assert_eq(TargetingPreview.action_beats(_skill("move"), 5, 2), 3, "5 tiles at 2 per AP")
	assert_eq(TargetingPreview.action_beats(_skill("move"), 2, 1), 2)
	assert_eq(TargetingPreview.action_beats(_skill("strike"), 0, 1), 1)
	assert_eq(TargetingPreview.action_beats(_skill("power_strike"), 0, 1), 2, "a two-stage skill takes two beats")
