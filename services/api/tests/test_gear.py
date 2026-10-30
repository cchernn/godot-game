"""Gear and the bag: starting gear, equipping, discarding, the battle's consumable choice, drops and rewards."""
import json
import uuid

from app import catalog, rules
from conftest import SERVER, auth
from test_inventory import carried, grant
from test_persistence import make_char, result_body, setup_world
from test_world import new_party, party


def one(client, cls="warrior"):
    w, [(tok, _), _] = setup_world(client)
    return w, tok, make_char(client, w["id"], tok, cls=cls).json()


def inv(client, tok, char):
    r = client.get(f"/characters/{char['id']}/inventory", headers=auth(tok))
    assert r.status_code == 200, r.text
    return r.json()


def worn(i):
    return {g["place"]: g["gear_id"] for g in i["gear"] if g["place"]}


def bag(i):
    return sorted(g["gear_id"] for g in i["gear"] if not g["place"])


def give_gear(client, char, gear_id):
    r = client.post(f"/internal/characters/{char['id']}/gear", json={"gear_id": gear_id}, headers=SERVER)
    assert r.status_code == 200, r.text
    return r.json()


def piece(i, gear_id, nth=0):
    return [g for g in i["gear"] if g["gear_id"] == gear_id][nth]["id"]


def equip(client, tok, char, row, place):
    return client.post(f"/characters/{char['id']}/gear/{row}/equip", json={"place": place}, headers=auth(tok))


def test_the_catalog_matches_the_api_classes():
    assert set(catalog.load()["classes"]) == set(rules.CLASSES)
    for cls in rules.CLASSES:
        for g in catalog.starting_gear(cls):
            assert catalog.gear_kind(g) is not None, g


def test_a_character_starts_wearing_its_classes_gear_in_the_right_places(client):
    w, tok, c = one(client)
    i = inv(client, tok, c)
    assert worn(i) == {"weapon_1": "iron_longsword", "weapon_2": "wooden_shield", "armor": "iron_chainmail"}
    assert bag(i) == []
    assert inv(client, tok, c)["gear"] == i["gear"], "starting gear is given once, not on every look"
    me = client.get(f"/worlds/{w['id']}/characters/me", headers=auth(tok)).json()
    assert me["gear"] == i["gear"], "the character carries its gear"
    s = client.post("/internal/auth/session", json={"token": tok, "world_id": w["id"]}, headers=SERVER).json()
    assert s["character"]["gear"] == i["gear"]
    w2, tok2, mage = one(client, "mage")
    assert worn(inv(client, tok2, mage)) == {"weapon_1": "wooden_staff", "armor": "garb"}


def test_equipping_puts_what_was_there_in_the_bag(client):
    w, tok, c = one(client)
    give_gear(client, c, "iron_dagger")
    i = inv(client, tok, c)
    assert bag(i) == ["iron_dagger"]
    r = equip(client, tok, c, piece(i, "iron_dagger"), "weapon_1")
    assert r.status_code == 200, r.text
    assert worn(r.json()) == {"weapon_1": "iron_dagger", "weapon_2": "wooden_shield", "armor": "iron_chainmail"}
    assert bag(r.json()) == ["iron_longsword"]


def test_moving_a_weapon_to_the_other_hand_swaps_them(client):
    w, tok, c = one(client)
    i = inv(client, tok, c)
    r = equip(client, tok, c, piece(i, "iron_longsword"), "weapon_2")
    assert worn(r.json())["weapon_2"] == "iron_longsword" and worn(r.json())["weapon_1"] == "wooden_shield"
    assert bag(r.json()) == []


def test_gear_only_goes_where_it_fits_and_places_must_exist(client):
    w, tok, c = one(client)
    i = inv(client, tok, c)
    assert equip(client, tok, c, piece(i, "iron_longsword"), "armor").status_code == 422
    assert equip(client, tok, c, piece(i, "iron_chainmail"), "weapon_1").status_code == 422
    assert equip(client, tok, c, piece(i, "iron_longsword"), "head").status_code == 422, "not a place"
    assert equip(client, tok, c, str(uuid.uuid4()), "weapon_1").status_code == 404


def test_unequipping_and_discarding(client):
    w, tok, c = one(client)
    i = inv(client, tok, c)
    sword = piece(i, "iron_longsword")
    assert client.post(f"/characters/{c['id']}/gear/{sword}/discard", headers=auth(tok)).status_code == 409, "take it off first"
    r = client.post(f"/characters/{c['id']}/gear/{sword}/unequip", headers=auth(tok))
    assert bag(r.json()) == ["iron_longsword"] and "weapon_1" not in worn(r.json())
    r = client.post(f"/characters/{c['id']}/gear/{sword}/discard", headers=auth(tok))
    assert r.status_code == 200 and bag(r.json()) == []


def test_two_copies_of_the_same_gear_are_separate_pieces(client):
    w, tok, c = one(client)
    give_gear(client, c, "iron_longsword")
    i = give_gear(client, c, "iron_longsword")
    assert len({g["id"] for g in i["gear"] if g["gear_id"] == "iron_longsword"}) == 3


