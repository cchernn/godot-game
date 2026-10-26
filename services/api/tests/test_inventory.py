import uuid

from conftest import SERVER, auth
from test_persistence import make_char, result_body, setup_world


def grant(client, char_id, item="potion", qty=3, max_stack=99):
    return client.post(f"/internal/characters/{char_id}/items", json={"item_id": item, "quantity": qty, "max_stack": max_stack},
                       headers=SERVER)


def carried(client, world_id, tok):
    return {i["item_id"]: i["quantity"] for i in client.get(f"/worlds/{world_id}/characters/me", headers=auth(tok)).json()["items"]}


def one_character(client):
    w, [(tok, _), _] = setup_world(client)
    char = make_char(client, w["id"], tok).json()
    return w, tok, char


def test_a_new_character_carries_nothing_and_grants_stack_up_to_the_limit(client):
    w, tok, char = one_character(client)
    assert carried(client, w["id"], tok) == {}
    assert grant(client, char["id"], qty=3).json()["quantity"] == 3
    assert grant(client, char["id"], qty=4, max_stack=5).json()["quantity"] == 5, "capped at the item's own limit"
    assert carried(client, w["id"], tok) == {"potion": 5}


def test_granting_needs_the_service_key_and_a_real_character(client):
    w, tok, char = one_character(client)
    body = {"item_id": "potion", "quantity": 1}
    assert client.post(f"/internal/characters/{char['id']}/items", json=body, headers=auth(tok)).status_code == 401
    assert client.post(f"/internal/characters/{uuid.uuid4()}/items", json=body, headers=SERVER).status_code == 404
    assert client.post(f"/internal/characters/{char['id']}/items", json={"item_id": "Bad Id", "quantity": 1}, headers=SERVER).status_code == 422


def test_the_session_payload_carries_the_loadout(client):
    w, tok, char = one_character(client)
    grant(client, char["id"], "potion", 2)
    grant(client, char["id"], "bomb", 1)
    r = client.post("/internal/auth/session", json={"token": tok, "world_id": w["id"]}, headers=SERVER).json()
    assert r["character"]["items"] == [{"item_id": "bomb", "quantity": 1}, {"item_id": "potion", "quantity": 2}]


def used_body(world_id, char_id, used, key=None):
    body = result_body(world_id, [char_id], key=key)
    body["participants"][0]["items_used"] = used
    return body


def test_a_result_consumes_the_items_once_and_a_replay_does_not_consume_again(client):
    w, tok, char = one_character(client)
    grant(client, char["id"], "potion", 3)
    body = used_body(w["id"], char["id"], {"potion": 2}, key="battle-items-1")
    assert client.post("/internal/combat-results", json=body, headers=SERVER).status_code == 200
    assert carried(client, w["id"], tok) == {"potion": 1}
    replay = client.post("/internal/combat-results", json=body, headers=SERVER)
    assert replay.status_code == 200 and replay.json()["duplicate"]
    assert carried(client, w["id"], tok) == {"potion": 1}
    changed = used_body(w["id"], char["id"], {"potion": 1}, key="battle-items-1")
    assert client.post("/internal/combat-results", json=changed, headers=SERVER).status_code == 409


def test_using_up_the_last_copy_removes_the_row(client):
    w, tok, char = one_character(client)
    grant(client, char["id"], "potion", 1)
    assert client.post("/internal/combat-results", json=used_body(w["id"], char["id"], {"potion": 1}), headers=SERVER).status_code == 200
    assert carried(client, w["id"], tok) == {}


def test_using_more_than_carried_refuses_the_whole_result(client, pool):
    w, tok, char = one_character(client)
    grant(client, char["id"], "potion", 1)
    r = client.post("/internal/combat-results", json=used_body(w["id"], char["id"], {"potion": 2}), headers=SERVER)
    assert r.status_code == 422
    assert carried(client, w["id"], tok) == {"potion": 1}
    with pool.connection() as c:
        assert c.execute("select count(*) n from combat_results").fetchone()["n"] == 0
    assert client.post("/internal/combat-results", json=used_body(w["id"], char["id"], {"bomb": 1}), headers=SERVER).status_code == 422


