"""World foundation: membership, discovery, overview, activity instances and atomic completion.
Static definitions come from templates; everything mutable lives in Postgres."""
import uuid

import psycopg.errors

from .errors import Conflict, Forbidden, Invalid, NotFound
from .templates import TemplateError, WorldDefinition


def _s(v):
    return str(v) if isinstance(v, uuid.UUID) else v


def _row(r):
    return None if r is None else {k: _s(v) for k, v in r.items()}


class WorldMixin:
    # ---- definitions ----

    def definition(self, world_id: uuid.UUID) -> WorldDefinition:
        with self.pool.connection() as conn:
            w = conn.execute("select template_id, definition_version from worlds where id=%s", (world_id,)).fetchone()
        if w is None:
            raise NotFound("World not found")
        try:
            return self.templates.load(w["template_id"], w["definition_version"])
        except TemplateError as e:
            raise Invalid(str(e)) from e

    # ---- membership (host decides; approval grants access, not a character) ----

    def is_host(self, world_id: uuid.UUID, user_id: uuid.UUID) -> bool:
        with self.pool.connection() as conn:
            return conn.execute("select 1 from world_members where world_id=%s and user_id=%s and role='host' and status='active'",
                                (world_id, user_id)).fetchone() is not None

    @staticmethod
    def _standing(member_status: str | None, role: str | None, request_status: str | None) -> tuple[str, bool]:
        """(status, is_host) from a user's membership row and latest join request."""
        if member_status == "active":
            return "member", role == "host"
        if request_status == "pending":
            return "pending", False
        if member_status is not None:  # removed by the host
            return "removed", False
        if request_status == "rejected":
            return "rejected", False
        return "none", False

    def browse_worlds(self, user_id: uuid.UUID, limit: int = 100) -> list[dict]:
        """Every world, with the caller's standing in each, so a player can pick one to enter or ask to join.
        Reveals only a world's name and size, never its members."""
        with self.pool.connection() as conn:
            rows = conn.execute(
                "select w.id, w.name, w.created_at, "
                "  (select count(*) from world_members x where x.world_id = w.id and x.status = 'active') as members, "
                "  m.status as member_status, m.role as member_role, "
                "  (select r.status from world_join_requests r where r.world_id = w.id and r.user_id = %s "
                "     order by r.created_at desc limit 1) as request_status "
                "from worlds w left join world_members m on m.world_id = w.id and m.user_id = %s "
                "order by (m.status = 'active') desc nulls last, w.created_at desc limit %s",
                (user_id, user_id, limit)).fetchall()
        out = []
        for r in rows:
            status, is_host = self._standing(r["member_status"], r["member_role"], r["request_status"])
            out.append({"id": _s(r["id"]), "name": r["name"], "members": r["members"], "status": status, "is_host": is_host})
        return out

    def membership(self, world_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        """What this user may do in a world, for the join screen. Works for non-members, and reveals only
        the world's name. status: member | pending | rejected | removed | none."""
        with self.pool.connection() as conn:
            w = conn.execute("select id, name from worlds where id=%s", (world_id,)).fetchone()
            if w is None:
                raise NotFound("World not found")
            m = conn.execute("select status, role from world_members where world_id=%s and user_id=%s", (world_id, user_id)).fetchone()
            req = conn.execute("select status from world_join_requests where world_id=%s and user_id=%s order by created_at desc limit 1",
                               (world_id, user_id)).fetchone()
        status, is_host = self._standing(m["status"] if m else None, m["role"] if m else None, req["status"] if req else None)
        return {"world": _row(w), "status": status, "is_host": is_host}

    def request_join(self, world_id: uuid.UUID, user_id: uuid.UUID, label: str | None = None) -> dict:
        with self.pool.connection() as conn:
            if conn.execute("select 1 from worlds where id=%s", (world_id,)).fetchone() is None:
                raise NotFound("World not found")
        if self.is_member(world_id, user_id):
            raise Conflict("Already a member")
        try:
            with self.pool.connection() as conn:
                r = conn.execute("insert into world_join_requests (world_id, user_id, requester_label) values (%s,%s,%s) returning *",
                    (world_id, user_id, label)).fetchone()
        except psycopg.errors.UniqueViolation as e:
            raise Conflict("A request is already pending") from e
        return _row(r)

    def list_requests(self, world_id: uuid.UUID, host_id: uuid.UUID) -> list[dict]:
        if not self.is_host(world_id, host_id):
            raise Forbidden("Only the host can see requests")
        with self.pool.connection() as conn:
            rows = conn.execute("select q.*, p.display_name from world_join_requests q left join profiles p on p.user_id = q.user_id "
                                "where q.world_id=%s and q.status='pending' order by q.created_at", (world_id,)).fetchall()
        return [_row(r) for r in rows]

    def decide_request(self, world_id: uuid.UUID, host_id: uuid.UUID, request_id: uuid.UUID, approve: bool) -> dict:
        if not self.is_host(world_id, host_id):
            raise Forbidden("Only the host can decide requests")
        with self.pool.connection() as conn:
            r = conn.execute("select * from world_join_requests where id=%s and world_id=%s for update", (request_id, world_id)).fetchone()
            if r is None:
                raise NotFound("Request not found")
            if r["status"] != "pending":
                raise Conflict("Request already decided")
            if approve:  # reapproval restores the removed member's row, and with it their character
                conn.execute("insert into world_members (world_id, user_id) values (%s,%s) "
                             "on conflict (world_id, user_id) do update set status='active'", (world_id, r["user_id"]))
            r = conn.execute("update world_join_requests set status=%s, decided_at=now(), decided_by=%s where id=%s returning *",
                             ("approved" if approve else "rejected", host_id, request_id)).fetchone()
        return _row(r)

    def remove_member(self, world_id: uuid.UUID, host_id: uuid.UUID, user_id: uuid.UUID) -> None:
        if not self.is_host(world_id, host_id):
            raise Forbidden("Only the host can remove members")
        with self.pool.connection() as conn:
            m = conn.execute("select * from world_members where world_id=%s and user_id=%s and status='active' for update",
                             (world_id, user_id)).fetchone()
            if m is None:
                raise NotFound("Member not found")
            if m["role"] == "host":
                raise Forbidden("The host cannot be removed")
            conn.execute("update world_members set status='removed' where world_id=%s and user_id=%s", (world_id, user_id))
            for c in conn.execute("select id from characters where world_id=%s and user_id=%s and status='active'", (world_id, user_id)).fetchall():
                self._detach(conn, c["id"])  # a removed member leaves their party
                conn.execute("delete from activity_roster where character_id=%s and instance_id in "
                             "(select id from activity_instances where status in ('forming','active'))", (c["id"],))  # and the battle they were in

    def list_members(self, world_id: uuid.UUID, host_id: uuid.UUID) -> list[dict]:
        """Active members for the host's management screen: who they are (their join label, else their character) and their role."""
        if not self.is_host(world_id, host_id):
            raise Forbidden("Only the host can see members")
        with self.pool.connection() as conn:
            rows = conn.execute(
                "select m.user_id, m.role, "
                "  (select c.name from characters c where c.world_id = m.world_id and c.user_id = m.user_id and c.status = 'active') as character_name, "
                "  (select r.requester_label from world_join_requests r where r.world_id = m.world_id and r.user_id = m.user_id "
                "     and r.requester_label is not null order by r.created_at desc limit 1) as label, "
                "  (select p.display_name from profiles p where p.user_id = m.user_id) as display_name "
                "from world_members m where m.world_id = %s and m.status = 'active' order by (m.role = 'host') desc, m.joined_at",
                (world_id,)).fetchall()
        return [_row(r) for r in rows]

    def world_info(self, world_id: uuid.UUID, host_id: uuid.UUID) -> dict:
        if not self.is_host(world_id, host_id):
            raise Forbidden("Only the host can see this")
        with self.pool.connection() as conn:
            return _row(conn.execute(
                "select w.name, w.template_id, w.definition_version, w.created_at, "
                "  (select count(*) from world_members where world_id = w.id and status = 'active') as members, "
                "  (select count(*) from characters where world_id = w.id and status = 'active') as characters, "
                "  (select count(*) from activity_instances where world_id = w.id and status in ('forming','active')) as live_parties, "
                "  (select count(*) from combat_results where world_id = w.id) as battles "
                "from worlds w where w.id = %s", (world_id,)).fetchone())

    def rename_world(self, world_id: uuid.UUID, host_id: uuid.UUID, name: str) -> dict:
        if not self.is_host(world_id, host_id):
            raise Forbidden("Only the host can rename the world")
        with self.pool.connection() as conn:
            return _row(conn.execute("update worlds set name=%s where id=%s returning *", (name, world_id)).fetchone())

    def delete_world(self, world_id: uuid.UUID, host_id: uuid.UUID, confirm_name: str) -> None:
        """Permanent: removes the world with its members, characters, parties, discoveries and combat history."""
        if not self.is_host(world_id, host_id):
            raise Forbidden("Only the host can delete the world")
        with self.pool.connection() as conn:
            w = conn.execute("select name from worlds where id=%s for update", (world_id,)).fetchone()
            if w is None:
                raise NotFound("World not found")
            if confirm_name != w["name"]:
                raise Invalid("Type the world's name exactly to delete it")
            if conn.execute("select 1 from activity_instances where world_id=%s and status in ('forming','active') limit 1",
                            (world_id,)).fetchone():
                raise Conflict("Finish or cancel the live parties first")
            # Tables that point at characters or the world without cascading go first.
            conn.execute("delete from combat_results where world_id=%s", (world_id,))
            conn.execute("delete from activity_instances where world_id=%s", (world_id,))
            conn.execute("delete from party_join_requests where party_id in (select id from parties where world_id=%s)", (world_id,))
            conn.execute("delete from party_members where party_id in (select id from parties where world_id=%s)", (world_id,))
            conn.execute("delete from parties where world_id=%s", (world_id,))
            conn.execute("delete from world_discoveries where world_id=%s", (world_id,))
            conn.execute("delete from characters where world_id=%s", (world_id,))
            conn.execute("delete from worlds where id=%s", (world_id,))

    # ---- discovery ----

    @staticmethod
    def _bump(conn, world_id) -> int:
        """World-state revision: +1 per successful atomic transaction that changes shared world state."""
        return conn.execute("update worlds set state_revision = state_revision + 1 where id=%s returning state_revision", (world_id,)).fetchone()["state_revision"]

    def reveal(self, world_id: uuid.UUID, kind: str, target_id: str, scope: str, character_id: uuid.UUID | None = None) -> dict:
        d = self.definition(world_id)
        if not d.exists(kind, target_id):
            raise Invalid("Unknown location or route")
        with self.pool.connection() as conn:
            if scope == "world":
                new = conn.execute("insert into world_discoveries (world_id, kind, target_id, scope) values (%s,%s,%s,'world') "
                                   "on conflict (world_id, kind, target_id) where scope='world' do nothing returning id",
                                   (world_id, kind, target_id)).fetchone() is not None
                revision = self._bump(conn, world_id) if new else conn.execute("select state_revision from worlds where id=%s", (world_id,)).fetchone()["state_revision"]
            elif scope == "character":
                if character_id is None or conn.execute("select 1 from characters where id=%s and world_id=%s and status='active'",
                                                        (character_id, world_id)).fetchone() is None:
                    raise Invalid("Unknown or inactive character")
                new = conn.execute("insert into world_discoveries (world_id, kind, target_id, scope, character_id) values (%s,%s,%s,'character',%s) "
                                   "on conflict (world_id, kind, target_id, character_id) where scope='character' do nothing returning id",
                                   (world_id, kind, target_id, character_id)).fetchone() is not None
                # character-only change: shared world revision is untouched
                revision = conn.execute("select state_revision from worlds where id=%s", (world_id,)).fetchone()["state_revision"]
            else:
                raise Invalid("Unknown scope")
        return {"new": new, "revision": revision}

    def _visible(self, conn, world_id, character_id) -> set[tuple[str, str]]:
        rows = conn.execute("select kind, target_id from world_discoveries where world_id=%s and (scope='world' or character_id=%s)",
                            (world_id, character_id)).fetchall()
        return {(r["kind"], r["target_id"]) for r in rows}

    def overview(self, world_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        if not self.is_member(world_id, user_id):
            raise Forbidden("Not a member of this world")
        d = self.definition(world_id)
        char = self.active_character(world_id, user_id)
        with self.pool.connection() as conn:
            w = conn.execute("select * from worlds where id=%s", (world_id,)).fetchone()
            vis = self._visible(conn, world_id, char["id"] if char else None)
            state = {r["activity_id"]: r["status"] for r in conn.execute("select * from world_activities where world_id=%s", (world_id,)).fetchall()}
            done = {r["activity_id"] for r in conn.execute("select distinct activity_id from activity_completions where world_id=%s and character_id=%s",
                                                           (world_id, char["id"])).fetchall()} if char else set()
            live = {r["activity_id"]: _row(r) for r in conn.execute(
                "select * from activity_instances where world_id=%s and status in ('forming','active')", (world_id,)).fetchall()}
        nodes = [{"id": n["id"], "name": n["name"], "kind": n["kind"]} for n in d.nodes.values() if ("node", n["id"]) in vis]
        routes = [{k: r[k] for k in ("id", "from", "to", "travel_days")} for r in d.routes.values() if ("route", r["id"]) in vis]
        visible_nodes = {n["id"] for n in nodes}
        board = [{"id": a["id"], "node": a["node"], "name": a["name"], "class": a["class"], "type": a["type"], "audience": a.get("audience"),
                  "available": state.get(a["id"], "available") == "available" and not (a["class"] == "quest" and a["id"] in done),
                  "completed": a["id"] in done, "max_players": a["max_players"], "instance": live.get(a["id"])}
                 for a in d.activities.values() if a["node"] in visible_nodes]
        return {"world": {"id": str(w["id"]), "name": w["name"], "template": f"{w['template_id']}@{w['definition_version']}",
                          "state_revision": w["state_revision"]},
                "location": char["node_id"] if char else None, "nodes": nodes, "routes": routes, "activities": board}

    # ---- activity runs (an instance is one activity being played by a party) ----

    def cancel_instance(self, instance_id: uuid.UUID) -> dict:
        """The game server cancels a run that never got going (or was abandoned); its party is idle again."""
        with self.pool.connection() as conn:
            inst = conn.execute("select * from activity_instances where id=%s for update", (instance_id,)).fetchone()
            if inst is None:
                raise NotFound("Party not found")
            if inst["status"] == "cancelled":
                return _row(inst)
            if inst["status"] == "finished":
                raise Conflict("Run already finished")
            inst = conn.execute("update activity_instances set status='cancelled', ended_at=now() where id=%s returning *", (instance_id,)).fetchone()
        return _row(inst)

    def get_instance(self, instance_id: uuid.UUID) -> dict:
        """For the game server: the party's state and roster, plus what its activity says to run."""
        with self.pool.connection() as conn:
            inst = conn.execute("select * from activity_instances where id=%s", (instance_id,)).fetchone()
            if inst is None:
                raise NotFound("Party not found")
            roster = conn.execute("select c.id, c.user_id, c.name, c.class, c.flags from activity_roster r join characters c on c.id=r.character_id "
                                  "where r.instance_id=%s and (%s::uuid is null or r.character_id in (select character_id from party_members where party_id=%s)) "
                                  "order by r.joined_at", (instance_id, inst["party_id"], inst["party_id"])).fetchall()
            loadouts = self._loadouts(conn, [r["id"] for r in roster])
        act = self.definition(inst["world_id"]).activities[inst["activity_id"]]
        roster = [{**_row(r), "items": loadouts.get(str(r["id"]), [])} for r in roster]
        return {**_row(inst), "roster": roster, "activity_type": act["type"], "encounter": act.get("encounter"), "story": act.get("story"),
                "activity_name": act["name"], "max_players": act["max_players"]}

    def party_seat(self, instance_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        """Lets the game server check that this user's character is on a running activity's roster."""
        inst = self.get_instance(instance_id)
        if inst["status"] != "active":
            raise Conflict("This party's battle has ended")
        if str(user_id) not in {r["user_id"] for r in inst["roster"]}:
            raise Forbidden("You are not on this party's roster")
        return inst

    def complete_instance(self, instance_id: uuid.UUID) -> tuple[dict, bool]:
        """Atomically finishes an active instance and applies its world changes. First completion of a
        one-time activity wins; replays are harmless. Returns (result, duplicate)."""
        with self.pool.connection() as conn:
            inst = conn.execute("select * from activity_instances where id=%s for update", (instance_id,)).fetchone()
            if inst is None:
                raise NotFound("Instance not found")
            wid = inst["world_id"]
            revision = conn.execute("select state_revision from worlds where id=%s", (wid,)).fetchone()["state_revision"]
            if inst["status"] == "finished":
                return {"instance": _row(inst), "world_changed": False, "state_revision": revision}, True
            if inst["status"] != "active":
                raise Conflict("Only an active instance can be completed")
            act = self.definition(wid).activities[inst["activity_id"]]
            changed = False
            if act["class"] == "campaign":
                won = conn.execute("update world_activities set status='completed', completed_by_instance=%s, completed_at=now() "
                                   "where world_id=%s and activity_id=%s and status='available' returning activity_id",
                                   (instance_id, wid, inst["activity_id"])).fetchone()
                if won is None:
                    raise Conflict("This activity was already completed")
                changed = True
            for rv in act.get("rewards", {}).get("reveal", []):
                new = conn.execute("insert into world_discoveries (world_id, kind, target_id, scope) values (%s,%s,%s,'world') "
                                   "on conflict (world_id, kind, target_id) where scope='world' do nothing returning id",
                                   (wid, rv["kind"], rv["id"])).fetchone()
                changed = changed or new is not None
            inst = conn.execute("update activity_instances set status='finished', ended_at=now() where id=%s returning *", (instance_id,)).fetchone()
            if changed:
                revision = self._bump(conn, wid)
        return {"instance": _row(inst), "world_changed": changed, "state_revision": revision}, False
