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
    r = client.post(f"/worlds/{world_id}/characters", json={"name": name, "origin": "outcast", "class": cls}, headers=auth(tok))
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


def test_invalid_templates_are_rejected():
    base = json.loads((DEFAULT_DIR / "prototype@1.json").read_text())
    for mutate in (lambda d: d["routes"][0].update({"to": "nowhere"}),
                   lambda d: d.update({"start_node": "nowhere"}),
                   lambda d: d["nodes"].append(dict(d["nodes"][0])),
                   lambda d: d["activities"][0].update({"one_time": True}),  # minor + one_time
                   lambda d: d["activities"][2]["on_complete"]["reveal"].append({"kind": "node", "id": "ghost"})):
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
    return client.post(f"/worlds/{world_id}/characters", json={"name": "x", "origin": "outcast", "class": "warrior"}, headers=auth(tok)).status_code


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


# ---------- activities ----------

def party(client, pool, n=2):
    w, host, _ = make_world(client)
    toks = [host] + [join(client, w["id"], host)[0] for _ in range(n - 1)]
    chars = [char(client, w["id"], t, f"C{i}") for i, t in enumerate(toks)]
    return w, toks, chars


def test_instances_require_discovery_presence_and_membership(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    url = f"/worlds/{w['id']}/activities/ashen_keep_siege/instances"
    assert client.post(url, headers=auth(t1)).status_code == 403, "location not discovered"
    reveal(client, w["id"], "node", "ashen_keep", "world")
    assert client.post(url, headers=auth(t1)).status_code == 403, "not physically present"
    set_node(pool, c1["id"], "ashen_keep")
    outsider, _ = new_user()
    assert client.post(url, headers=auth(outsider)).status_code == 403
    assert client.post(url, headers=auth(t1)).status_code == 201


def test_duplicate_and_concurrent_major_instances_are_prevented_atomically(client, pool):
    w, toks, chars = party(client, pool, 3)
    for n in ("ashen_keep",):
        reveal(client, w["id"], "node", n, "world")
    reveal(client, w["id"], "node", "blackwood", "world")
    for c in chars:
        set_node(pool, c["id"], "ashen_keep")
    url = f"/worlds/{w['id']}/activities/ashen_keep_siege/instances"
    with ThreadPoolExecutor(3) as ex:
        codes = sorted(ex.map(lambda t: client.post(url, headers=auth(t)).status_code, toks))
    assert codes == [201, 409, 409], "exactly one reservation wins"
    # a different major activity cannot run at the same time; minor ones can
    d = json.loads((DEFAULT_DIR / "prototype@1.json").read_text())
    set_node(pool, chars[1]["id"], "hollowmere")
    ok = client.post(f"/worlds/{w['id']}/activities/cellar_rats/instances", headers=auth(toks[1]))
    assert ok.status_code == 201, "minor activities run concurrently with a major one"
    set_node(pool, chars[2]["id"], "hollowmere")
    dup = client.post(f"/worlds/{w['id']}/activities/cellar_rats/instances", headers=auth(toks[2]))
    assert dup.status_code == 409 and "already has an active instance" in dup.json()["detail"]


def test_roster_rules_leader_decisions_and_locking(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    inst = client.post(f"/worlds/{w['id']}/activities/cellar_rats/instances", headers=auth(t1)).json()
    iid = inst["id"]
    set_node(pool, c2["id"], "blackwood")
    assert client.post(f"/instances/{iid}/join", headers=auth(t2)).status_code == 403, "must be present"
    set_node(pool, c2["id"], "hollowmere")
    assert client.post(f"/instances/{iid}/join", headers=auth(t2)).status_code == 200
    assert client.post(f"/instances/{iid}/join", headers=auth(t2)).status_code == 409
    assert client.post(f"/instances/{iid}/start", headers=auth(t2)).status_code == 403, "only the leader starts"
    assert client.post(f"/instances/{iid}/leave", headers=auth(t2)).status_code == 204
    client.post(f"/instances/{iid}/join", headers=auth(t2))
    assert client.post(f"/instances/{iid}/start", headers=auth(t1)).json()["status"] == "active"
    assert client.post(f"/instances/{iid}/leave", headers=auth(t2)).status_code == 409, "no voluntary departure after start"
    other, _ = join(client, w["id"], t1)
    char(client, w["id"], other, "Late")
    assert client.post(f"/instances/{iid}/join", headers=auth(other)).status_code == 409, "roster locked"
    inst = client.get(f"/internal/instances/{iid}", headers=SERVER).json()
    assert [r["name"] for r in inst["roster"]] == ["C0", "C1"]


def test_roster_capacity(client, pool):
    w, toks, chars = party(client, pool, 5)
    iid = client.post(f"/worlds/{w['id']}/activities/cellar_rats/instances", headers=auth(toks[0])).json()["id"]
    codes = [client.post(f"/instances/{iid}/join", headers=auth(t)).status_code for t in toks[1:]]
    assert codes == [200, 200, 200, 409], "cellar_rats allows 4 players"


def test_one_time_major_completion_changes_the_world_atomically(client, pool):
    w, [t1, t2], [c1, c2] = party(client, pool)
    reveal(client, w["id"], "node", "ashen_keep", "world")  # revision 1
    set_node(pool, c1["id"], "ashen_keep")
    iid = client.post(f"/worlds/{w['id']}/activities/ashen_keep_siege/instances", headers=auth(t1)).json()["id"]
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
    set_node(pool, c1["id"], "ashen_keep")
    iid = client.post(f"/worlds/{w['id']}/activities/ashen_keep_siege/instances", headers=auth(t1)).json()["id"]
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