def test_a_result_with_no_items_used_still_works(client):
    w, tok, char = one_character(client)
    assert client.post("/internal/combat-results", json=result_body(w["id"], [char["id"]]), headers=SERVER).status_code == 200


def allocate(client, char_id, allocated):
    return client.put(f"/internal/characters/{char_id}/allocation", json={"allocated": allocated}, headers=SERVER)


def test_a_character_starts_with_no_points_and_the_service_key_sets_them(client):
    w, tok, char = one_character(client)
    me = lambda: client.get(f"/worlds/{w['id']}/characters/me", headers=auth(tok)).json()
    assert me()["allocated"] == {} and me()["level"] == 1
    r = allocate(client, char["id"], {"might": 2, "agility": 1, "vitality": 0})
    assert r.status_code == 200 and r.json()["allocated"] == {"might": 2, "agility": 1}, "zeros are dropped"
    assert me()["allocated"] == {"might": 2, "agility": 1}
    assert allocate(client, char["id"], {}).json()["allocated"] == {}


def test_allocation_is_checked_for_shape_key_and_a_real_character(client):
    w, tok, char = one_character(client)
    assert client.put(f"/internal/characters/{char['id']}/allocation", json={"allocated": {"might": 1}}, headers=auth(tok)).status_code == 401
    assert allocate(client, uuid.uuid4(), {"might": 1}).status_code == 404
    for bad in ({"luck": 1}, {"might": -1}, {"might": 100}, {"might": "x"}):
        assert allocate(client, char["id"], bad).status_code == 422, bad



def test_learned_skills_and_flags_are_set_with_the_service_key_and_carried(client):
    w, tok, char = one_character(client)
    me = lambda: client.get(f"/worlds/{w['id']}/characters/me", headers=auth(tok)).json()
    assert me()["learned_skills"] == [] and me()["flags"] == []
    put = lambda body: client.put(f"/internal/characters/{char['id']}/learned-skills", json=body, headers=SERVER)
    assert put({"learned": ["bolt", "bolt", "heal_2"]}).json()["learned_skills"] == ["bolt", "heal_2"], "duplicates dropped"
    flag = lambda body: client.post(f"/internal/characters/{char['id']}/flags", json=body, headers=SERVER)
    assert flag({"add": ["met_hermit", "met_hermit"]}).json()["flags"] == ["met_hermit"]
    assert flag({"add": ["slain_ghoul"]}).json()["flags"] == ["met_hermit", "slain_ghoul"]
    assert flag({"remove": ["met_hermit"], "add": ["x"]}).json()["flags"] == ["slain_ghoul", "x"]
    assert (me()["learned_skills"], me()["flags"]) == (["bolt", "heal_2"], ["slain_ghoul", "x"])


def test_learned_skills_and_flags_are_checked(client):
    w, tok, char = one_character(client)
    base = f"/internal/characters/{char['id']}"
    assert client.put(f"{base}/learned-skills", json={"learned": []}, headers=auth(tok)).status_code == 401
    assert client.post(f"{base}/flags", json={"add": ["a"]}, headers=auth(tok)).status_code == 401
    assert client.put(f"/internal/characters/{uuid.uuid4()}/learned-skills", json={"learned": []}, headers=SERVER).status_code == 404
    assert client.post(f"/internal/characters/{uuid.uuid4()}/flags", json={"add": ["a"]}, headers=SERVER).status_code == 404
    for bad in ({"learned": ["Bad Id"]}, {"learned": [""]}, {"learned": "bolt"}):
        assert client.put(f"{base}/learned-skills", json=bad, headers=SERVER).status_code == 422, bad
    for bad in ({"add": ["Has Space"]}, {"remove": [3]}):
        assert client.post(f"{base}/flags", json=bad, headers=SERVER).status_code == 422, bad
