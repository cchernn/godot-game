extends TestCase

const KIND := Enums.SkillKind
const TARGET := Enums.Targeting
const FREQ := Enums.Frequency

## The skills as they were in skills.json before they became resources.
const ORIGINAL := {
	"move": {"name": "Move", "kind": KIND.MOVE, "targeting": TARGET.NONE, "range": 1, "speed": 5, "freq": FREQ.UNLIMITED,
		"stability": 3, "stages": [["step", 1, 0, 0]], "reaction": {}},
	"strike": {"name": "Strike", "kind": KIND.ATTACK, "targeting": TARGET.CHARACTER, "range": 1, "speed": 6, "freq": FREQ.ONCE_PER_TURN,
		"stability": 1, "stages": [["strike", 1, 6, 1]], "reaction": {}},
	"power_strike": {"name": "Power Strike", "kind": KIND.ATTACK, "targeting": TARGET.CHARACTER, "range": 1, "speed": 4, "freq": FREQ.ONCE_PER_TURN,
		"stability": 2, "stages": [["wind-up", 1, 0, 0], ["smash", 1, 12, 2]], "reaction": {}},
	"bolt": {"name": "Bolt", "kind": KIND.ATTACK, "targeting": TARGET.TILE, "range": 5, "speed": 5, "freq": FREQ.ONCE_PER_TURN,
		"stability": 1, "stages": [["bolt", 1, 5, 1]], "reaction": {}},
	"disrupt": {"name": "Disrupt", "kind": KIND.REACTION, "targeting": TARGET.NONE, "range": 1, "speed": 7, "freq": FREQ.ONCE_PER_TURN,
		"stability": 1, "stages": [["ready", 1, 0, 0]], "reaction": {"range": 3, "duration_beats": 6, "interrupt": 2}},
	"revive": {"name": "Revive", "kind": KIND.REVIVE, "targeting": TARGET.CHARACTER, "range": 1, "speed": 5, "freq": FREQ.ONCE_PER_TURN,
		"stability": 1, "stages": [["revive", 2, 0, 0]], "reaction": {}},
}


func test_converted_skills_match_the_original_values() -> void:
	var db := SkillDb.load_file()
	assert_eq(db.skills.size(), ORIGINAL.size())
	for id: String in ORIGINAL:
		var want: Dictionary = ORIGINAL[id]
		var s := db.get_skill(id)
		assert_true(s != null, id)
		assert_eq(s.display_name, want["name"], id)
		assert_eq(s.kind, want["kind"], "%s kind" % id)
		assert_eq(s.targeting, want["targeting"], "%s targeting" % id)
		assert_eq(s.attack_range, want["range"], "%s range" % id)
		assert_eq(s.speed, want["speed"], "%s speed" % id)
		assert_eq(s.frequency, want["freq"], "%s frequency" % id)
		assert_eq(s.stability, want["stability"], "%s stability" % id)
		assert_eq(s.reaction, want["reaction"], "%s reaction" % id)
		var got: Array = []
		for st: Dictionary in s.stages:
			got.append([st["name"], st["ap"], st["damage"], st["interrupt"]])
		assert_eq(got, want["stages"], "%s stages" % id)


func test_the_skill_set_is_valid_and_file_names_match_ids() -> void:
	var set := load("res://game/content/skills/skill_set.tres") as SkillSet
	assert_eq(set.problems(), [] as Array[String])
	for s in set.skills:
		assert_eq(s.resource_path.get_file().get_basename(), s.id, "file name is the id")
	var files: Array[String] = []
	for f in DirAccess.get_files_at("res://game/content/skills"):
		if f.ends_with(".tres") and f != "skill_set.tres":
			files.append(f.get_basename())
	files.sort()
	var ids: Array[String] = []
	for s in set.skills:
		ids.append(s.id)
	ids.sort()
	assert_eq(files, ids, "every skill file is listed in the set, and nothing else is")


