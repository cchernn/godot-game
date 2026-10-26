import json
import shutil
import uuid
from concurrent.futures import ThreadPoolExecutor

from fastapi.testclient import TestClient

from app.main import create_app
from app.templates import DEFAULT_DIR, TemplateError, parse
from conftest import SERVER, auth, make_settings, token_for
import pytest


def new_user():
    return token_for()


def make_world(client, name="W", host=None):
    tok, uid = host or new_user()
    w = client.post("/worlds", json={"name": name}, headers=auth(tok)).json()
    return w, tok, uid


def join(client, world_id, host_tok):
    """A new player requests access and the host approves."""
    tok, uid = new_user()
    req = client.post(f"/worlds/{world_id}/requests", headers=auth(tok))
    assert req.status_code == 201, req.text
    ok = client.post(f"/worlds/{world_id}/requests/{req.json()['id']}/approve", headers=auth(host_tok))
    assert ok.status_code == 200, ok.text
    return tok, uid


def char(client, world_id, tok, name="Hero", cls="warrior"):
    r = client.post(f"/worlds/{world_id}/characters", json={"name": name, "class": cls}, headers=auth(tok))
    assert r.status_code == 201, r.text
    return r.json()


def overview(client, world_id, tok):
    return client.get(f"/worlds/{world_id}/overview", headers=auth(tok)).json()


def set_node(pool, character_id, node):
    with pool.connection() as c:
        c.execute("update characters set node_id=%s where id=%s", (node, character_id))


# ---------- templates ----------

def test_world_initializes_once_from_pinned_template_version(client):
    w, tok, _ = make_world(client)
    assert (w["template_id"], w["definition_version"], w["state_revision"]) == ("prototype", 1, 0)
    char(client, w["id"], tok)
    ov = overview(client, w["id"], tok)
    assert {n["id"] for n in ov["nodes"]} == {"hollowmere", "blackwood"}, "only initially visible locations"
    assert ov["location"] == "hollowmere"


def test_template_edits_never_reset_existing_worlds(pool, tmp_path):
    shutil.copy(DEFAULT_DIR / "prototype@1.json", tmp_path / "prototype@1.json")
    c = TestClient(create_app(make_settings(templates_dir=str(tmp_path)), pool))
    w1, tok, _ = make_world(c, "old")
    char(c, w1["id"], tok)
    v2 = json.loads((tmp_path / "prototype@1.json").read_text())
    v2["version"] = 2
    v2["nodes"].append({"id": "extra", "name": "Extra", "kind": "landmark", "initially_visible": True})
    (tmp_path / "prototype@2.json").write_text(json.dumps(v2))
    w2, tok2, _ = make_world(c, "new")
    assert w2["definition_version"] == 2 and w1["definition_version"] == 1
    char(c, w2["id"], tok2)
    assert "extra" not in {n["id"] for n in overview(c, w1["id"], tok)["nodes"]}
    assert "extra" in {n["id"] for n in overview(c, w2["id"], tok2)["nodes"]}


def act(d, activity_id):
    return next(a for a in d["activities"] if a["id"] == activity_id)


def test_invalid_templates_are_rejected():
    base = json.loads((DEFAULT_DIR / "prototype@1.json").read_text())
    for mutate in (lambda d: d["routes"][0].update({"to": "nowhere"}),
                   lambda d: d.update({"start_node": "nowhere"}),
                   lambda d: d["nodes"].append(dict(d["nodes"][0])),
                   lambda d: act(d, "cellar_rats").update({"one_time": True}),  # minor + one_time
                   lambda d: act(d, "cellar_rats").pop("encounter"),
                   lambda d: act(d, "cellar_rats").update({"encounter": "../etc"}),
                   lambda d: act(d, "cellar_rats").update({"max_players": 0}),
                   lambda d: act(d, "ashen_keep_siege")["on_complete"]["reveal"].append({"kind": "node", "id": "ghost"})):
        d = json.loads(json.dumps(base))
        mutate(d)
        with pytest.raises(TemplateError):
            parse(d)
    assert parse(base).start_node == "hollowmere"


def test_multiple_routes_between_the_same_nodes_are_allowed():
    d = parse(json.loads((DEFAULT_DIR / "prototype@1.json").read_text()))
    pairs = [(r["from"], r["to"]) for r in d.routes.values()]
    assert pairs.count(("hollowmere", "blackwood")) == 2


# ---------- membership ----------

def test_join_request_approval_flow_and_host_limits(client):
    w, host, host_uid = make_world(client)
    tok, uid = new_user()
    assert client.post(f"/worlds/{w['id']}/requests", headers=auth(tok)).status_code == 201
    assert client.post(f"/worlds/{w['id']}/requests", headers=auth(tok)).status_code == 409, "one pending request"
    assert client.get(f"/worlds/{w['id']}/requests", headers=auth(tok)).status_code == 403, "only the host sees requests"
    reqs = client.get(f"/worlds/{w['id']}/requests", headers=auth(host)).json()
    assert [r["user_id"] for r in reqs] == [uid]
    assert client.post(f"/worlds/{w['id']}/requests/{reqs[0]['id']}/approve", headers=auth(tok)).status_code == 403
    assert overview(client, w["id"], tok).get("detail"), "not a member yet"
    assert client.post(f"/worlds/{w['id']}/requests/{reqs[0]['id']}/approve", headers=auth(host)).status_code == 200
    assert client.get(f"/worlds/{w['id']}/characters/me", headers=auth(tok)).status_code == 404, "approval does not create a character"
    assert client.post(f"/worlds/{w['id']}/requests/{reqs[0]['id']}/approve", headers=auth(host)).status_code == 409


def test_rejected_request_grants_nothing(client):
    w, host, _ = make_world(client)
    tok, _ = new_user()
    rid = client.post(f"/worlds/{w['id']}/requests", headers=auth(tok)).json()["id"]
    assert client.post(f"/worlds/{w['id']}/requests/{rid}/reject", headers=auth(host)).json()["status"] == "rejected"
    assert make_char_status(client, w["id"], tok) == 403