def test_nobody_else_can_touch_your_gear(client, pool):
    w, tok, c = one(client)
    stranger, _ = setup_world(client)[1][0]
    i = inv(client, tok, c)
    sword = piece(i, "iron_longsword")
    assert client.get(f"/characters/{c['id']}/inventory", headers=auth(stranger)).status_code == 404
    assert client.post(f"/characters/{c['id']}/gear/{sword}/unequip", headers=auth(stranger)).status_code == 404
    assert client.post(f"/internal/characters/{c['id']}/gear", json={"gear_id": "bow"}, headers=auth(tok)).status_code == 401
    assert client.post(f"/internal/characters/{c['id']}/gear", json={"gear_id": "no_such_gear"}, headers=SERVER).status_code == 422


def test_gear_is_locked_while_an_activity_runs(client, pool):
    w, toks, [c1, c2] = party(client, pool)
    new_party(client, w["id"], toks[0])
    i = inv(client, toks[0], c1)
    assert i["locked"]
    sword = piece(i, "iron_longsword")
    assert client.post(f"/characters/{c1['id']}/gear/{sword}/unequip", headers=auth(toks[0])).status_code == 409
    grant(client, c1["id"], "potion", 1)
    assert client.put(f"/characters/{c1['id']}/battle-items", json={"items": ["potion"]}, headers=auth(toks[0])).status_code == 409


def test_choosing_which_consumables_go_into_a_battle(client):
    w, tok, c = one(client)
    for k in ["potion", "bomb", "salve"]:
        grant(client, c["id"], k, 2)
    assert inv(client, tok, c)["battle_items"] is None, "automatic until chosen"
    put = lambda items: client.put(f"/characters/{c['id']}/battle-items", json={"items": items}, headers=auth(tok))
    assert put(["salve", "potion"]).json()["battle_items"] == ["salve", "potion"]
    assert put(["potion", "potion"]).status_code == 422, "once each"
    assert put(["nothing"]).status_code == 422, "only what you hold"
    assert put(["a", "b", "c", "d", "e"]).status_code == 422, "at most the battle's slots"
    s = client.post("/internal/auth/session", json={"token": tok, "world_id": w["id"]}, headers=SERVER).json()
    assert s["character"]["battle_items"] == ["salve", "potion"]
    assert put(None).json()["battle_items"] is None


def test_discarding_consumables(client):
    w, tok, c = one(client)
    grant(client, c["id"], "potion", 3)
    client.put(f"/characters/{c['id']}/battle-items", json={"items": ["potion"]}, headers=auth(tok))
    d = lambda n: client.post(f"/characters/{c['id']}/items/potion/discard", json={"quantity": n}, headers=auth(tok))
    assert d(4).status_code == 422
    assert d(1).json()["items"] == [{"item_id": "potion", "quantity": 2}]
    r = d(2).json()
    assert r["items"] == [] and r["battle_items"] == [], "a kind you no longer hold drops out of the choice"


def loot_body(w, c, loot, outcome="players_win", key=None, fate="survived"):
    body = result_body(w["id"], [c["id"]], key=key, outcome=outcome)
    body["participants"][0]["loot"] = loot
    body["participants"][0]["outcome"] = fate
    return body


def test_drops_go_into_the_bag_once_and_only_on_a_win(client):
    w, tok, c = one(client)
    body = loot_body(w, c, {"gear": ["bow"], "items": {"potion": 2}}, key="drop-key-1")
    r = client.post("/internal/combat-results", json=body, headers=SERVER)
    assert r.status_code == 200, r.text
    assert r.json()["rewards"][c["id"]]["gear"] == ["bow"] and r.json()["rewards"][c["id"]]["items"] == {"potion": 2}
    assert bag(inv(client, tok, c)) == ["bow"] and carried(client, w["id"], tok) == {"potion": 2}
    client.post("/internal/combat-results", json=body, headers=SERVER)
    assert bag(inv(client, tok, c)) == ["bow"], "a replay drops nothing more"
    lost = loot_body(w, c, {"gear": ["bow"]}, outcome="players_lose", key="drop-key-2", fate="downed")
    assert client.post("/internal/combat-results", json=lost, headers=SERVER).status_code == 200
    assert bag(inv(client, tok, c)) == ["bow"], "no drops from a loss"
    gone = loot_body(w, c, {"gear": ["bow"]}, key="drop-key-3", fate="escaped")
    client.post("/internal/combat-results", json=gone, headers=SERVER)
    assert bag(inv(client, tok, c)) == ["bow"], "nor for someone who left"


def test_an_unknown_piece_of_gear_refuses_the_whole_result(client):
    w, tok, c = one(client)
    body = loot_body(w, c, {"gear": ["no_such_gear"]}, key="drop-key-bad")
    assert client.post("/internal/combat-results", json=body, headers=SERVER).status_code == 422
    assert bag(inv(client, tok, c)) == []


def test_the_templates_gear_rewards_are_checked_against_the_catalog():
    from app.templates import TemplateError, _check_rewards
    _check_rewards("x", {"gear": ["bow"]}, {}, {})
    try:
        _check_rewards("x", {"gear": ["moon_blade"]}, {}, {})
    except TemplateError as e:
        assert "moon_blade" in str(e)
    else:
        raise AssertionError("an unknown gear reward was accepted")


def test_the_catalog_file_is_valid_json_with_every_class(client):
    d = json.loads(catalog.FILE.read_text())
    assert d["worn_places"] == ["weapon_1", "weapon_2", "armor", "accessory"]
