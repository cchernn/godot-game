class_name SkillDb
extends RefCounted
## Skill definitions loaded from skills.json (provisional values).

const DEFAULT_PATH := "res://game/shared/config/skills.json"
const KINDS := {"move": Enums.SkillKind.MOVE, "attack": Enums.SkillKind.ATTACK,
	"reaction": Enums.SkillKind.REACTION, "revive": Enums.SkillKind.REVIVE}
const TARGETING := {"none": Enums.Targeting.NONE, "character": Enums.Targeting.CHARACTER,
	"tile": Enums.Targeting.TILE}

var skills: Dictionary = {}


static func load_file(path: String = DEFAULT_PATH) -> SkillDb:
	var file := FileAccess.open(path, FileAccess.READ)
	assert(file != null, "Cannot open skills: %s" % path)
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	assert(parsed is Dictionary, "skills.json is not an object")
	var db := SkillDb.new()
	for id: String in (parsed as Dictionary):
		if id.begins_with("_"):
			continue
		var d: Dictionary = parsed[id]
		var s := SkillDef.new()
		s.id = id
		s.display_name = d["name"]
		s.kind = KINDS[d["kind"]]
		s.targeting = TARGETING[d.get("targeting", "none")]
		s.attack_range = d.get("range", 1)
		s.speed = d["speed"]
		s.frequency = Enums.Frequency.UNLIMITED if d.get("frequency", "once_per_turn") == "unlimited" \
			else Enums.Frequency.ONCE_PER_TURN
		s.stability = d.get("stability", 1)
		s.stages.assign(d["stages"])
		s.reaction = d.get("reaction", {})
		db.skills[id] = s
	return db


func get_skill(id: String) -> SkillDef:
	return skills.get(id) as SkillDef