def make_char_status(client, world_id, tok):
    return client.post(f"/worlds/{world_id}/characters", json={"name": "x", "class": "warrior"}, headers=auth(tok)).status_code


def test_removal_revokes_access_but_keeps_data_and_reapproval_restores_it(client):
    w, host, _ = make_world(client)
    tok, uid = join(client, w["id"], host)
    c = char(client, w["id"], tok)
    assert client.post(f"/worlds/{w['id']}/members/{uid}/remove", headers=auth(tok)).status_code == 403
    assert client.post(f"/worlds/{w['id']}/members/{uid}/remove", headers=auth(host)).status_code == 204
    assert client.get(f"/worlds/{w['id']}/characters/me", headers=auth(tok)).status_code == 403
    assert client.post("/internal/auth/session", json={"token": tok, "world_id": w["id"]}, headers=SERVER).status_code == 403
    assert w["id"] not in [x["id"] for x in client.get("/worlds", headers=auth(tok)).json()]
    rid = client.post(f"/worlds/{w['id']}/requests", headers=auth(tok)).json()["id"]
    client.post(f"/worlds/{w['id']}/requests/{rid}/approve", headers=auth(host))
    assert client.get(f"/worlds/{w['id']}/characters/me", headers=auth(tok)).json()["id"] == c["id"], "same character restored"


def test_host_cannot_be_removed(client):
    w, host, host_uid = make_world(client)
    assert client.post(f"/worlds/{w['id']}/members/{host_uid}/remove", headers=auth(host)).status_code == 403


# ---------- discovery & revision ----------

def reveal(client, wid, kind, target, scope, cid=None):
    body = {"kind": kind, "target_id": target, "scope": scope}
    if cid:
        body["character_id"] = cid
    return client.post(f"/internal/worlds/{wid}/reveal", json=body, headers=SERVER)


def test_discovery_scopes_and_revision_rules(client):
    w, host, _ = make_world(client)
    other, _ = join(client, w["id"], host)
    a, b = char(client, w["id"], host, "A"), char(client, w["id"], other, "B", "rogue")
    r = reveal(client, w["id"], "node", "ashen_keep", "character", a["id"]).json()
    assert r["new"] and r["revision"] == 0, "character-only discovery does not advance the world revision"
    assert "ashen_keep" in {n["id"] for n in overview(client, w["id"], host)["nodes"]}
    assert "ashen_keep" not in {n["id"] for n in overview(client, w["id"], other)["nodes"]}
    r = reveal(client, w["id"], "node", "ashen_keep", "world").json()
    assert r["new"] and r["revision"] == 1
    assert "ashen_keep" in {n["id"] for n in overview(client, w["id"], other)["nodes"]}, "world reveal reaches everyone"
    again = reveal(client, w["id"], "node", "ashen_keep", "world").json()
    assert not again["new"] and again["revision"] == 1, "no-op reveal does not advance the revision"
    assert reveal(client, w["id"], "node", "atlantis", "world").status_code == 422
    assert reveal(client, w["id"], "node", "old_shrine", "character", str(uuid.uuid4())).status_code == 422


# ---------- parties, travel and activities ----------

def party(client, pool, n=2):
    w, host, _ = make_world(client)
    toks = [host] + [join(client, w["id"], host)[0] for _ in range(n - 1)]
    chars = [char(client, w["id"], t, f"C{i}") for i, t in enumerate(toks)]
    return w, toks, chars


def my_party(client, wid, tok):
    r = client.get(f"/worlds/{wid}/parties/me", headers=auth(tok))
    assert r.status_code == 200, r.text
    return r.json()


def new_party(client, wid, tok, activity="cellar_rats"):
    """Starts an activity from the player's own party and returns the run's id (it is active at once)."""
    pid = my_party(client, wid, tok)["id"]
    r = client.post(f"/parties/{pid}/start", json={"activity_id": activity}, headers=auth(tok))
    assert r.status_code == 201, r.text
    return r.json()["id"]


def join_party(client, pid, leader_tok, tok):
    """The player asks, the leader approves."""
    req = client.post(f"/parties/{pid}/requests", headers=auth(tok))
    assert req.status_code == 201, req.text
    ok = client.post(f"/parties/{pid}/requests/{req.json()['id']}/approve", headers=auth(leader_tok))
    assert ok.status_code == 200, ok.text


def start(client, pid, tok, activity="cellar_rats"):
    return client.post(f"/parties/{pid}/start", json={"activity_id": activity}, headers=auth(tok))


