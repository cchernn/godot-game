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


# ---------- activities and parties ----------

def party(client, pool, n=2):
    w, host, _ = make_world(client)
    toks = [host] + [join(client, w["id"], host)[0] for _ in range(n - 1)]
    chars = [char(client, w["id"], t, f"C{i}") for i, t in enumerate(toks)]
    return w, toks, chars


def new_party(client, wid, tok, activity="cellar_rats"):
    r = client.post(f"/worlds/{wid}/activities/{activity}/instances", headers=auth(tok))
    assert r.status_code == 201, r.text
    return r.json()["id"]


def join_party(client, iid, leader_tok, tok):
    """The player asks, the leader approves."""
    req = client.post(f"/instances/{iid}/requests", headers=auth(tok))
    assert req.status_code == 201, req.text
    ok = client.post(f"/instances/{iid}/requests/{req.json()['id']}/approve", headers=auth(leader_tok))
    assert ok.status_code == 200, ok.text


def test_instances_require_discovery_and_membership(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    url = f"/worlds/{w['id']}/activities/ashen_keep_siege/instances"
    assert client.post(url, headers=auth(t1)).status_code == 403, "location not discovered"
    reveal(client, w["id"], "node", "ashen_keep", "world")
    outsider, _ = new_user()
    assert client.post(url, headers=auth(outsider)).status_code == 403
    assert client.post(url, headers=auth(t1)).status_code == 201, "the template does not require presence yet"


def test_presence_is_enforced_when_the_template_requires_it(pool, tmp_path):
    d = json.loads((DEFAULT_DIR / "prototype@1.json").read_text())
    d["rules"]["require_location"] = True
    (tmp_path / "prototype@1.json").write_text(json.dumps(d))
    c = TestClient(create_app(make_settings(templates_dir=str(tmp_path)), pool))
    w, [t1, t2], [c1, c2] = party(c, pool)
    set_node(pool, c1["id"], "blackwood")
    assert c.post(f"/worlds/{w['id']}/activities/cellar_rats/instances", headers=auth(t1)).status_code == 403
    set_node(pool, c1["id"], "hollowmere")
    iid = new_party(c, w["id"], t1)
    set_node(pool, c2["id"], "blackwood")
    assert c.post(f"/instances/{iid}/requests", headers=auth(t2)).status_code == 403, "must be present to ask"


def test_concurrent_major_instances_are_prevented_atomically_but_minor_parties_run_side_by_side(client, pool):
    w, toks, chars = party(client, pool, 3)
    reveal(client, w["id"], "node", "ashen_keep", "world")
    url = f"/worlds/{w['id']}/activities/ashen_keep_siege/instances"
    with ThreadPoolExecutor(3) as ex:
        results = list(ex.map(lambda t: (t, client.post(url, headers=auth(t)).status_code), toks))
    assert sorted(code for _, code in results) == [201, 409, 409], "exactly one major reservation wins"
    # a minor activity can run in several parties at once, alongside the major one
    losers = [t for t, code in results if code == 409]
    a = new_party(client, w["id"], losers[0])
    b = new_party(client, w["id"], losers[1])
    assert a != b, "several parties may run the same activity"


def test_a_character_is_in_one_party_at_a_time(client, pool):
    w, [t1, t2], _ = party(client, pool)
    new_party(client, w["id"], t1)
    assert client.post(f"/worlds/{w['id']}/activities/wolf_hunt/instances", headers=auth(t1)).status_code == 409
    other = new_party(client, w["id"], t2, "wolf_hunt")
    assert client.post(f"/instances/{other}/requests", headers=auth(t1)).status_code == 409, "already in a party"


def test_party_requests_are_decided_by_the_leader(client, pool):
    w, [t1, t2, t3], [c1, c2, c3] = party(client, pool, 3)
    iid = new_party(client, w["id"], t1)
    req = client.post(f"/instances/{iid}/requests", headers=auth(t2))
    assert req.status_code == 201
    assert client.post(f"/instances/{iid}/requests", headers=auth(t2)).status_code == 409, "one pending ask at a time"
    assert client.get(f"/instances/{iid}/requests", headers=auth(t2)).status_code == 403, "only the leader sees requests"
    pending = client.get(f"/instances/{iid}/requests", headers=auth(t1)).json()
    assert [(p["name"], p["class"]) for p in pending] == [("C1", "warrior")]
    rid = req.json()["id"]
    assert client.post(f"/instances/{iid}/requests/{rid}/approve", headers=auth(t2)).status_code == 403
    assert client.post(f"/instances/{iid}/requests/{rid}/approve", headers=auth(t1)).status_code == 200
    assert client.post(f"/instances/{iid}/requests/{rid}/reject", headers=auth(t1)).status_code == 409, "already decided"
    assert [m["name"] for m in client.get(f"/instances/{iid}", headers=auth(t3)).json()["members"]] == ["C0", "C1"]
    # a rejected ask grants nothing, and a player can cancel their own ask
    r3 = client.post(f"/instances/{iid}/requests", headers=auth(t3)).json()["id"]
    assert client.post(f"/instances/{iid}/requests/{r3}/reject", headers=auth(t1)).status_code == 200
    assert len(client.get(f"/instances/{iid}", headers=auth(t3)).json()["members"]) == 2
    client.post(f"/instances/{iid}/requests", headers=auth(t3))
    assert client.post(f"/instances/{iid}/requests/cancel", headers=auth(t3)).status_code == 204
    assert client.post(f"/instances/{iid}/requests/cancel", headers=auth(t3)).status_code == 404
    assert client.get(f"/instances/{iid}/requests", headers=auth(t1)).json() == []


def test_joining_somewhere_cancels_the_other_pending_asks(client, pool):
    w, [t1, t2, t3], _ = party(client, pool, 3)
    a, b = new_party(client, w["id"], t1), new_party(client, w["id"], t2, "wolf_hunt")
    ra = client.post(f"/instances/{a}/requests", headers=auth(t3)).json()["id"]
    client.post(f"/instances/{b}/requests", headers=auth(t3))
    client.post(f"/instances/{a}/requests/{ra}/approve", headers=auth(t1))
    assert client.get(f"/instances/{b}/requests", headers=auth(t2)).json() == [], "the ask to the second party was withdrawn"


def test_roster_rules_leader_decisions_and_locking(client, pool):
    w, [t1, t2], _ = party(client, pool)
    iid = new_party(client, w["id"], t1)
    join_party(client, iid, t1, t2)
    assert client.post(f"/instances/{iid}/start", headers=auth(t2)).status_code == 403, "only the leader starts"
    assert client.post(f"/instances/{iid}/leave", headers=auth(t2)).status_code == 204
    join_party(client, iid, t1, t2)
    assert client.post(f"/instances/{iid}/start", headers=auth(t1)).json()["status"] == "active"
    assert client.post(f"/instances/{iid}/leave", headers=auth(t2)).status_code == 409, "no voluntary departure after start"
    other, _ = join(client, w["id"], t1)
    char(client, w["id"], other, "Late")
    assert client.post(f"/instances/{iid}/requests", headers=auth(other)).status_code == 409, "roster locked"
    inst = client.get(f"/internal/instances/{iid}", headers=SERVER).json()
    assert [r["name"] for r in inst["roster"]] == ["C0", "C1"]
    assert (inst["encounter"], inst["max_players"], inst["activity_name"]) == ("prototype", 4, "Clear the cellar")


def test_asks_made_before_the_start_are_withdrawn(client, pool):
    w, [t1, t2], _ = party(client, pool)
    iid = new_party(client, w["id"], t1)
    client.post(f"/instances/{iid}/requests", headers=auth(t2))
    client.post(f"/instances/{iid}/start", headers=auth(t1))
    with pool.connection() as c:
        assert c.execute("select count(*) n from instance_join_requests where status='pending'").fetchone()["n"] == 0


def test_leader_leaving_hands_over_to_the_longest_standing_member(client, pool):
    w, [t1, t2, t3], _ = party(client, pool, 3)
    iid = new_party(client, w["id"], t1)
    join_party(client, iid, t1, t2)
    join_party(client, iid, t1, t3)
    assert client.post(f"/instances/{iid}/leave", headers=auth(t1)).status_code == 204
    p = client.get(f"/instances/{iid}", headers=auth(t3)).json()
    assert p["leader"]["name"] == "C1" and p["status"] == "forming"
    assert (client.get(f"/instances/{iid}", headers=auth(t2)).json()["relation"],
            client.get(f"/instances/{iid}", headers=auth(t3)).json()["relation"]) == ("leader", "member")
    assert client.post(f"/instances/{iid}/start", headers=auth(t2)).status_code == 200, "the new leader can start"


def test_the_last_member_leaving_cancels_the_party(client, pool):
    w, [t1, t2], _ = party(client, pool)
    iid = new_party(client, w["id"], t1)
    assert client.post(f"/instances/{iid}/leave", headers=auth(t1)).status_code == 204
    assert client.get(f"/instances/{iid}", headers=auth(t1)).json()["status"] == "cancelled"
    assert client.get(f"/worlds/{w['id']}/parties", headers=auth(t1)).json() == []
    assert new_party(client, w["id"], t1) != iid, "they are free to start another"


def test_party_list_shows_every_live_party_and_my_relation(client, pool):
    w, [t1, t2, t3], _ = party(client, pool, 3)
    a, b = new_party(client, w["id"], t1), new_party(client, w["id"], t2, "wolf_hunt")
    client.post(f"/instances/{a}/requests", headers=auth(t3))
    rows = {p["id"]: p for p in client.get(f"/worlds/{w['id']}/parties", headers=auth(t3)).json()}
    assert set(rows) == {a, b}
    assert (rows[a]["relation"], rows[a]["activity_name"], rows[a]["leader"]["name"]) == ("pending", "Clear the cellar", "C0")
    assert (rows[b]["relation"], rows[b]["open"], rows[b]["max_players"]) == ("none", True, 4)
    mine = {p["id"]: p["relation"] for p in client.get(f"/worlds/{w['id']}/parties", headers=auth(t1)).json()}
    assert mine == {a: "leader", b: "none"}
    client.post(f"/instances/{b}/start", headers=auth(t2))
    started = {p["id"]: p for p in client.get(f"/worlds/{w['id']}/parties", headers=auth(t3)).json()}
    assert started[b]["status"] == "active" and started[b]["open"] is False
    outsider, _ = new_user()
    assert client.get(f"/worlds/{w['id']}/parties", headers=auth(outsider)).status_code == 403
    assert client.get(f"/instances/{a}", headers=auth(outsider)).status_code == 403


def test_roster_capacity(client, pool):
    w, toks, chars = party(client, pool, 5)
    iid = new_party(client, w["id"], toks[0])
    for t in toks[1:4]:
        join_party(client, iid, toks[0], t)
    assert client.post(f"/instances/{iid}/requests", headers=auth(toks[4])).status_code == 409, "cellar_rats allows 4 players"


def test_game_server_checks_the_roster_when_a_player_enters_a_battle(client, pool):
    w, [t1, t2, t3], _ = party(client, pool, 3)
    iid = new_party(client, w["id"], t1)
    join_party(client, iid, t1, t2)

    def seat(tok):
        return client.post("/internal/auth/session", headers=SERVER,
                           json={"token": tok, "world_id": w["id"], "instance_id": iid})
    assert seat(t1).status_code == 409, "not started yet"
    client.post(f"/instances/{iid}/start", headers=auth(t1))
    ok = seat(t2).json()
    assert ok["character"]["name"] == "C1" and ok["instance"]["encounter"] == "prototype"
    assert seat(t3).status_code == 403, "a member who is not on the roster is refused"
    client.post(f"/internal/instances/{iid}/complete", headers=SERVER)
    assert seat(t1).status_code == 409, "a finished party cannot be entered"


def test_one_time_major_completion_changes_the_world_atomically(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    reveal(client, w["id"], "node", "ashen_keep", "world")  # revision 1
    iid = new_party(client, w["id"], t1, "ashen_keep_siege")
    assert client.post(f"/internal/instances/{iid}/complete", headers=SERVER).status_code == 409, "must be started first"
    client.post(f"/instances/{iid}/start", headers=auth(t1))
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
    r = client.post(f"/worlds/{w['id']}/activities/ashen_keep_siege/instances", headers=auth(t1))
    assert r.status_code == 409 and "no longer available" in r.json()["detail"]


def test_minor_completion_without_world_effects_keeps_revision(client, pool):
    w, [t1, _], [c1, _] = party(client, pool)
    iid = client.post(f"/worlds/{w['id']}/activities/cellar_rats/instances", headers=auth(t1)).json()["id"]
    client.post(f"/instances/{iid}/start", headers=auth(t1))
    done = client.post(f"/internal/instances/{iid}/complete", headers=SERVER).json()
    assert not done["world_changed"] and done["state_revision"] == 0
    again = client.post(f"/worlds/{w['id']}/activities/cellar_rats/instances", headers=auth(t1))
    assert again.status_code == 201, "repeatable activities can run again"


def test_failed_completion_does_not_advance_revision_or_state(client, pool):
    w, [t1, _], [c1, _] = party(client, pool)
    reveal(client, w["id"], "node", "ashen_keep", "world")
    iid = new_party(client, w["id"], t1, "ashen_keep_siege")
    client.post(f"/instances/{iid}/start", headers=auth(t1))
    with pool.connection() as c:  # simulate another path already completing it
        c.execute("update world_activities set status='completed' where world_id=%s", (w["id"],))
    assert client.post(f"/internal/instances/{iid}/complete", headers=SERVER).status_code == 409
    with pool.connection() as c:
        assert c.execute("select state_revision from worlds where id=%s", (w["id"],)).fetchone()["state_revision"] == 1
        assert c.execute("select count(*) n from world_discoveries where target_id='sunken_crypt'").fetchone()["n"] == 0
        assert c.execute("select status from activity_instances where id=%s", (iid,)).fetchone()["status"] == "active"


def test_cancelled_instance_frees_the_reservation(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    url = f"/worlds/{w['id']}/activities/cellar_rats/instances"
    iid = client.post(url, headers=auth(t1)).json()["id"]
    assert client.post(f"/instances/{iid}/cancel", headers=auth(t2)).status_code == 403
    assert client.post(f"/instances/{iid}/cancel", headers=auth(t1)).json()["status"] == "cancelled"
    assert client.post(url, headers=auth(t2)).status_code == 201


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
    assert client.post(f"/worlds/{wid}/delete", json=body("Doomed"), headers=auth(host)).status_code == 409, "live party blocks it"
    client.post(f"/instances/{p}/leave", headers=auth(host))
    assert client.post(f"/worlds/{wid}/delete", json=body("Doomed"), headers=auth(host)).status_code == 204
    assert client.get("/worlds", headers=auth(host)).json() == []
    assert client.get(f"/worlds/{wid}/membership", headers=auth(tok)).status_code == 404
    with pool.connection() as c:
        for t in ("characters", "activity_instances", "world_members", "combat_results"):
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


def test_a_character_in_a_live_party_cannot_retire(client):
    w, host, _ = make_world(client)
    c = char(client, w["id"], host)
    p = new_party(client, w["id"], host, "training_skirmish")
    assert client.post(f"/characters/{c['id']}/retire", headers=auth(host)).status_code == 409
    client.post(f"/instances/{p}/leave", headers=auth(host))
    assert client.post(f"/characters/{c['id']}/retire", headers=auth(host)).status_code == 200


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
    iid = new_party(client, w["id"], t1, "training_skirmish")
    join_party(client, iid, t1, t2)
    body = lambda c: {"character_id": c["id"]}
    assert client.post(f"/instances/{iid}/leader", json=body(c2), headers=auth(t2)).status_code == 403, "only the leader"
    assert client.post(f"/instances/{iid}/leader", json=body(c3), headers=auth(t1)).status_code == 404, "must be on the roster"
    assert client.post(f"/instances/{iid}/leader", json=body(c2), headers=auth(t1)).status_code == 204
    assert client.get(f"/instances/{iid}", headers=auth(t1)).json()["leader"]["id"] == c2["id"]
    assert client.post(f"/instances/{iid}/leader", json=body(c1), headers=auth(t1)).status_code == 403, "no longer the leader"
    client.post(f"/instances/{iid}/start", headers=auth(t2))
    assert client.post(f"/instances/{iid}/leader", json=body(c1), headers=auth(t2)).status_code == 409, "not after the start"
