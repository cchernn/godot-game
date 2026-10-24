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
                  "available": state.get(a["id"], "available") == "available", "max_players": a["max_players"], "instance": live.get(a["id"])}
                 for a in d.activities.values() if a["node"] in visible_nodes]
        return {"world": {"id": str(w["id"]), "name": w["name"], "template": f"{w['template_id']}@{w['definition_version']}",
                          "state_revision": w["state_revision"]},
                "location": char["node_id"] if char else None, "nodes": nodes, "routes": routes, "activities": board}

    # ---- activity instances (a "party" is an instance with a leader and a roster) ----

    def _char_for(self, conn, world_id, user_id) -> dict:
        c = conn.execute("select * from characters where world_id=%s and user_id=%s and status='active' for update", (world_id, user_id)).fetchone()
        if c is None:
            raise Forbidden("You need an active character in this world")
        return c

    @staticmethod
    def _live_party_of(conn, character_id) -> dict | None:
        """The forming or active party a character is on, if any. A character is on at most one."""
        return conn.execute("select i.* from activity_instances i join activity_roster r on r.instance_id = i.id "
                            "where r.character_id=%s and i.status in ('forming','active')", (character_id,)).fetchone()

    def _check_presence(self, d: WorldDefinition, char: dict, act: dict) -> None:
        """Physical presence matters only once the overworld exists: the template switches it on."""
        if d.rules.get("require_location", True) and char["node_id"] != act["node"]:
            raise Forbidden("You must be at the activity's location")

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
                self._check_presence(d, char, act)
                if self._live_party_of(conn, char["id"]):
                    raise Conflict("You are already in a party")
                done = conn.execute("select 1 from world_activities where world_id=%s and activity_id=%s and status='completed'",
                                    (world_id, activity_id)).fetchone()
                if done:
                    raise Conflict("This activity is no longer available")
                inst = conn.execute("insert into activity_instances (world_id, activity_id, kind, leader_character_id) values (%s,%s,%s,%s) returning *",
                                    (world_id, activity_id, act["kind"], char["id"])).fetchone()
                conn.execute("insert into activity_roster (instance_id, character_id) values (%s,%s)", (inst["id"], char["id"]))
        except psycopg.errors.UniqueViolation as e:
            raise Conflict("Another major instance is already active in this world") from e
        return _row(inst)

    def _roster_size(self, conn, instance_id) -> int:
        return conn.execute("select count(*) n from activity_roster where instance_id=%s", (instance_id,)).fetchone()["n"]

    def request_party(self, instance_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        """Asks the party's leader to let this player's character in."""
        with self.pool.connection() as conn:
            inst = conn.execute("select * from activity_instances where id=%s for update", (instance_id,)).fetchone()
            if inst is None:
                raise NotFound("Party not found")
            if not self.is_member(inst["world_id"], user_id):
                raise Forbidden("Not a member of this world")
            char = self._char_for(conn, inst["world_id"], user_id)
            if inst["status"] != "forming":
                raise Conflict("This party has already started")
            d = self.definition(inst["world_id"])
            act = d.activities[inst["activity_id"]]
            self._check_presence(d, char, act)
            if conn.execute("select 1 from activity_roster where instance_id=%s and character_id=%s", (instance_id, char["id"])).fetchone():
                raise Conflict("Already in this party")
            if self._live_party_of(conn, char["id"]):
                raise Conflict("You are already in a party")
            if self._roster_size(conn, instance_id) >= act["max_players"]:
                raise Conflict("The party is full")
            try:
                req = conn.execute("insert into instance_join_requests (instance_id, character_id, user_id) values (%s,%s,%s) returning *",
                                   (instance_id, char["id"], user_id)).fetchone()
            except psycopg.errors.UniqueViolation as e:
                raise Conflict("You have already asked to join this party") from e
        return _row(req)

    def cancel_party_request(self, instance_id: uuid.UUID, user_id: uuid.UUID) -> None:
        with self.pool.connection() as conn:
            done = conn.execute("update instance_join_requests set status='cancelled', decided_at=now() "
                                "where instance_id=%s and user_id=%s and status='pending' returning id", (instance_id, user_id)).fetchone()
        if done is None:
            raise NotFound("No pending request")

    def list_party_requests(self, instance_id: uuid.UUID, user_id: uuid.UUID) -> list[dict]:
        with self.pool.connection() as conn:
            inst = self._leader_instance(conn, instance_id, user_id)
            rows = conn.execute("select q.id, q.character_id, q.created_at, c.name, c.class from instance_join_requests q "
                                "join characters c on c.id = q.character_id where q.instance_id=%s and q.status='pending' order by q.created_at",
                                (inst["id"],)).fetchall()
        return [_row(r) for r in rows]

    def decide_party_request(self, instance_id: uuid.UUID, user_id: uuid.UUID, request_id: uuid.UUID, approve: bool) -> dict:
        with self.pool.connection() as conn:
            inst = self._leader_instance(conn, instance_id, user_id)
            req = conn.execute("select * from instance_join_requests where id=%s and instance_id=%s for update", (request_id, instance_id)).fetchone()
            if req is None:
                raise NotFound("Request not found")
            if req["status"] != "pending":
                raise Conflict("Request already decided")
            if approve:
                if inst["status"] != "forming":
                    raise Conflict("The party has already started")
                act = self.definition(inst["world_id"]).activities[inst["activity_id"]]
                if self._roster_size(conn, instance_id) >= act["max_players"]:
                    raise Conflict("The party is full")
                if self._live_party_of(conn, req["character_id"]):
                    raise Conflict("That player has joined another party")
                conn.execute("insert into activity_roster (instance_id, character_id) values (%s,%s)", (instance_id, req["character_id"]))
                # They are in now; any other pending asks of theirs no longer apply.
                conn.execute("update instance_join_requests set status='cancelled', decided_at=now() "
                             "where user_id=%s and status='pending' and id<>%s", (req["user_id"], request_id))
            req = conn.execute("update instance_join_requests set status=%s, decided_at=now() where id=%s returning *",
                               ("approved" if approve else "rejected", request_id)).fetchone()
        return _row(req)

    def leave_instance(self, instance_id: uuid.UUID, user_id: uuid.UUID) -> None:
        """Leaves a forming party. If the leader leaves, the longest-standing member takes over; an empty party is cancelled."""
        with self.pool.connection() as conn:
            inst = conn.execute("select * from activity_instances where id=%s for update", (instance_id,)).fetchone()
            if inst is None:
                raise NotFound("Party not found")
            char = self._char_for(conn, inst["world_id"], user_id)
            if inst["status"] != "forming":
                raise Conflict("Cannot leave after the party has started")
            gone = conn.execute("delete from activity_roster where instance_id=%s and character_id=%s returning character_id",
                                (instance_id, char["id"])).fetchone()
            if gone is None:
                raise NotFound("You are not in this party")
            if inst["leader_character_id"] == char["id"]:
                nxt = conn.execute("select character_id from activity_roster where instance_id=%s order by joined_at limit 1", (instance_id,)).fetchone()
                if nxt is None:
                    conn.execute("update activity_instances set status='cancelled', ended_at=now() where id=%s", (instance_id,))
                    conn.execute("update instance_join_requests set status='cancelled', decided_at=now() where instance_id=%s and status='pending'", (instance_id,))
                else:
                    conn.execute("update activity_instances set leader_character_id=%s where id=%s", (nxt["character_id"], instance_id))

    def _leader_instance(self, conn, instance_id, user_id) -> dict:
        inst = conn.execute("select i.*, c.user_id leader_user from activity_instances i join characters c on c.id = i.leader_character_id "
                            "where i.id=%s for update of i", (instance_id,)).fetchone()
        if inst is None:
            raise NotFound("Party not found")
        if inst["leader_user"] != user_id:  # the server validates every leader decision
            raise Forbidden("Only the party leader can do that")
        return inst

    def lock_and_start_instance(self, instance_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            inst = self._leader_instance(conn, instance_id, user_id)
            if inst["status"] != "forming":
                raise Conflict("Party already started or ended")
            inst = conn.execute("update activity_instances set status='active' where id=%s returning *", (instance_id,)).fetchone()
            conn.execute("update instance_join_requests set status='cancelled', decided_at=now() where instance_id=%s and status='pending'", (instance_id,))
        return _row(inst)

    def cancel_instance(self, instance_id: uuid.UUID, user_id: uuid.UUID | None = None) -> dict:
        """Leader cancels a forming party; the game server (user_id=None) may cancel any live one."""
        with self.pool.connection() as conn:
            if user_id is not None:
                inst = self._leader_instance(conn, instance_id, user_id)
                if inst["status"] != "forming":
                    raise Conflict("Only a forming party can be cancelled by its leader")
            else:
                inst = conn.execute("select * from activity_instances where id=%s for update", (instance_id,)).fetchone()
                if inst is None:
                    raise NotFound("Party not found")
                if inst["status"] == "cancelled":
                    return _row(inst)
                if inst["status"] == "finished":
                    raise Conflict("Party already finished")
            inst = conn.execute("update activity_instances set status='cancelled', ended_at=now() where id=%s returning *", (instance_id,)).fetchone()
            conn.execute("update instance_join_requests set status='cancelled', decided_at=now() where instance_id=%s and status='pending'", (instance_id,))
        return _row(inst)

    def get_instance(self, instance_id: uuid.UUID) -> dict:
        """For the game server: the party's state and roster, plus what its activity says to run."""
        with self.pool.connection() as conn:
            inst = conn.execute("select * from activity_instances where id=%s", (instance_id,)).fetchone()
            if inst is None:
                raise NotFound("Party not found")
            roster = conn.execute("select c.id, c.user_id, c.name, c.class from activity_roster r join characters c on c.id=r.character_id "
                                  "where r.instance_id=%s order by r.joined_at", (instance_id,)).fetchall()
        act = self.definition(inst["world_id"]).activities[inst["activity_id"]]
        return {**_row(inst), "roster": [_row(r) for r in roster], "encounter": act["encounter"],
                "activity_name": act["name"], "max_players": act["max_players"]}

    def party_seat(self, instance_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        """Lets the game server check that this user's character is on an active party's roster."""
        inst = self.get_instance(instance_id)
        if inst["status"] != "active":
            raise Conflict("This party's battle is not running" if inst["status"] == "forming" else "This party's battle has ended")
        if str(user_id) not in {r["user_id"] for r in inst["roster"]}:
            raise Forbidden("You are not on this party's roster")
        return inst

    # ---- party views for players ----

    def _party_rows(self, conn, rows: list[dict], world_id, user_id) -> list[dict]:
        if not rows:
            return []
        d = self.definition(world_id)
        ids = [r["id"] for r in rows]
        roster = conn.execute("select r.instance_id, c.id, c.user_id, c.name, c.class from activity_roster r join characters c on c.id=r.character_id "
                              "where r.instance_id = any(%s) order by r.joined_at", (ids,)).fetchall()
        asked = {r["instance_id"] for r in conn.execute("select instance_id from instance_join_requests where user_id=%s and status='pending'",
                                                         (user_id,)).fetchall()}
        out = []
        for i in rows:
            act = d.activities[i["activity_id"]]
            members = [{"id": _s(m["id"]), "name": m["name"], "class": m["class"]} for m in roster if m["instance_id"] == i["id"]]
            mine = [m for m in roster if m["instance_id"] == i["id"] and m["user_id"] == user_id]
            if mine:
                relation = "leader" if mine[0]["id"] == i["leader_character_id"] else "member"
            else:
                relation = "pending" if i["id"] in asked else "none"
            leader = next((m for m in members if m["id"] == _s(i["leader_character_id"])), None)
            out.append({"id": _s(i["id"]), "activity_id": i["activity_id"], "activity_name": act["name"], "kind": i["kind"],
                        "status": i["status"], "max_players": act["max_players"], "leader": leader, "members": members,
                        "relation": relation, "open": i["status"] == "forming" and len(members) < act["max_players"]})
        return out

    def list_parties(self, world_id: uuid.UUID, user_id: uuid.UUID) -> list[dict]:
        """Every live party in the world, with the caller's relation to each (leader | member | pending | none)."""
        if not self.is_member(world_id, user_id):
            raise Forbidden("Not a member of this world")
        with self.pool.connection() as conn:
            rows = conn.execute("select * from activity_instances where world_id=%s and status in ('forming','active') order by created_at",
                                (world_id,)).fetchall()
            return self._party_rows(conn, rows, world_id, user_id)

    def get_party(self, instance_id: uuid.UUID, user_id: uuid.UUID) -> dict:
        with self.pool.connection() as conn:
            inst = conn.execute("select * from activity_instances where id=%s", (instance_id,)).fetchone()
            if inst is None:
                raise NotFound("Party not found")
            if not self.is_member(inst["world_id"], user_id):
                raise Forbidden("Not a member of this world")
            return self._party_rows(conn, [inst], inst["world_id"], user_id)[0]

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
