class_name Battle
extends RefCounted
## One encounter: planning, Ready/commit, beat-based resolution, victory. Pure gameplay logic —
## no networking, timers or persistence. Time-based concerns (timeouts, pacing) belong to the server app.

var cfg: GameConfig
var skills: SkillDb
var bf: Battlefield
## Which painted map scene the clients should render (game/content/maps/<id>.tscn); empty for test fixtures.
var map_id: String = ""
var state: BattleState = BattleState.new()
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var beat: int = 0
var beats_per_round: int = 8
var sight: int = 8
var outcome: int = Enums.Outcome.NONE
## Tests turn this off to script enemies by hand.
var ai_enabled: bool = true
## Full internal log (never sent as-is to clients).
var events: Array[Dictionary] = []

var _resolver: BeatResolver
var _ai: AiPlanner = AiPlanner.new()
var _seq: int = 0


func _init(p_cfg: GameConfig, p_skills: SkillDb, p_bf: Battlefield, p_seed: int = 1) -> void:
	cfg = p_cfg
	skills = p_skills
	bf = p_bf
	rng.seed = p_seed
	beats_per_round = cfg.get_value("combat", "beats_per_round")
	sight = cfg.get_value("combat", "sight_range")
	_resolver = BeatResolver.new(self)


func add_combatant(c: Combatant) -> void:
	state.add(c)


func start() -> void:
	_begin_planning()


# ---------- Planning ----------

func _begin_planning() -> void:
	state.phase = Enums.RoundPhase.PLANNING
	beat = 0
	for c: Combatant in state.combatants.values():
		c.ap_capacity = cfg.ap_capacity(c.dexterity)
		c.ap_reserved = 0
		c.ap_spent = 0
		c.ap_forfeited = 0
		c.ready = false
		c.plan = []
		c.queue_index = 0
		c.current = null
		c.current_stage = 0
		c.move_index = 0
		c.interrupt_points = 0
		c.skills_used = {}
		c.reaction = {}
	emit("round_start", "Round %d begins. Planning." % state.round_number)
	# AI plans simultaneously with the players, under the same rules; hidden until execution.
	for c: Combatant in state.team_members(Enums.Team.ENEMIES):
		if ai_enabled and c.is_active(state.round_number):
			c.plan = _ai.plan_for(self, c)
			_commit(c)


func submit_plan(cid: String, raw: Variant) -> Dictionary:
	var c := _planner(cid)
	if c == null:
		return _err("You cannot plan right now")
	if c.ready:
		return _err("Plan is locked; withdraw Ready to edit")
	if not raw is Array:
		return _err("Malformed plan")
	var actions: Array[PlannedAction] = []
	for r: Variant in (raw as Array):
		var a := PlannedAction.from_dict(r)
		if a == null:
			return _err("Malformed action")
		actions.append(a)
	var v := PlanValidator.validate(self, c, actions)
	if not v["ok"]:
		return _err(v["error"])
	c.plan = actions
	return {"ok": true, "error": ""}


func set_ready(cid: String, flag: bool) -> Dictionary:
	var c := _planner(cid)
	if c == null:
		return _err("You cannot plan right now")
	if flag:
		if c.ready:
			return {"ok": true, "error": ""}
		var v := PlanValidator.validate(self, c, c.plan)
		if not v["ok"]:
			return _err(v["error"])
		_commit(c)
	else:
		c.ready = false
		c.ap_reserved = 0
		for a in c.plan:
			a.reserved = 0
			a.reserved_left = 0
	return {"ok": true, "error": ""}


func _planner(cid: String) -> Combatant:
	if state.phase != Enums.RoundPhase.PLANNING:
		return null
	var c := state.get_c(cid)
	if c == null or not c.is_active(state.round_number):
		return null
	return c


## Validates and reserves AP for the whole queue. An invalid queue becomes an empty one.
func _commit(c: Combatant) -> void:
	var v := PlanValidator.validate(self, c, c.plan)
	if not v["ok"]:
		c.plan = []
		v = PlanValidator.validate(self, c, c.plan)
	var costs: Array = v["costs"]
	var total := 0
	for i in c.plan.size():
		var cost: int = costs[i]
		c.plan[i].reserved = cost
		c.plan[i].reserved_left = cost
		c.plan[i].spent = 0
		total += cost
	c.ap_reserved = total
	c.ready = true


func all_required_ready() -> bool:
	for c: Combatant in state.team_members(Enums.Team.PLAYERS):
		if c.is_active(state.round_number) and not c.ready:
			return false
	return true


# ---------- Resolution ----------

func begin_resolution() -> void:
	if state.phase != Enums.RoundPhase.PLANNING:
		return
	for c: Combatant in state.team_members(Enums.Team.PLAYERS):
		if c.is_active(state.round_number) and not c.ready:
			_commit(c) # timeout: execute the current valid queue; empty means no action
	state.phase = Enums.RoundPhase.RESOLVING
	beat = 0
	emit("resolution_start", "All plans are committed. Resolving.")


