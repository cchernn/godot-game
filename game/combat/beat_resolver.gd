class_name BeatResolver
extends RefCounted
## Executes one beat: orders pending steps by skill speed (ties by a server-generated priority fixed
## for the beat), runs one step per combatant, re-validates at execution, and processes
## interruptions and reactions. Reaction effects never begin skills, so reactions cannot chain.

var b: Battle
var _rank: Dictionary = {}


func _init(battle: Battle) -> void:
	b = battle


func run_beat() -> void:
	var st := b.state
	for c: Combatant in st.combatants.values():
		if not c.reaction.is_empty() and b.beat > (c.reaction["expires_beat"] as int):
			c.reaction = {}
	var ids: Array = st.combatants.keys()
	ids.sort()
	for i in range(ids.size() - 1, 0, -1):
		var j := b.rng.randi_range(0, i)
		var tmp: Variant = ids[i]
		ids[i] = ids[j]
		ids[j] = tmp
	_rank.clear()
	for i in ids.size():
		_rank[ids[i]] = i
	var speeds := {}
	var order: Array[Combatant] = []
	for id: String in ids:
		var c := st.get_c(id)
		var sp := _pending_speed(c)
		if c.is_active(st.round_number) and sp >= 0:
			speeds[id] = sp
			order.append(c)
	order.sort_custom(func(x: Combatant, y: Combatant) -> bool:
		if speeds[x.id] != speeds[y.id]:
			return (speeds[x.id] as int) > (speeds[y.id] as int)
		return (_rank[x.id] as int) < (_rank[y.id] as int))
	for c in order:
		if c.is_active(st.round_number): # may have been defeated earlier this beat
			_step(c)


func _pending_speed(c: Combatant) -> int:
	var a: PlannedAction = c.current
	if a == null and c.queue_index < c.plan.size():
		a = c.plan[c.queue_index]
	if a == null:
		return -1
	var sk := b.skills.get_skill(a.skill_id)
	return sk.speed if sk != null else -1


func _step(c: Combatant) -> void:
	if c.current == null:
		while c.queue_index < c.plan.size():
			var a := c.plan[c.queue_index]
			c.queue_index += 1
			var sk := b.skills.get_skill(a.skill_id)
			var reason := _can_begin(c, a, sk)
			if reason == "":
				c.current = a
				c.current_stage = 0
				c.move_index = 0
				c.interrupt_points = 0
				# Usage is consumed when the skill begins executing. Reaction preparation does not consume it.
				if sk.frequency == Enums.Frequency.ONCE_PER_TURN and sk.kind != Enums.SkillKind.REACTION:
					c.skills_used[sk.id] = true
				break
			b.emit("skip", "{a}'s %s is skipped (%s)." % [sk.display_name, reason], c.id)
			forfeit(c, a)
		if c.current == null:
			return
	_run_stage(c)


func _can_begin(c: Combatant, a: PlannedAction, sk: SkillDef) -> String:
	if sk == null or not c.skills.has(a.skill_id):
		return "unknown skill"
	if sk.frequency == Enums.Frequency.ONCE_PER_TURN and c.skills_used.has(sk.id):
		return "already used this round"
	if sk.kind == Enums.SkillKind.MOVE:
		if a.path.is_empty() or not b.bf.can_step(c.cell, a.path[0], b.cfg.get_value("combat", "max_step_height")):
			return "path no longer valid"
		if b.state.at_cell(a.path[0]) != null:
			return "path blocked"
		var first := 1 + (b.cfg.get_value("movement", "difficult_terrain_surcharge") as int if b.bf.is_difficult(a.path[0]) else 0)
		if a.reserved_left < first:
			return "not enough AP"
		return ""
	return _stage_problem(c, a, sk, 0)


