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

    def request_join(self, world_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            if conn.execute("select 1 from worlds where id=%s", (world_id,)).fetchone() is None:
                raise NotFound("World not found")
        if self.is_member(world_id, user_id):
            raise Conflict("Already a member")
        try:
            with self.pool.connection() as conn:
                r = conn.execute("insert into world_join_requests (world_id, user_id) values (%s,%s) returning *", (world_id, user_id)).fetchone()
        except psycopg.errors.UniqueViolation as e:
            raise Conflict("A request is already pending") from e
        return _row(r)

    def list_requests(self, world_id: uuid.UUID, host_id: uuid.UUID) -> list[dict]:
        if not self.is_host(world_id, host_id):
            raise Forbidden("Only the host can see requests")
        with self.pool.connection() as conn:
            rows = conn.execute("select * from world_join_requests where world_id=%s and status='pending' order by created_at", (world_id,)).fetchall()
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
            live = {r["activity_id"]: _row(r) for r in conn.execute(
                "select * from activity_instances where world_id=%s and status in ('forming','active')", (world_id,)).fetchall()}
        nodes = [{"id": n["id"], "name": n["name"], "kind": n["kind"]} for n in d.nodes.values() if ("node", n["id"]) in vis]
        routes = [{k: r[k] for k in ("id", "from", "to", "travel_days")} for r in d.routes.values() if ("route", r["id"]) in vis]
        visible_nodes = {n["id"] for n in nodes}
        board = [{"id": a["id"], "node": a["node"], "name": a["name"], "kind": a["kind"], "one_time": a.get("one_time", False),
                  "available": state.get(a["id"], "available") == "available", "instance": live.get(a["id"])}
                 for a in d.activities.values() if a["node"] in visible_nodes]
        return {"world": {"id": str(w["id"]), "name": w["name"], "template": f"{w['template_id']}@{w['definition_version']}",
                          "state_revision": w["state_revision"]},
                "location": char["node_id"] if char else None, "nodes": nodes, "routes": routes, "activities": board}

    # ---- activity instances ----

    def _char_for(self, conn, world_id, user_id) -> dict:
        c = conn.execute("select * from characters where world_id=%s and user_id=%s and status='active'", (world_id, user_id)).fetchone()
        if c is None:
            raise Forbidden("You need an active character in this world")
        return c

    def start_instance(self, world_id: uuid.UUID, user_id: uuid.UUID, activity_id: str) -> dict:
        if not self.is_member(world_id, user_id):
            raise Forbidden("Not a member of this world")
        d = self.definition(world_id)
        act = d.activities.get(activity_id)
        if act is None:
            raise NotFound("Unknown activity")
        try:
            with self.pool.connection() as conn:
                char = self._char_for(conn, world_id, user_id)
                if ("node", act["node"]) not in self._visible(conn, world_id, char["id"]):
                    raise Forbidden("You have not discovered this location")
                if char["node_id"] != act["node"]:
                    raise Forbidden("You must be at the activity's location")
                done = conn.execute("select 1 from world_activities where world_id=%s and activity_id=%s and status='completed'",
                                    (world_id, activity_id)).fetchone()
                if done:
                    raise Conflict("This activity is no longer available")
                inst = conn.execute("insert into activity_instances (world_id, activity_id, kind, leader_character_id) values (%s,%s,%s,%s) returning *",
                                    (world_id, activity_id, act["kind"], char["id"])).fetchone()
                conn.execute("insert into activity_roster (instance_id, character_id) values (%s,%s)", (inst["id"], char["id"]))
        except psycopg.errors.UniqueViolation as e:
            name = e.diag.constraint_name or ""
            raise Conflict("Another major instance is already active in this world" if name == "instance_one_live_major"
                           else "This activity already has an active instance") from e
        return _row(inst)

    def join_instance(self, instance_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            inst = conn.execute("select * from activity_instances where id=%s for update", (instance_id,)).fetchone()
            if inst is None:
                raise NotFound("Instance not found")
            if not self.is_member(inst["world_id"], user_id):
                raise Forbidden("Not a member of this world")
            char = self._char_for(conn, inst["world_id"], user_id)
            act = self.definition(inst["world_id"]).activities[inst["activity_id"]]
            if inst["status"] != "forming":
                raise Conflict("The roster is locked")
            if char["node_id"] != act["node"]:
                raise Forbidden("You must be at the activity's location")
            n = conn.execute("select count(*) n from activity_roster where instance_id=%s", (instance_id,)).fetchone()["n"]
            if n >= act.get("max_players", 8):
                raise Conflict("The roster is full")
            try:
                conn.execute("insert into activity_roster (instance_id, character_id) values (%s,%s)", (instance_id, char["id"]))
            except psycopg.errors.UniqueViolation as e:
                raise Conflict("Already on the roster") from e
        return _row(inst)

    def leave_instance(self, instance_id: uuid.UUID, user_id: uuid.UUID) -> None:
        with self.pool.connection() as conn:
            inst = conn.execute("select * from activity_instances where id=%s for update", (instance_id,)).fetchone()
            if inst is None:
                raise NotFound("Instance not found")
            char = self._char_for(conn, inst["world_id"], user_id)
            if inst["status"] != "forming":
                raise Conflict("Cannot leave after the instance has started")
            if inst["leader_character_id"] == char["id"]:
                raise Conflict("The leader must cancel instead of leaving")
            conn.execute("delete from activity_roster where instance_id=%s and character_id=%s", (instance_id, char["id"]))

    def _leader_instance(self, conn, instance_id, user_id) -> dict:
        inst = conn.execute("select i.*, c.user_id leader_user from activity_instances i join characters c on c.id = i.leader_character_id "
                            "where i.id=%s for update of i", (instance_id,)).fetchone()
        if inst is None:
            raise NotFound("Instance not found")
        if inst["leader_user"] != user_id:  # the server validates every leader decision
            raise Forbidden("Only the activity leader can do that")
        return inst

    def lock_and_start_instance(self, instance_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            inst = self._leader_instance(conn, instance_id, user_id)
            if inst["status"] != "forming":
                raise Conflict("Instance already started or ended")
            inst = conn.execute("update activity_instances set status='active' where id=%s returning *", (instance_id,)).fetchone()
        return _row(inst)

    def cancel_instance(self, instance_id: uuid.UUID, user_id: uuid.UUID | None = None) -> dict:
        """Leader cancels a forming instance; the game server (user_id=None) may cancel any live one."""
        with self.pool.connection() as conn:
            if user_id is not None:
                inst = self._leader_instance(conn, instance_id, user_id)
                if inst["status"] != "forming":
                    raise Conflict("Only a forming instance can be cancelled by its leader")
            else:
                inst = conn.execute("select * from activity_instances where id=%s for update", (instance_id,)).fetchone()
                if inst is None:
                    raise NotFound("Instance not found")
                if inst["status"] == "cancelled":
                    return _row(inst)
                if inst["status"] == "finished":
                    raise Conflict("Instance already finished")
            inst = conn.execute("update activity_instances set status='cancelled', ended_at=now() where id=%s returning *", (instance_id,)).fetchone()
        return _row(inst)

    def get_instance(self, instance_id: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            inst = conn.execute("select * from activity_instances where id=%s", (instance_id,)).fetchone()
            if inst is None:
                raise NotFound("Instance not found")
            roster = conn.execute("select c.id, c.user_id, c.name from activity_roster r join characters c on c.id=r.character_id "
                                  "where r.instance_id=%s order by r.joined_at", (instance_id,)).fetchall()
        return {**_row(inst), "roster": [_row(r) for r in roster]}

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
            if act.get("one_time"):
                won = conn.execute("update world_activities set status='completed', completed_by_instance=%s, completed_at=now() "
                                   "where world_id=%s and activity_id=%s and status='available' returning activity_id",
                                   (instance_id, wid, inst["activity_id"])).fetchone()
                if won is None:
                    raise Conflict("This activity was already completed")
                changed = True
            for rv in act.get("on_complete", {}).get("reveal", []):
                new = conn.execute("insert into world_discoveries (world_id, kind, target_id, scope) values (%s,%s,%s,'world') "
                                   "on conflict (world_id, kind, target_id) where scope='world' do nothing returning id",
                                   (wid, rv["kind"], rv["id"])).fetchone()
                changed = changed or new is not None
            inst = conn.execute("update activity_instances set status='finished', ended_at=now() where id=%s returning *", (instance_id,)).fetchone()
            if changed:
                revision = self._bump(conn, wid)
        return {"instance": _row(inst), "world_changed": changed, "state_revision": revision}, False