## Resolves one beat; moves on to the next planning phase after the last one.
func resolve_next_beat() -> void:
	if state.phase != Enums.RoundPhase.RESOLVING:
		return
	beat += 1
	_resolver.run_beat()
	outcome = check_victory()
	if outcome != Enums.Outcome.NONE:
		state.phase = Enums.RoundPhase.FINISHED
		var msg := {Enums.Outcome.PLAYERS_WIN: "Victory!", Enums.Outcome.PLAYERS_LOSE: "Defeat.",
			Enums.Outcome.DRAW: "Mutual destruction."}[outcome] as String
		emit("victory", msg)
	elif beat >= beats_per_round:
		_end_round()


func _end_round() -> void:
	for c: Combatant in state.combatants.values():
		_resolver.forfeit_all(c) # unused reservations expire; AP never carries over
	state.round_number += 1
	_begin_planning()


## Encounter objective: elimination (prototype). Simultaneous wipe is a provisional draw.
func check_victory() -> int:
	var players_up := false
	var enemies_up := false
	for c: Combatant in state.combatants.values():
		if c.life_state != Enums.LifeState.ALIVE:
			continue
		if c.team == Enums.Team.PLAYERS:
			players_up = true
		else:
			enemies_up = true
	if not enemies_up and not players_up:
		return Enums.Outcome.DRAW
	if not enemies_up:
		return Enums.Outcome.PLAYERS_WIN
	if not players_up:
		return Enums.Outcome.PLAYERS_LOSE
	return Enums.Outcome.NONE


# ---------- Visibility & events ----------

func team_can_see_combatant(team: int, t: Combatant) -> bool:
	if not t.is_present():
		return false
	if t.team == team:
		return true
	return Visibility.team_sees(state, bf, team, t.cell, sight)


func emit(type: String, template: String, actor_id: String = "", target_id: String = "",
		data: Dictionary = {}, force_seen: bool = false) -> void:
	var hidden: Array[String] = []
	for id in [actor_id, target_id]:
		var c := state.get_c(id as String)
		if c != null and c.team == Enums.Team.ENEMIES and not force_seen \
				and not Visibility.team_sees(state, bf, Enums.Team.PLAYERS, c.cell, sight):
			hidden.append(id as String)
	var a := state.get_c(actor_id)
	var t := state.get_c(target_id)
	var full := template.replace("{a}", a.display_name if a else "").replace("{t}", t.display_name if t else "")
	var pub := template.replace("{a}", "Something unseen" if actor_id in hidden else (a.display_name if a else "")) \
		.replace("{t}", "something unseen" if target_id in hidden else (t.display_name if t else ""))
	_seq += 1
	events.append({"seq": _seq, "round": state.round_number, "beat": beat, "type": type,
		"actor": actor_id, "target": target_id, "text": full, "public_text": pub,
		"hidden": hidden, "data": data})


## Events a player may see: hidden enemies are masked, and events about only-hidden units are dropped.
func public_events_since(seq: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in events:
		if (e["seq"] as int) <= seq:
			continue
		var hidden: Array = e["hidden"]
		var involved: Array[String] = []
		for id: String in [e["actor"], e["target"]]:
			if id != "":
				involved.append(id)
		if not involved.is_empty() and hidden.size() == involved.size():
			continue
		var pe := {"seq": e["seq"], "round": e["round"], "beat": e["beat"], "type": e["type"],
			"text": e["public_text"],
			"actor": "" if e["actor"] in hidden else e["actor"],
			"target": "" if e["target"] in hidden else e["target"]}
		out.append(pe)
	return out


func last_seq() -> int:
	return _seq


func snapshot_for(cid: String) -> Dictionary:
	var me := state.get_c(cid)
	var units: Array[Dictionary] = []
	for c: Combatant in state.combatants.values():
		var own := c.id == cid
		if c.team == Enums.Team.ENEMIES and not team_can_see_combatant(Enums.Team.PLAYERS, c):
			continue
		if c.life_state == Enums.LifeState.ELIMINATED:
			continue
		var u := {"id": c.id, "name": c.display_name, "visual": c.visual, "team": c.team, "cell": c.cell, "facing": c.facing,
			"hp": c.hp, "max_hp": c.max_hp, "life": c.life_state, "ready": c.ready,
			"active": c.is_active(state.round_number), "revived": c.revived_this_encounter}
		if own:
			u["skills"] = c.skills
			u["ap_capacity"] = c.ap_capacity
			u["ap_reserved"] = c.ap_reserved
			u["ap_spent"] = c.ap_spent
			u["ap_forfeited"] = c.ap_forfeited
			u["dexterity"] = c.dexterity
			u["tiles_per_ap"] = cfg.tiles_per_ap(c.dexterity)
			u["reaction"] = not c.reaction.is_empty()
		units.append(u)
	var plan: Array[Dictionary] = []
	if me != null:
		for a in me.plan:
			plan.append(a.to_dict())
	var eliminated := me != null and me.life_state == Enums.LifeState.ELIMINATED
	return {"round": state.round_number, "phase": state.phase, "beat": beat,
		"beats_per_round": beats_per_round, "outcome": outcome, "you": cid, "eliminated": eliminated,
		"map": {"id": map_id, "w": bf.width, "h": bf.height, "terrain": Array(bf.terrain), "elev": Array(bf.elevation)},
		"units": units, "plan": plan}


func _err(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}