def test_every_character_starts_in_a_party_of_one_at_the_start_node(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    p = my_party(client, w["id"], t1)
    assert (p["node_id"], p["relation"], p["leader"]["name"], [m["name"] for m in p["members"]]) == ("hollowmere", "leader", "C0", ["C0"])
    assert p["instance"] is None and p["open"] and p["here"]
    assert my_party(client, w["id"], t1)["id"] == p["id"], "asking again does not make another"
    assert my_party(client, w["id"], t2)["id"] != p["id"]


def test_legacy_characters_get_a_party_when_first_asked(client, pool):
    w, host, _ = make_world(client)
    c = char(client, w["id"], host)
    with pool.connection() as conn:  # a character from before parties existed
        conn.execute("delete from party_members where character_id=%s", (c["id"],))
        conn.execute("update characters set node_id=null where id=%s", (c["id"],))
    p = my_party(client, w["id"], host)
    assert p["node_id"] == "hollowmere" and [m["name"] for m in p["members"]] == ["Hero"]
    with pool.connection() as conn:
        conn.execute("delete from party_members where character_id=%s", (c["id"],))
    listed = client.get(f"/worlds/{w['id']}/parties", headers=auth(host)).json()
    assert [(x["relation"], x["node_id"]) for x in listed if x["relation"] == "leader"] == [("leader", "hollowmere")], "listing makes the caller's party"


def test_starting_needs_discovery_leadership_and_the_right_place(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    p1, p2 = my_party(client, w["id"], t1)["id"], my_party(client, w["id"], t2)["id"]
    assert start(client, p1, t1, "ashen_keep_siege").status_code == 403, "location not discovered"
    reveal(client, w["id"], "node", "ashen_keep", "world")
    assert start(client, p1, t1, "ashen_keep_siege").status_code == 403, "the party is not at the keep"
    assert start(client, p1, t1, "wolf_hunt").status_code == 403, "wolf_hunt is in the Blackwood"
    assert start(client, p1, t2).status_code == 403, "only the leader starts"
    assert start(client, p1, t1, "no_such_thing").status_code == 404
    outsider, _ = new_user()
    assert start(client, p1, outsider).status_code == 403
    assert start(client, p1, t1).status_code == 201
    assert start(client, p1, t1).status_code == 409, "already playing"
    assert start(client, p2, t2, "training_skirmish").status_code == 201, "another party may play at once"


def test_the_leader_travels_the_party_along_discovered_routes(client, pool):
    w, [t1, t2, t3], [c1, c2, c3] = party(client, pool, 3)
    p1 = my_party(client, w["id"], t1)["id"]
    join_party(client, p1, t1, t2)
    travel = lambda tok, node, pid=p1: client.post(f"/parties/{pid}/travel", json={"node_id": node}, headers=auth(tok))
    assert travel(t2, "blackwood").status_code == 403, "only the leader travels"
    assert travel(t1, "hollowmere").status_code == 409, "already there"
    assert travel(t1, "atlantis").status_code == 422
    assert travel(t1, "ashen_keep").status_code == 403, "not discovered"
    reveal(client, w["id"], "node", "ashen_keep", "world")
    assert travel(t1, "ashen_keep").status_code == 409, "no route from here"
    moved = travel(t1, "blackwood")
    assert moved.status_code == 200 and moved.json()["node_id"] == "blackwood"
    assert overview(client, w["id"], t1)["location"] == "blackwood" and overview(client, w["id"], t2)["location"] == "blackwood"
    assert overview(client, w["id"], t3)["location"] == "hollowmere", "other parties stay put"
    assert my_party(client, w["id"], t2)["here"] is True and client.get(f"/parties/{p1}", headers=auth(t3)).json()["here"] is False
    assert start(client, p1, t1, "wolf_hunt").status_code == 201, "now the party is where the hunt is"
    assert travel(t1, "hollowmere").status_code == 409, "not in the middle of an activity"


def test_joining_needs_the_same_place_and_a_lone_character(client, pool):
    w, [t1, t2, t3], [c1, c2, c3] = party(client, pool, 3)
    p1 = my_party(client, w["id"], t1)["id"]
    client.post(f"/parties/{p1}/travel", json={"node_id": "blackwood"}, headers=auth(t1))
    assert client.post(f"/parties/{p1}/requests", headers=auth(t2)).status_code == 403, "must be there to ask"
    client.post(f"/parties/{my_party(client, w['id'], t2)['id']}/travel", json={"node_id": "blackwood"}, headers=auth(t2))
    join_party(client, p1, t1, t2)
    p3 = my_party(client, w["id"], t3)["id"]
    assert client.post(f"/parties/{p3}/requests", headers=auth(t1)).status_code == 409, "leave your party first"
    assert client.post(f"/parties/{p1}/requests", headers=auth(t1)).status_code == 409, "already in this party"


def test_concurrent_major_instances_are_prevented_atomically_but_minor_parties_run_side_by_side(client, pool):
    w, toks, chars = party(client, pool, 3)
    reveal(client, w["id"], "node", "ashen_keep", "world")
    for t, c in zip(toks, chars):
        set_node(pool, c["id"], "ashen_keep")
        with pool.connection() as conn:
            conn.execute("update parties set node_id='ashen_keep' where id=%s", (my_party(client, w["id"], t)["id"],))
    pids = [my_party(client, w["id"], t)["id"] for t in toks]
    with ThreadPoolExecutor(3) as ex:
        results = list(ex.map(lambda pt: (pt[0], start(client, pt[1], pt[0], "ashen_keep_siege").status_code), zip(toks, pids)))
    assert sorted(code for _, code in results) == [201, 409, 409], "exactly one major reservation wins"
    a, b = (my_party(client, w["id"], t)["id"] for t in toks[:2])
    assert a != b, "parties are separate"


def test_a_party_in_an_activity_is_held_in_place(client, pool):
    w, [t1, t2], _ = party(client, pool)
    p1 = my_party(client, w["id"], t1)["id"]
    new_party(client, w["id"], t1)
    assert my_party(client, w["id"], t1)["instance"]["activity_name"] == "Clear the cellar"
    assert client.post(f"/parties/{p1}/requests", headers=auth(t2)).status_code == 409, "cannot join mid-activity"
    assert start(client, p1, t1, "training_skirmish").status_code == 409


def test_party_requests_are_decided_by_the_leader(client, pool):
    w, [t1, t2, t3], [c1, c2, c3] = party(client, pool, 3)
    pid = my_party(client, w["id"], t1)["id"]
    req = client.post(f"/parties/{pid}/requests", headers=auth(t2))
    assert req.status_code == 201
    assert client.post(f"/parties/{pid}/requests", headers=auth(t2)).status_code == 409, "one pending ask at a time"
    assert client.get(f"/parties/{pid}/requests", headers=auth(t2)).status_code == 403, "only the leader sees requests"
    pending = client.get(f"/parties/{pid}/requests", headers=auth(t1)).json()
    assert [(p["name"], p["class"]) for p in pending] == [("C1", "warrior")]
    rid = req.json()["id"]
    assert client.post(f"/parties/{pid}/requests/{rid}/approve", headers=auth(t2)).status_code == 403
    assert client.post(f"/parties/{pid}/requests/{rid}/approve", headers=auth(t1)).status_code == 200
    assert client.post(f"/parties/{pid}/requests/{rid}/reject", headers=auth(t1)).status_code == 409, "already decided"
    assert [m["name"] for m in client.get(f"/parties/{pid}", headers=auth(t3)).json()["members"]] == ["C0", "C1"]
    assert my_party(client, w["id"], t2)["id"] == pid, "their old party of one is gone"
    # a rejected ask grants nothing, and a player can cancel their own ask
    r3 = client.post(f"/parties/{pid}/requests", headers=auth(t3)).json()["id"]
    assert client.post(f"/parties/{pid}/requests/{r3}/reject", headers=auth(t1)).status_code == 200
    assert len(client.get(f"/parties/{pid}", headers=auth(t3)).json()["members"]) == 2
    client.post(f"/parties/{pid}/requests", headers=auth(t3))
    assert client.post(f"/parties/{pid}/requests/cancel", headers=auth(t3)).status_code == 204
    assert client.post(f"/parties/{pid}/requests/cancel", headers=auth(t3)).status_code == 404
    assert client.get(f"/parties/{pid}/requests", headers=auth(t1)).json() == []


def test_joining_somewhere_cancels_the_other_pending_asks(client, pool):
    w, [t1, t2, t3], _ = party(client, pool, 3)
    a, b = my_party(client, w["id"], t1)["id"], my_party(client, w["id"], t2)["id"]
    ra = client.post(f"/parties/{a}/requests", headers=auth(t3)).json()["id"]
    client.post(f"/parties/{b}/requests", headers=auth(t3))
    client.post(f"/parties/{a}/requests/{ra}/approve", headers=auth(t1))
    assert client.get(f"/parties/{b}/requests", headers=auth(t2)).json() == [], "the ask to the second party was withdrawn"


def test_the_run_takes_the_roster_and_locks_it(client, pool):
    w, [t1, t2], _ = party(client, pool)
    pid = my_party(client, w["id"], t1)["id"]
    join_party(client, pid, t1, t2)
    assert start(client, pid, t2).status_code == 403, "only the leader starts"
    iid = start(client, pid, t1).json()["id"]
    assert client.post(f"/parties/{pid}/leave", headers=auth(t2)).status_code == 409, "no departure mid-activity"
    other, _ = join(client, w["id"], t1)
    char(client, w["id"], other, "Late")
    assert client.post(f"/parties/{pid}/requests", headers=auth(other)).status_code == 409, "roster locked"
    inst = client.get(f"/internal/instances/{iid}", headers=SERVER).json()
    assert [r["name"] for r in inst["roster"]] == ["C0", "C1"]
    assert (inst["encounter"], inst["max_players"], inst["activity_name"]) == ("prototype", 4, "Clear the cellar")


def test_asks_pending_at_the_start_are_withdrawn(client, pool):
    w, [t1, t2], _ = party(client, pool)
    pid = my_party(client, w["id"], t1)["id"]
    client.post(f"/parties/{pid}/requests", headers=auth(t2))
    start(client, pid, t1)
    with pool.connection() as c:
        assert c.execute("select count(*) n from party_join_requests where status='pending'").fetchone()["n"] == 0


def test_leader_leaving_hands_over_to_the_longest_standing_member(client, pool):
    w, [t1, t2, t3], _ = party(client, pool, 3)
    pid = my_party(client, w["id"], t1)["id"]
    join_party(client, pid, t1, t2)
    join_party(client, pid, t1, t3)
    assert client.post(f"/parties/{pid}/leave", headers=auth(t1)).status_code == 204
    p = client.get(f"/parties/{pid}", headers=auth(t3)).json()
    assert p["leader"]["name"] == "C1" and [m["name"] for m in p["members"]] == ["C1", "C2"]
    assert (client.get(f"/parties/{pid}", headers=auth(t2)).json()["relation"],
            client.get(f"/parties/{pid}", headers=auth(t3)).json()["relation"]) == ("leader", "member")
    assert start(client, pid, t2).status_code == 201, "the new leader can start"
    alone = my_party(client, w["id"], t1)
    assert alone["id"] != pid and [m["name"] for m in alone["members"]] == ["C0"], "the one who left is on their own"


def test_a_lone_character_cannot_leave_and_empty_parties_disappear(client, pool):
    w, [t1, t2], _ = party(client, pool)
    solo = my_party(client, w["id"], t1)["id"]
    assert client.post(f"/parties/{solo}/leave", headers=auth(t1)).status_code == 409
    other = my_party(client, w["id"], t2)["id"]
    join_party(client, solo, t1, t2)
    assert client.get(f"/parties/{other}", headers=auth(t1)).status_code == 404, "an emptied party is closed"
    assert {p["id"] for p in client.get(f"/worlds/{w['id']}/parties", headers=auth(t1)).json()} == {solo}


def test_party_list_shows_every_party_and_my_relation(client, pool):
    w, [t1, t2, t3], _ = party(client, pool, 3)
    a, b = my_party(client, w["id"], t1)["id"], my_party(client, w["id"], t2)["id"]
    client.post(f"/parties/{a}/requests", headers=auth(t3))
    rows = {p["id"]: p for p in client.get(f"/worlds/{w['id']}/parties", headers=auth(t3)).json()}
    assert a in rows and b in rows and len(rows) == 3
    assert (rows[a]["relation"], rows[a]["leader"]["name"], rows[a]["node_name"], rows[a]["here"]) == ("pending", "C0", "Hollowmere", True)
    assert (rows[b]["relation"], rows[b]["open"], rows[b]["max_size"]) == ("none", True, 4)
    mine = {p["id"]: p["relation"] for p in client.get(f"/worlds/{w['id']}/parties", headers=auth(t1)).json()}
    assert mine[a] == "leader" and mine[b] == "none"
    start(client, b, t2, "training_skirmish")
    started = {p["id"]: p for p in client.get(f"/worlds/{w['id']}/parties", headers=auth(t3)).json()}
    assert started[b]["instance"]["status"] == "active" and started[b]["open"] is False
    outsider, _ = new_user()
    assert client.get(f"/worlds/{w['id']}/parties", headers=auth(outsider)).status_code == 403
    assert client.get(f"/parties/{a}", headers=auth(outsider)).status_code == 403


def test_party_capacity(client, pool):
    w, toks, chars = party(client, pool, 5)
    pid = my_party(client, w["id"], toks[0])["id"]
    for t in toks[1:4]:
        join_party(client, pid, toks[0], t)
    assert client.post(f"/parties/{pid}/requests", headers=auth(toks[4])).status_code == 409, "the party holds 4"


def test_game_server_checks_the_roster_when_a_player_enters_a_battle(client, pool):
    w, [t1, t2, t3], _ = party(client, pool, 3)
    pid = my_party(client, w["id"], t1)["id"]
    join_party(client, pid, t1, t2)
    iid = start(client, pid, t1).json()["id"]

    def seat(tok):
        return client.post("/internal/auth/session", headers=SERVER,
                           json={"token": tok, "world_id": w["id"], "instance_id": iid})
    ok = seat(t2).json()
    assert ok["character"]["name"] == "C1" and ok["instance"]["encounter"] == "prototype"
    assert seat(t3).status_code == 403, "a member who is not on the roster is refused"
    client.post(f"/internal/instances/{iid}/complete", headers=SERVER)
    assert seat(t1).status_code == 409, "a finished run cannot be entered"
    assert my_party(client, w["id"], t1)["instance"] is None, "the party is idle again"


def test_one_time_major_completion_changes_the_world_atomically(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    reveal(client, w["id"], "node", "ashen_keep", "world")  # revision 1
    for c in (c1, c2):
        set_node(pool, c["id"], "ashen_keep")
    with pool.connection() as conn:
        conn.execute("update parties set node_id='ashen_keep' where world_id=%s", (w["id"],))
    iid = new_party(client, w["id"], t1, "ashen_keep_siege")
    done = client.post(f"/internal/instances/{iid}/complete", headers=SERVER).json()
    assert done["world_changed"] and done["state_revision"] == 2 and not done["duplicate"]
    replay = client.post(f"/internal/instances/{iid}/complete", headers=SERVER).json()
    assert replay["duplicate"] and replay["state_revision"] == 2, "replays never advance the revision"
    # consequences are visible to everyone, including players who missed the event
    ov = overview(client, w["id"], t2)
    assert "sunken_crypt" in {n["id"] for n in ov["nodes"]} and "tunnel_ak_crypt" in {r["id"] for r in ov["routes"]}
    siege = next(a for a in ov["activities"] if a["id"] == "ashen_keep_siege")
    assert siege["available"] is False
    # the one-time activity is unavailable to new participants
    r = start(client, my_party(client, w["id"], t1)["id"], t1, "ashen_keep_siege")
    assert r.status_code == 409 and "no longer available" in r.json()["detail"]


def test_a_run_must_be_started_to_be_completed(client, pool):
    w, [t1, _], _ = party(client, pool)
    iid = new_party(client, w["id"], t1)
    client.post(f"/internal/instances/{iid}/cancel", headers=SERVER)
    assert client.post(f"/internal/instances/{iid}/complete", headers=SERVER).status_code == 409


def test_minor_completion_without_world_effects_keeps_revision(client, pool):
    w, [t1, _], [c1, _] = party(client, pool)
    iid = new_party(client, w["id"], t1)
    done = client.post(f"/internal/instances/{iid}/complete", headers=SERVER).json()
    assert not done["world_changed"] and done["state_revision"] == 0
    assert start(client, my_party(client, w["id"], t1)["id"], t1).status_code == 201, "repeatable activities can run again"


def test_failed_completion_does_not_advance_revision_or_state(client, pool):
    w, [t1, _], [c1, _] = party(client, pool)
    reveal(client, w["id"], "node", "ashen_keep", "world")
    set_node(pool, c1["id"], "ashen_keep")
    with pool.connection() as conn:
        conn.execute("update parties set node_id='ashen_keep' where world_id=%s and leader_character_id=%s", (w["id"], c1["id"]))
    iid = new_party(client, w["id"], t1, "ashen_keep_siege")
    with pool.connection() as c:  # simulate another path already completing it
        c.execute("update world_activities set status='completed' where world_id=%s", (w["id"],))
    assert client.post(f"/internal/instances/{iid}/complete", headers=SERVER).status_code == 409
    with pool.connection() as c:
        assert c.execute("select state_revision from worlds where id=%s", (w["id"],)).fetchone()["state_revision"] == 1
        assert c.execute("select count(*) n from world_discoveries where target_id='sunken_crypt'").fetchone()["n"] == 0
        assert c.execute("select status from activity_instances where id=%s", (iid,)).fetchone()["status"] == "active"


def test_cancelled_run_frees_the_party_and_the_reservation(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    iid = new_party(client, w["id"], t1)
    assert client.post(f"/internal/instances/{iid}/cancel", headers=SERVER).json()["status"] == "cancelled"
    assert my_party(client, w["id"], t1)["instance"] is None
    assert start(client, my_party(client, w["id"], t1)["id"], t1).status_code == 201


def test_membership_status_follows_the_join_flow(client):
    w, host_tok, _ = make_world(client, "Joinable")
    wid = w["id"]
    tok, _ = new_user()

    def status(t):
        r = client.get(f"/worlds/{wid}/membership", headers=auth(t))
        assert r.status_code == 200, r.text
        return r.json()

    s = status(tok)
    assert s["status"] == "none" and s["world"]["name"] == "Joinable" and s["is_host"] is False
    assert status(host_tok)["status"] == "member" and status(host_tok)["is_host"] is True

    req = client.post(f"/worlds/{wid}/requests", headers=auth(tok)).json()
    assert status(tok)["status"] == "pending"
    assert client.post(f"/worlds/{wid}/requests/{req['id']}/reject", headers=auth(host_tok)).status_code == 200
    assert status(tok)["status"] == "rejected"

    req2 = client.post(f"/worlds/{wid}/requests", headers=auth(tok))
    assert req2.status_code == 201, "a rejected user can ask again"
    assert client.post(f"/worlds/{wid}/requests/{req2.json()['id']}/approve", headers=auth(host_tok)).status_code == 200
    assert status(tok)["status"] == "member" and status(tok)["is_host"] is False

    me = client.get(f"/worlds/{wid}/characters/me", headers=auth(tok))
    assert me.status_code == 404, "approved but no character yet"


def test_membership_of_an_unknown_world_is_404_and_needs_login(client):
    tok, _ = new_user()
    assert client.get(f"/worlds/{uuid.uuid4()}/membership", headers=auth(tok)).status_code == 404
    assert client.get(f"/worlds/{uuid.uuid4()}/membership").status_code == 401


def test_removed_member_sees_removed_and_can_request_again(client):
    w, host_tok, _ = make_world(client, "Removal")
    tok, uid = join(client, w["id"], host_tok)
    assert client.post(f"/worlds/{w['id']}/members/{uid}/remove", headers=auth(host_tok)).status_code == 204
    assert client.get(f"/worlds/{w['id']}/membership", headers=auth(tok)).json()["status"] == "removed"
    assert client.post(f"/worlds/{w['id']}/requests", headers=auth(tok)).status_code == 201


def test_join_request_carries_the_email_label_from_the_token(client):
    w, host_tok, _ = make_world(client, "Labels")
    tok, _ = token_for(email="tester@example.com")
    assert client.post(f"/worlds/{w['id']}/requests", headers=auth(tok)).status_code == 201
    reqs = client.get(f"/worlds/{w['id']}/requests", headers=auth(host_tok)).json()
    assert reqs[0]["requester_label"] == "tester@example.com"
    anon, _ = new_user()
    client.post(f"/worlds/{w['id']}/requests", headers=auth(anon))
    labels = {r["requester_label"] for r in client.get(f"/worlds/{w['id']}/requests", headers=auth(host_tok)).json()}
    assert None in labels and "tester@example.com" in labels


def test_available_worlds_lists_every_world_with_my_standing(client):
    a, host_a, _ = make_world(client, "Alpha")
    b, host_b, _ = make_world(client, "Bravo")
    tok, _ = new_user()

    def listing():
        r = client.get("/worlds/available", headers=auth(tok))
        assert r.status_code == 200, r.text
        return {w["name"]: w for w in r.json()}

    w = listing()
    assert w["Alpha"]["status"] == "none" and w["Bravo"]["status"] == "none", "worlds are visible before joining"
    assert w["Alpha"]["members"] == 1 and w["Alpha"]["is_host"] is False
    assert set(w["Alpha"]) == {"id", "name", "members", "status", "is_host"}, "no member identities leak"

    req = client.post(f"/worlds/{a['id']}/requests", headers=auth(tok)).json()
    assert listing()["Alpha"]["status"] == "pending"
    client.post(f"/worlds/{a['id']}/requests/{req['id']}/approve", headers=auth(host_a))
    w = listing()
    assert w["Alpha"]["status"] == "member" and w["Alpha"]["members"] == 2 and w["Bravo"]["status"] == "none"
    assert list(listing())[0] == "Alpha", "my worlds come first"

    mine = client.get("/worlds/available", headers=auth(host_b)).json()
    assert [x["is_host"] for x in mine if x["name"] == "Bravo"] == [True]
    assert client.get("/worlds/available").status_code == 401
    assert client.get("/worlds", headers=auth(tok)).json()[0]["name"] == "Alpha", "/worlds still lists only my worlds"


# ---------- world management: members, rename, delete ----------

def test_host_lists_members_and_renames_the_world(client):
    w, host, _ = make_world(client, "Old")
    tok, uid = join(client, w["id"], host)
    char(client, w["id"], tok, name="Tessa")
    m = client.get(f"/worlds/{w['id']}/members", headers=auth(host)).json()
    assert [x["role"] for x in m] == ["host", "member"]
    assert m[1]["user_id"] == uid and m[1]["character_name"] == "Tessa"
    assert client.get(f"/worlds/{w['id']}/members", headers=auth(tok)).status_code == 403
    assert client.post(f"/worlds/{w['id']}/rename", json={"name": "New"}, headers=auth(tok)).status_code == 403
    assert client.post(f"/worlds/{w['id']}/rename", json={"name": ""}, headers=auth(host)).status_code == 422
    assert client.post(f"/worlds/{w['id']}/rename", json={"name": "New"}, headers=auth(host)).json()["name"] == "New"
    assert client.get("/worlds", headers=auth(host)).json()[0]["name"] == "New"
    client.post(f"/worlds/{w['id']}/members/{uid}/remove", headers=auth(host))
    assert len(client.get(f"/worlds/{w['id']}/members", headers=auth(host)).json()) == 1


def test_deleting_a_world_is_permanent_and_guarded(client, pool):
    w, host, _ = make_world(client, "Doomed")
    tok, _uid = join(client, w["id"], host)
    char(client, w["id"], host, name="Aldric")
    char(client, w["id"], tok, name="Tessa")
    wid = w["id"]
    body = lambda n: {"confirm_name": n}
    assert client.post(f"/worlds/{wid}/delete", json=body("Doomed"), headers=auth(tok)).status_code == 403
    assert client.post(f"/worlds/{wid}/delete", json=body("doomed"), headers=auth(host)).status_code == 422
    p = new_party(client, wid, host, "training_skirmish")
    assert client.post(f"/worlds/{wid}/delete", json=body("Doomed"), headers=auth(host)).status_code == 409, "a running activity blocks it"
    client.post(f"/internal/instances/{p}/cancel", headers=SERVER)
    assert client.post(f"/worlds/{wid}/delete", json=body("Doomed"), headers=auth(host)).status_code == 204
    assert client.get("/worlds", headers=auth(host)).json() == []
    assert client.get(f"/worlds/{wid}/membership", headers=auth(tok)).status_code == 404
    with pool.connection() as c:
        for t in ("characters", "activity_instances", "world_members", "combat_results", "parties"):
            assert c.execute(f"select count(*) as n from {t} where world_id=%s", (wid,)).fetchone()["n"] == 0


# ---------- character page: roster, history, retirement, XP reset, party leadership ----------

def result(wid, cid, key, outcome="players_win", xp=100):
    return {"idempotency_key": key, "world_id": wid, "outcome": outcome, "rounds": 3,
            "participants": [{"character_id": cid, "outcome": "survived", "xp": xp}]}


def test_world_characters_show_owners_and_fallen_ones(client):
    w, host, _ = make_world(client)
    tok, _uid = join(client, w["id"], host)
    char(client, w["id"], host, "Aldric")
    old = char(client, w["id"], tok, "Tessa")
    client.post(f"/characters/{old['id']}/retire", headers=auth(tok))
    char(client, w["id"], tok, "Tessa II", "rogue")
    rows = client.get(f"/worlds/{w['id']}/characters", headers=auth(tok)).json()
    assert [(r["name"], r["status"], r["mine"]) for r in rows] == [
        ("Aldric", "active", False), ("Tessa II", "active", True), ("Tessa", "retired", True)]
    assert rows[0]["owner"] == "Host" and rows[1]["owner"].startswith("Player ")
    mail_tok, _ = token_for(email="mira.k@example.com")  # the join label is the email; only the part before @ is shown
    rid = client.post(f"/worlds/{w['id']}/requests", headers=auth(mail_tok)).json()["id"]
    client.post(f"/worlds/{w['id']}/requests/{rid}/approve", headers=auth(host))
    char(client, w["id"], mail_tok, "Mira")
    owners = {r["name"]: r["owner"] for r in client.get(f"/worlds/{w['id']}/characters", headers=auth(host)).json()}
    assert owners["Mira"] == "mira.k"
    assert client.get(f"/worlds/{w['id']}/characters", headers=auth(new_user()[0])).status_code == 403


def test_battle_history_and_the_xp_reset_rule(client):
    w, host, _ = make_world(client)
    c = char(client, w["id"], host)
    for i in range(7):
        assert client.post("/internal/combat-results", json=result(w["id"], c["id"], f"battle-{i}"), headers=SERVER).status_code == 200
    me = client.get(f"/worlds/{w['id']}/characters/me", headers=auth(host)).json()
    assert me["xp"] == 0 and me["level"] == 1, "the prototype template resets XP after every battle"
    h = client.get(f"/worlds/{w['id']}/characters/me/battles", headers=auth(host)).json()
    assert len(h) == 5 and h[0]["xp_awarded"] == 100 and h[0]["result"] == "players_win" and h[0]["outcome"] == "survived"
    assert client.get(f"/worlds/{w['id']}/characters/me/battles", headers=auth(new_user()[0])).status_code in (403, 404)


def test_a_character_in_an_activity_cannot_retire_and_retiring_leaves_the_party(client):
    w, host, _ = make_world(client)
    tok, _uid = join(client, w["id"], host)
    c, other = char(client, w["id"], host), char(client, w["id"], tok, "Other")
    pid = my_party(client, w["id"], host)["id"]
    join_party(client, pid, host, tok)
    run = new_party(client, w["id"], host, "training_skirmish")
    assert client.post(f"/characters/{c['id']}/retire", headers=auth(host)).status_code == 409
    client.post(f"/internal/instances/{run}/cancel", headers=SERVER)
    assert client.post(f"/characters/{c['id']}/retire", headers=auth(host)).status_code == 200
    p = client.get(f"/parties/{pid}", headers=auth(tok)).json()
    assert [m["name"] for m in p["members"]] == ["Other"] and p["leader"]["id"] == other["id"]


def test_world_info_is_for_the_host(client):
    w, host, _ = make_world(client, "Info")
    tok, _uid = join(client, w["id"], host)
    char(client, w["id"], host)
    new_party(client, w["id"], host, "training_skirmish")
    i = client.get(f"/worlds/{w['id']}/info", headers=auth(host)).json()
    assert (i["name"], i["template_id"], i["definition_version"], i["members"], i["characters"], i["live_parties"], i["battles"]) \
        == ("Info", "prototype", 1, 2, 1, 1, 0)
    assert client.get(f"/worlds/{w['id']}/info", headers=auth(tok)).status_code == 403


def test_leader_hands_the_party_to_a_member(client, pool):
    w, [t1, t2, t3], [c1, c2, c3] = party(client, pool, 3)
    iid = my_party(client, w["id"], t1)["id"]
    join_party(client, iid, t1, t2)
    body = lambda c: {"character_id": c["id"]}
    assert client.post(f"/parties/{iid}/leader", json=body(c2), headers=auth(t2)).status_code == 403, "only the leader"
    assert client.post(f"/parties/{iid}/leader", json=body(c3), headers=auth(t1)).status_code == 404, "must be on the roster"
    assert client.post(f"/parties/{iid}/leader", json=body(c2), headers=auth(t1)).status_code == 204
    assert client.get(f"/parties/{iid}", headers=auth(t1)).json()["leader"]["id"] == c2["id"]
    assert client.post(f"/parties/{iid}/leader", json=body(c1), headers=auth(t1)).status_code == 403, "no longer the leader"
    start(client, iid, t2)
    assert client.post(f"/parties/{iid}/leader", json=body(c1), headers=auth(t2)).status_code == 409, "not mid-activity"


def test_a_removed_member_drops_out_of_the_running_battle(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    join_party(client, my_party(client, w["id"], t1)["id"], t1, t2)
    rid = new_party(client, w["id"], t1)
    roster = lambda: [r["name"] for r in client.get(f"/internal/instances/{rid}", headers=SERVER).json()["roster"]]
    assert roster() == ["C0", "C1"]
    uid = client.get(f"/worlds/{w['id']}/characters/me", headers=auth(t2)).json()["user_id"]
    assert client.post(f"/worlds/{w['id']}/members/{uid}/remove", headers=auth(t1)).status_code == 204
    assert roster() == ["C0"], "the removed player no longer holds a seat"
    assert [m["name"] for m in my_party(client, w["id"], t1)["members"]] == ["C0"]


def beat(client, wid, tok):
    assert client.post(f"/worlds/{wid}/presence", headers=auth(tok)).status_code == 204


def go_offline(pool, character_id, seconds=60):
    with pool.connection() as c:
        c.execute("update characters set last_seen_at = now() - make_interval(secs => %s) where id=%s", (seconds, character_id))


def test_coming_back_alone_to_an_offline_party_starts_a_new_session_alone(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    pid = my_party(client, w["id"], t1)["id"]
    join_party(client, pid, t1, t2)
    set_node(pool, c1["id"], "hollowmere")
    beat(client, w["id"], t1)
    beat(client, w["id"], t2)
    beat(client, w["id"], t1)
    assert len(my_party(client, w["id"], t1)["members"]) == 2, "a heartbeat inside the window changes nothing"
    go_offline(pool, c1["id"])
    go_offline(pool, c2["id"])
    beat(client, w["id"], t1)  # a new session, and the other member is offline
    mine = my_party(client, w["id"], t1)
    assert [m["name"] for m in mine["members"]] == ["C0"] and mine["id"] != pid and mine["node_id"] == "hollowmere"
    assert [m["name"] for m in my_party(client, w["id"], t2)["members"]] == ["C1"], "the other player is alone too"


def test_a_returning_player_keeps_a_party_whose_other_member_is_online(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    pid = my_party(client, w["id"], t1)["id"]
    join_party(client, pid, t1, t2)
    beat(client, w["id"], t2)
    go_offline(pool, c1["id"])
    beat(client, w["id"], t1)
    assert my_party(client, w["id"], t1)["id"] == pid


def test_a_party_in_an_activity_is_not_reset_by_a_new_session(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    join_party(client, my_party(client, w["id"], t1)["id"], t1, t2)
    new_party(client, w["id"], t1)
    beat(client, w["id"], t1)
    go_offline(pool, c1["id"])
    go_offline(pool, c2["id"])
    beat(client, w["id"], t1)
    assert len(my_party(client, w["id"], t1)["members"]) == 2


def test_listing_disbands_idle_parties_whose_members_are_all_offline(client, pool):
    w, [t1, t2, t3], [c1, c2, c3] = party(client, pool, 3)
    pid = my_party(client, w["id"], t1)["id"]
    join_party(client, pid, t1, t2)
    for t in (t1, t2, t3):
        beat(client, w["id"], t)
    assert any(len(p["members"]) == 2 for p in client.get(f"/worlds/{w['id']}/parties", headers=auth(t3)).json())
    go_offline(pool, c1["id"])
    go_offline(pool, c2["id"])
    listed = client.get(f"/worlds/{w['id']}/parties", headers=auth(t3)).json()
    assert sorted(len(p["members"]) for p in listed) == [1, 1, 1]
    assert [m["name"] for m in my_party(client, w["id"], t2)["members"]] == ["C1"]


def test_presence_needs_membership(client, pool):
    w, [t1], _ = party(client, pool, 1)
    stranger, _ = new_user()
    assert client.post(f"/worlds/{w['id']}/presence", headers=auth(stranger)).status_code == 403


def test_a_display_name_replaces_the_email_prefix_for_other_players(client):
    w, host, _ = make_world(client)
    mail_tok, _ = token_for(email="mira.k@example.com")
    rid = client.post(f"/worlds/{w['id']}/requests", headers=auth(mail_tok)).json()["id"]
    assert client.get("/me/profile", headers=auth(mail_tok)).json() == {"display_name": None}
    assert [r["display_name"] for r in client.get(f"/worlds/{w['id']}/requests", headers=auth(host)).json()] == [None]
    assert client.put("/me/profile", json={"display_name": "  Mira \n the  Grey "}, headers=auth(mail_tok)).json() == {"display_name": "Mira the Grey"}
    reqs = client.get(f"/worlds/{w['id']}/requests", headers=auth(host)).json()
    assert (reqs[0]["display_name"], reqs[0]["requester_label"]) == ("Mira the Grey", "mira.k@example.com"), "the host still sees the email"
    client.post(f"/worlds/{w['id']}/requests/{rid}/approve", headers=auth(host))
    char(client, w["id"], mail_tok, "Mira")
    owners = {r["name"]: r["owner"] for r in client.get(f"/worlds/{w['id']}/characters", headers=auth(host)).json()}
    assert owners["Mira"] == "Mira the Grey"
    members = client.get(f"/worlds/{w['id']}/members", headers=auth(host)).json()
    assert "Mira the Grey" in [m["display_name"] for m in members]


def test_display_names_are_validated_and_belong_to_the_caller(client):
    tok, _ = new_user()
    for bad in ["", "   ", "x" * 25, "bell\x07"]:
        assert client.put("/me/profile", json={"display_name": bad}, headers=auth(tok)).status_code == 422, bad
    assert client.put("/me/profile", json={"display_name": "Ok"}, headers=auth(tok)).status_code == 200
    other, _ = new_user()
    assert client.get("/me/profile", headers=auth(other)).json() == {"display_name": None}
    assert client.get("/me/profile").status_code == 401