## "" if the stage can execute right now.
func _stage_problem(c: Combatant, a: PlannedAction, sk: SkillDef, stage_index: int) -> String:
	if a.reserved_left < (sk.stages[stage_index]["ap"] as int):
		return "not enough AP"
	match sk.kind:
		Enums.SkillKind.ATTACK, Enums.SkillKind.REVIVE, Enums.SkillKind.SUPPORT:
			if sk.targeting == Enums.Targeting.SELF:
				return ""
			var from := c.cell
			var to: Vector2i
			if sk.targeting == Enums.Targeting.CHARACTER:
				var t := b.state.get_c(a.target_id)
				if t == null or not t.is_present():
					return "target gone"
				if sk.kind == Enums.SkillKind.REVIVE:
					if t.life_state != Enums.LifeState.DOWNED or t.revived_this_encounter:
						return "target cannot be revived"
				elif not b.team_can_see_combatant(c.team, t):
					return "target out of sight"
				to = t.cell
			else:
				to = a.target_cell
			if Enums.manhattan(from, to) > sk.attack_range:
				return "out of range"
			if not b.bf.has_los(from, to):
				return "no line of sight"
	return ""


func _run_stage(c: Combatant) -> void:
	var a := c.current
	var sk := b.skills.get_skill(a.skill_id)
	if sk.kind == Enums.SkillKind.MOVE:
		_move_step(c, a)
		return
	if c.current_stage > 0:
		var problem := _stage_problem(c, a, sk, c.current_stage)
		if problem != "":
			b.emit("cancel", "{a}'s %s is cancelled (%s)." % [sk.display_name, problem], c.id)
			forfeit(c, a)
			c.current = null
			return
	var stage: Dictionary = sk.stages[c.current_stage]
	_spend(c, a, stage["ap"] as int)
	match sk.kind:
		Enums.SkillKind.ATTACK, Enums.SkillKind.SUPPORT:
			_run_effects(c, a, sk, stage)
		Enums.SkillKind.REVIVE:
			_revive(c, a)
		Enums.SkillKind.REACTION:
			c.reaction = {"skill": sk.id, "expires_beat": b.beat + (sk.reaction["duration_beats"] as int)}
			b.emit("reaction_ready", "{a} prepares %s." % sk.display_name, c.id)
	if c.current == null: # e.g. the actor was defeated by its own side effects
		return
	var began := c.current_stage == 0
	c.current_stage += 1
	if began and sk.kind == Enums.SkillKind.ATTACK and sk.is_multistage():
		_check_reactions(c)
	if c.current != null and c.current_stage >= sk.stages.size():
		forfeit(c, a)
		c.current = null


func _move_step(c: Combatant, a: PlannedAction) -> void:
	var tpa := b.cfg.tiles_per_ap(c.dexterity)
	var sur: int = b.cfg.get_value("movement", "difficult_terrain_surcharge")
	var max_step: int = b.cfg.get_value("combat", "max_step_height")
	var moved := 0
	while moved < tpa and c.move_index < a.path.size():
		var nxt := a.path[c.move_index]
		var cost := (1 if moved == 0 else 0) + (sur if b.bf.is_difficult(nxt) else 0)
		var why := ""
		if not b.bf.can_step(c.cell, nxt, max_step):
			why = "terrain"
		elif b.state.at_cell(nxt) != null:
			why = "the way is blocked"
		elif cost > a.reserved_left:
			why = "out of AP"
		if why != "":
			b.emit("move_stop", "{a} stops (%s)." % why, c.id)
			forfeit(c, a)
			c.current = null
			return
		_spend(c, a, cost)
		var old := c.cell
		c.cell = nxt
		c.move_index += 1
		moved += 1
		var seen := Visibility.team_sees(b.state, b.bf, Enums.Team.PLAYERS, old, b.sight)
		b.emit("move", "{a} moves.", c.id, "", {"from": old, "to": nxt}, seen)
	if c.move_index >= a.path.size():
		if a.facing >= 0:
			c.facing = a.facing
		forfeit(c, a)
		c.current = null


