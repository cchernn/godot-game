class_name SkillDb
extends RefCounted
## The skills in the game, looked up by id. Loaded from the SkillSet resource (provisional values).
## Every load returns its own copies, so a test (or a mod) can change one without touching the shared files.

const DEFAULT_PATH := "res://game/content/skills/skill_set.tres"

var skills: Dictionary = {}


static func load_file(path: String = DEFAULT_PATH) -> SkillDb:
	var set := load(path) as SkillSet
	assert(set != null, "Cannot load the skill set: %s" % path)
	var db := SkillDb.new()
	for s in set.skills:
		var copy := s.duplicate(true) as SkillDef
		db.skills[copy.id] = copy
	return db


func get_skill(id: String) -> SkillDef:
	return skills.get(id) as SkillDef
