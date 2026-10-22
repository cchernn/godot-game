extends SceneTree
## One-time scaffold: turns game/shared/config/skills.json into one SkillDef resource per skill plus the SkillSet:
##   game/content/skills/<id>.tres and game/content/skills/skill_set.tres
##   scripts/godot.sh --headless --path . --script res://tools/generate_skills.gd
## Never overwrites existing files; `-- --force` regenerates and discards edits. (The JSON is deleted once converted.)

const SOURCE := "res://game/shared/config/skills.json"
const OUT := "res://game/content/skills/"
const KINDS := {"move": Enums.SkillKind.MOVE, "attack": Enums.SkillKind.ATTACK, "reaction": Enums.SkillKind.REACTION,
	"revive": Enums.SkillKind.REVIVE}
const TARGETING := {"none": Enums.Targeting.NONE, "character": Enums.Targeting.CHARACTER, "tile": Enums.Targeting.TILE}


func _initialize() -> void:
	var force := "--force" in OS.get_cmdline_user_args()
	var parsed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SOURCE))
	var set := SkillSet.new()
	for id: String in parsed:
		if id.begins_with("_"):
			continue
		var d: Dictionary = parsed[id]
		var path := OUT + id + ".tres"
		if FileAccess.file_exists(path) and not force:
			print("kept ", path)
			set.skills.append(ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as SkillDef)
			continue
		var s := SkillDef.new()
		s.id = id
		s.display_name = d["name"]
		s.kind = KINDS[d["kind"]]
		s.targeting = TARGETING[d.get("targeting", "none")]
		s.attack_range = d.get("range", 1)
		s.speed = d["speed"]
		s.frequency = Enums.Frequency.UNLIMITED if d.get("frequency", "once_per_turn") == "unlimited" else Enums.Frequency.ONCE_PER_TURN
		s.stability = d.get("stability", 1)
		for st: Dictionary in d["stages"]:
			var stage := SkillStage.new()
			stage.stage_name = st.get("name", "")
			stage.ap = st["ap"]
			stage.damage = st.get("damage", 0)
			stage.interrupt = st.get("interrupt", 0)
			s.stage_defs.append(stage)
		var r: Dictionary = d.get("reaction", {})
		s.reaction_range = r.get("range", 0)
		s.reaction_duration_beats = r.get("duration_beats", 0)
		s.reaction_interrupt = r.get("interrupt", 0)
		ResourceSaver.save(s, path)
		s.take_over_path(path)
		print("wrote ", path)
		set.skills.append(s)
	var set_path := OUT + "skill_set.tres"
	if FileAccess.file_exists(set_path) and not force:
		print("kept ", set_path)
	else:
		ResourceSaver.save(set, set_path)
		print("wrote ", set_path)
	quit()
