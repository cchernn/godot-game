import uuid

from conftest import SERVER, auth, token_for


def setup_world(client, n=2):
    users = [token_for() for _ in range(n)]
    host_tok, _ = users[0]
    w = client.post("/worlds", json={"name": "Test"}, headers=auth(host_tok)).json()
    return w, users


def add_member(pool, world_id, user_id):
    with pool.connection() as c:
        c.execute("insert into world_members (world_id, user_id) values (%s,%s)", (world_id, user_id))


def make_char(client, world_id, tok, name="Hero", cls="warrior"):
    return client.post(f"/worlds/{world_id}/characters", json={"name": name, "class": cls}, headers=auth(tok))


def test_one_active_character_per_player_per_world_and_retirement(client):
    w, [(tok, _), _] = setup_world(client)
    r = make_char(client, w["id"], tok)
    assert r.status_code == 201
    assert make_char(client, w["id"], tok, "Dup").status_code == 409
    assert client.get(f"/worlds/{w['id']}/characters/me", headers=auth(tok)).json()["id"] == r.json()["id"]
    assert client.post(f"/characters/{r.json()['id']}/retire", headers=auth(tok)).json()["status"] == "retired"
    assert client.get(f"/worlds/{w['id']}/characters/me", headers=auth(tok)).status_code == 404
    again = make_char(client, w["id"], tok, "Replacement", "hunter")
    assert again.status_code == 201, "replacement allowed after retirement"


def test_authorization_membership_and_ownership(client, pool):
    w, [(host, _), (other, other_id)] = setup_world(client)
    assert make_char(client, w["id"], other).status_code == 403, "non-members cannot create characters"
    assert client.get(f"/worlds/{w['id']}/characters/me", headers=auth(other)).status_code == 403
    add_member(pool, w["id"], other_id)
    mine = make_char(client, w["id"], host).json()
    assert client.post(f"/characters/{mine['id']}/retire", headers=auth(other)).status_code == 404, "cannot retire someone else's character"
    assert client.get("/worlds", headers=auth(other)).json()[0]["id"] == w["id"]


def test_class_is_validated(client):
    w, [(tok, _), _] = setup_world(client)
    r = client.post(f"/worlds/{w['id']}/characters", json={"name": "x", "class": "nope"}, headers=auth(tok))
    assert r.status_code == 422


def test_session_verification_returns_server_derived_identity_and_character(client):
    w, [(tok, uid), _] = setup_world(client)
    char = make_char(client, w["id"], tok).json()
    r = client.post("/internal/auth/session", json={"token": tok, "world_id": w["id"]}, headers=SERVER)
    assert r.status_code == 200 and r.json()["user_id"] == uid and r.json()["character"]["id"] == char["id"]
    outsider, _ = token_for()
    assert client.post("/internal/auth/session", json={"token": outsider, "world_id": w["id"]}, headers=SERVER).status_code == 403


def result_body(world_id, chars, key=None, outcome="players_win"):
    return {"idempotency_key": key or str(uuid.uuid4()), "world_id": world_id, "outcome": outcome, "rounds": 5,
            "participants": [{"character_id": c, "outcome": "survived"} for c in chars]}


def test_combat_result_commit_is_atomic_and_idempotent(client, pool):
    w, [(a, _), (b, b_id)] = setup_world(client)
    add_member(pool, w["id"], b_id)
    ca = make_char(client, w["id"], a).json()["id"]
    cb = make_char(client, w["id"], b, "B", "mage").json()["id"]
    body = result_body(w["id"], [ca, cb], key="battle-0001")
    first = client.post("/internal/combat-results", json=body, headers=SERVER)
    assert first.status_code == 200 and first.json()["duplicate"] is False
    replay = client.post("/internal/combat-results", json=body, headers=SERVER)
    assert replay.json()["duplicate"] is True and replay.json()["result"]["id"] == first.json()["result"]["id"]
    changed = dict(body, outcome="draw")
    assert client.post("/internal/combat-results", json=changed, headers=SERVER).status_code == 409
    with pool.connection() as c:
        assert c.execute("select count(*) n from combat_result_participants").fetchone()["n"] == 2


def test_failed_commit_leaves_no_partial_outcome(client, pool):
    w, [(a, _), _] = setup_world(client)
    ca = make_char(client, w["id"], a).json()["id"]
    body = result_body(w["id"], [ca, str(uuid.uuid4())], key="battle-bad-1")
    assert client.post("/internal/combat-results", json=body, headers=SERVER).status_code == 422
    with pool.connection() as c:
        assert c.execute("select count(*) n from combat_results").fetchone()["n"] == 0
    good = result_body(w["id"], [ca], key="battle-bad-1")  # the key is free to retry with a corrected payload
    assert client.post("/internal/combat-results", json=good, headers=SERVER).status_code == 200


def test_retired_characters_cannot_receive_results(client):
    w, [(a, _), _] = setup_world(client)
    ca = make_char(client, w["id"], a).json()["id"]
    client.post(f"/characters/{ca}/retire", headers=auth(a))
    assert client.post("/internal/combat-results", json=result_body(w["id"], [ca]), headers=SERVER).status_code == 422


def test_restart_recovery_data_survives_new_connection_pool(client, pool, pg):
    from app.db import make_pool
    w, [(a, _), _] = setup_world(client)
    ca = make_char(client, w["id"], a).json()["id"]
    client.post("/internal/combat-results", json=result_body(w["id"], [ca], key="battle-restart"), headers=SERVER)
    fresh = make_pool(pg.get_uri())  # simulates a service restart
    with fresh.connection() as c:
        assert c.execute("select count(*) n from combat_result_participants where character_id=%s", (ca,)).fetchone()["n"] == 1
    fresh.close()


def test_migrations_are_idempotent(pool):
    from app.db import migrate
    assert migrate(pool) == []


def test_an_escape_result_and_an_escaped_participant_are_stored(client):
    w, [(a, _), _] = setup_world(client)
    ca = make_char(client, w["id"], a).json()["id"]
    body = result_body(w["id"], [ca], outcome="escaped")
    body["participants"][0]["outcome"] = "escaped"
    assert client.post("/internal/combat-results", json=body, headers=SERVER).status_code == 200
