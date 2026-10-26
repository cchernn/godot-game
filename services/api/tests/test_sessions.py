import time

from conftest import SERVER, auth, token_for


def _login(uid, sid):
    t, _ = token_for(uid, session_id=sid)
    return auth(t)


def test_second_login_is_refused_while_the_first_is_live(client):
    a = _login("11111111-1111-1111-1111-111111111111", "sess-a")
    b = _login("11111111-1111-1111-1111-111111111111", "sess-b")
    assert client.post("/me/session", headers=a).status_code == 204
    r = client.post("/me/session", headers=b)
    assert r.status_code == 423 and "another device" in r.json()["detail"]
    assert client.get("/worlds", headers=b).status_code == 423  # every call is refused, not only the claim
    assert client.get("/worlds", headers=a).status_code == 200  # the holder is untouched


def test_the_same_login_can_come_back(client):
    a = _login("22222222-2222-2222-2222-222222222222", "sess-a")
    assert client.post("/me/session", headers=a).status_code == 204
    assert client.post("/me/session", headers=a).status_code == 204


def test_other_accounts_are_independent(client):
    assert client.post("/me/session", headers=_login("33333333-3333-3333-3333-333333333333", "s")).status_code == 204
    assert client.post("/me/session", headers=_login("44444444-4444-4444-4444-444444444444", "s")).status_code == 204


def test_a_login_not_heard_from_can_be_replaced(pool, client):
    uid = "55555555-5555-5555-5555-555555555555"
    assert client.post("/me/session", headers=_login(uid, "old")).status_code == 204
    with pool.connection() as c:
        c.execute("update player_sessions set last_seen_at = now() - interval '5 minutes'")
    assert client.post("/me/session", headers=_login(uid, "new")).status_code == 204
    assert client.post("/me/session", headers=_login(uid, "old")).status_code == 423


def test_sign_out_frees_the_account_but_only_for_the_holder(client):
    uid = "66666666-6666-6666-6666-666666666666"
    a, b = _login(uid, "a"), _login(uid, "b")
    client.post("/me/session", headers=a)
    assert client.post("/me/session/release", headers=b).status_code == 204  # the refused login cannot release it
    assert client.post("/me/session", headers=b).status_code == 423
    assert client.post("/me/session/release", headers=a).status_code == 204
    assert client.post("/me/session", headers=b).status_code == 204


def test_tokens_without_a_session_are_not_tracked(client):
    t, _ = token_for("77777777-7777-7777-7777-777777777777")  # guest-style, no session_id claim
    assert client.post("/me/session", headers=auth(t)).status_code == 204


def test_the_battle_server_is_refused_for_a_second_login(client):
    uid = "88888888-8888-8888-8888-888888888888"
    a, _ = token_for(uid, session_id="a")
    b, _ = token_for(uid, session_id="b")
    client.post("/me/session", headers=auth(a))
    w = client.post("/worlds", headers=auth(a), json={"name": "W"}).json()
    ok = client.post("/internal/auth/session", headers=SERVER, json={"token": a, "world_id": w["id"]})
    assert ok.status_code == 200
    bad = client.post("/internal/auth/session", headers=SERVER, json={"token": b, "world_id": w["id"]})
    assert bad.status_code == 423