## Runs a stage's effects, in order, on whoever it is aimed at (and `on = CASTER` effects on the caster). Anyone can be the
## target, friend or foe, and the caster too. A stage with no effects is only a preparation step.
func _run_effects(c: Combatant, a: PlannedAction, sk: SkillDef, stage: Dictionary) -> void:
	var victim: Combatant = null
	var aim := c.cell
	match sk.targeting:
		Enums.Targeting.CHARACTER:
			victim = b.state.get_c(a.target_id)
			aim = victim.cell
		Enums.Targeting.TILE:
			aim = a.target_cell
			victim = b.state.at_cell(a.target_cell)
		Enums.Targeting.SELF:
			victim = c
	if aim != c.cell:
		c.facing = Enums.facing_from_delta(aim - c.cell)
	var effects: Array = stage.get("effects", [])
	if effects.is_empty():
		b.emit("windup", "{a} begins %s%s." % [sk.display_name, " on {t}" if victim else ""],
			c.id, victim.id if victim else "")
		return
	var landed := true
	var aimed_at_someone := false
	for e: Dictionary in effects:
		var on_caster := (e["on"] as int) == SkillEffect.On.CASTER
		var who: Combatant = c if on_caster else victim
		if who == null:
			continue
		aimed_at_someone = aimed_at_someone or not on_caster
		match e["type"] as String:
			"damage":
				landed = _damage(c, sk, e, who)
			"heal":
				_heal(c, sk, e, who)
			"shield":
				_shield(c, sk, e, who)
			"interrupt":
				if landed and who.life_state == Enums.LifeState.ALIVE:
					_add_interrupt(who, e["points"] as int)
	if victim == null and sk.targeting == Enums.Targeting.TILE:
		var hurts := effects.any(func(e: Dictionary) -> bool: return e["type"] == "damage")
		b.emit("miss", "{a}'s %s %s." % [sk.display_name, "strikes empty ground" if hurts else "finds no one there"], c.id)


## Returns true when the damage connected (a miss returns false, so a following interrupt effect does not land).
func _damage(c: Combatant, sk: SkillDef, e: Dictionary, victim: Combatant) -> bool:
	if victim.life_state == Enums.LifeState.DOWNED:
		b.emit("hit", "{a}'s %s finishes {t}." % sk.display_name, c.id, victim.id)
		_defeat(victim)
		return true
	if not victim.is_present() or victim.life_state != Enums.LifeState.ALIVE:
		return false
	if e["can_miss"] as bool:
		var per: float = b.cfg.get_value("combat", "accuracy_per_point")
		var chance := clampf((b.cfg.get_value("combat", "base_hit_chance") as float) + (c.accuracy - victim.evasion) * per, 0.05, 1.0)
		if b.rng.randf() >= chance:
			b.emit("miss", "{a}'s %s misses {t}." % sk.display_name, c.id, victim.id)
			return false
	var mult := 1.0
	var note := ""
	if e["can_crit"] as bool:
		if victim != c:
			var rel := _relative_facing(c, victim)
			if rel == 2:
				mult *= b.cfg.get_value("combat", "rear_multiplier") as float
				note = " (rear attack)"
			elif rel == 1:
				mult *= b.cfg.get_value("combat", "side_multiplier") as float
				note = " (flanking)"
		if b.rng.randf() < (b.cfg.get_value("combat", "crit_chance") as float):
			mult *= b.cfg.get_value("combat", "crit_multiplier") as float
			note += " CRITICAL"
	var raw: int = e["base"] as int
	if e["uses_power"] as bool:
		raw += c.power
	var dmg := maxi(1, roundi(raw * mult) - victim.armor)
	var absorbed := mini(victim.shield, dmg)
	victim.shield -= absorbed
	victim.hp = maxi(0, victim.hp - (dmg - absorbed))
	if absorbed > 0:
		note += " (%d absorbed by the shield)" % absorbed
	b.emit("hit", "{a}'s %s hits {t} for %d%s." % [sk.display_name, dmg, note], c.id, victim.id, {"amount": dmg, "absorbed": absorbed})
	if victim.hp == 0:
		_defeat(victim)
		return false # nothing left to interrupt
	return true


func _heal(c: Combatant, sk: SkillDef, e: Dictionary, victim: Combatant) -> void:
	if victim.life_state != Enums.LifeState.ALIVE:
		b.emit("no_effect", "{a}'s %s has no effect on {t}." % sk.display_name, c.id, victim.id)
		return
	var gained := mini(e["amount"] as int, victim.max_hp - victim.hp)
	victim.hp += gained
	b.emit("heal", "{a}'s %s heals {t} for %d." % [sk.display_name, gained], c.id, victim.id, {"amount": gained})