func test_the_views_the_rules_read_have_the_expected_shape() -> void:
	var db := SkillDb.load_file()
	var ps := db.get_skill("power_strike")
	assert_eq(ps.total_ap(), 2)
	assert_true(ps.is_multistage())
	assert_eq(ps.stages[1], {"name": "smash", "ap": 1, "damage": 12, "interrupt": 2})
	assert_true(not db.get_skill("strike").is_multistage())
	assert_eq(db.get_skill("strike").reaction, {}, "only reactions have reaction data")
	assert_eq(db.get_skill("disrupt").reaction["duration_beats"], 6)


func test_each_load_hands_out_independent_copies() -> void:
	var a := SkillDb.load_file()
	var b := SkillDb.load_file()
	a.get_skill("strike").speed = 99
	a.get_skill("strike").stage_defs[0].damage = 500
	assert_eq(b.get_skill("strike").speed, 6)
	assert_eq(b.get_skill("strike").stages[0]["damage"], 6)
	assert_eq(SkillDb.load_file().get_skill("strike").speed, 6, "the shared resource is untouched")


func test_changing_the_stage_list_refreshes_the_view() -> void:
	var s := SkillDb.load_file().get_skill("strike")
	assert_eq(s.total_ap(), 1)
	var extra := SkillStage.new()
	extra.stage_name = "follow-through"
	extra.ap = 2
	var stages: Array[SkillStage] = [s.stage_defs[0], extra]
	s.stage_defs = stages
	assert_eq(s.total_ap(), 3)
	assert_true(s.is_multistage())


func test_inspector_hides_fields_that_do_not_apply_to_the_kind() -> void:
	var s := SkillDef.new()
	s.kind = KIND.ATTACK
	var p := {"name": "reaction_range", "usage": PROPERTY_USAGE_DEFAULT}
	s._validate_property(p)
	assert_eq(p["usage"], PROPERTY_USAGE_NO_EDITOR, "reaction fields are hidden for attacks")
	s.kind = KIND.REACTION
	p = {"name": "reaction_range", "usage": PROPERTY_USAGE_DEFAULT}
	s._validate_property(p)
	assert_eq(p["usage"], PROPERTY_USAGE_DEFAULT, "and shown for reactions")
	p = {"name": "targeting", "usage": PROPERTY_USAGE_DEFAULT}
	s._validate_property(p)
	assert_eq(p["usage"], PROPERTY_USAGE_NO_EDITOR, "targeting is hidden for reactions")
	s.kind = KIND.ATTACK
	p = {"name": "targeting", "usage": PROPERTY_USAGE_DEFAULT}
	s._validate_property(p)
	assert_eq(p["usage"], PROPERTY_USAGE_DEFAULT)


func test_problems_name_the_skill_and_the_mistake() -> void:
	var s := SkillDef.new()
	assert_true(s.problems().size() >= 3, "empty skill: id, name, stages")
	s.id = "zap"
	s.display_name = "Zap"
	s.kind = KIND.ATTACK
	s.targeting = TARGET.NONE
	var stage := SkillStage.new()
	var one: Array[SkillStage] = [stage]
	s.stage_defs = one
	var issues := s.problems()
	assert_eq(issues.size(), 1)
	assert_true(issues[0].contains("zap") and issues[0].contains("target"), issues[0])
	s.kind = KIND.REACTION
	assert_true(str(s.problems()).contains("duration"), "a reaction needs range and duration")
	var set := SkillSet.new()
	var two: Array[SkillDef] = [load("res://game/content/skills/move.tres"), load("res://game/content/skills/move.tres")]
	set.skills = two
	assert_true(str(set.problems()).contains("twice"))


func test_every_skill_has_a_hint() -> void:
	for s in SkillDb.load_file().skills.values():
		assert_true((s as SkillDef).hint != "", "%s has a hint" % s.id)