func _shield(c: Combatant, sk: SkillDef, e: Dictionary, victim: Combatant) -> void:
	if victim.life_state != Enums.LifeState.ALIVE:
		b.emit("no_effect", "{a}'s %s has no effect on {t}." % sk.display_name, c.id, victim.id)
		return
	victim.shield = maxi(victim.shield, e["amount"] as int) # does not stack: only a higher shield replaces it
	b.emit("shield", "{a}'s %s shields {t} (%d)." % [sk.display_name, victim.shield], c.id, victim.id, {"amount": victim.shield})


## 0 = front, 1 = side, 2 = rear.
func _relative_facing(attacker: Combatant, target: Combatant) -> int:
	var dir := Enums.facing_from_delta(attacker.cell - target.cell)
	if dir == target.facing:
		return 0
	if dir == (target.facing + 2) % 4:
		return 2
	return 1


func _revive(c: Combatant, a: PlannedAction) -> void:
	var t := b.state.get_c(a.target_id)
	t.hp = maxi(1, int(t.max_hp * (b.cfg.get_value("combat", "revive_hp_fraction") as float)))
	t.life_state = Enums.LifeState.ALIVE
	t.revived_this_encounter = true
	t.inactive_until_round = b.state.round_number + 1
	b.emit("revived", "{a} revives {t}.", c.id, t.id)


func _defeat(v: Combatant) -> void:
	clear_queue(v)
	v.shield = 0
	if v.team == Enums.Team.ENEMIES or v.life_state == Enums.LifeState.DOWNED or v.revived_this_encounter:
		v.life_state = Enums.LifeState.ELIMINATED
		v.hp = 0
		b.emit("eliminated", "{t} is eliminated!", "", v.id)
	else:
		v.life_state = Enums.LifeState.DOWNED
		b.emit("downed", "{t} is downed!", "", v.id)


## A defeated character loses the current skill and the whole remaining queue.
func clear_queue(v: Combatant) -> void:
	forfeit_all(v)
	v.queue_index = v.plan.size()
	v.current = null


func _add_interrupt(v: Combatant, pts: int) -> void:
	if pts <= 0 or v.current == null:
		return
	v.interrupt_points += pts
	var sk := b.skills.get_skill(v.current.skill_id)
	if v.interrupt_points >= sk.stability:
		b.emit("interrupt", "{t}'s %s is interrupted!" % sk.display_name, "", v.id)
		forfeit(v, v.current)
		v.current = null # completed effects remain; the rest of this skill is cancelled


func _check_reactions(actor: Combatant) -> void:
	var reactors: Array[Combatant] = []
	for r: Combatant in b.state.combatants.values():
		if r.team != actor.team and r.is_active(b.state.round_number) and not r.reaction.is_empty():
			reactors.append(r)
	reactors.sort_custom(func(x: Combatant, y: Combatant) -> bool: return (_rank[x.id] as int) < (_rank[y.id] as int))
	for r in reactors:
		if actor.current == null:
			return
		var sk := b.skills.get_skill(r.reaction["skill"] as String)
		var rng_: int = sk.reaction["range"]
		if Enums.manhattan(r.cell, actor.cell) > rng_ or not b.bf.has_los(r.cell, actor.cell) \
				or not b.team_can_see_combatant(r.team, actor):
			continue
		r.skills_used[sk.id] = true # consumed when the reaction executes
		r.reaction = {}
		b.emit("reaction", "{a}'s %s triggers against {t}!" % sk.display_name, r.id, actor.id)
		_add_interrupt(actor, sk.reaction["interrupt"] as int)


func _spend(c: Combatant, a: PlannedAction, n: int) -> void:
	a.reserved_left -= n
	a.spent += n
	c.ap_reserved -= n
	c.ap_spent += n


## Unused reservation is forfeited for the round; it is never reassigned to later actions.
func forfeit(c: Combatant, a: PlannedAction) -> void:
	c.ap_reserved -= a.reserved_left
	c.ap_forfeited += a.reserved_left
	a.reserved_left = 0


func forfeit_all(c: Combatant) -> void:
	for a in c.plan:
		forfeit(c, a)
