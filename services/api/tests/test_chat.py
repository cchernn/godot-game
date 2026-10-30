"""World chat: in memory, members only, spoken under the character's name, cleaned and rate limited."""
from app import catalog
from app.chat import ChatBoard, clean
from conftest import auth
from test_persistence import add_member, make_char, setup_world


def two_talkers(client, pool):
    w, [(host, _), (other, other_id)] = setup_world(client)
    add_member(pool, w["id"], other_id)
    make_char(client, w["id"], host, "Aldric")
    make_char(client, w["id"], other, "Brenna", cls="hunter")
    return w, host, other


def say(client, w, tok, text):
    return client.post(f"/worlds/{w['id']}/chat", json={"text": text}, headers=auth(tok))


def hear(client, w, tok, after=None):
    q = "" if after is None else f"?after={after}"
    r = client.get(f"/worlds/{w['id']}/chat{q}", headers=auth(tok))
    assert r.status_code == 200, r.text
    return r.json()


def test_clean_makes_one_plain_line_and_cuts_it():
    assert clean("  hello \n\t world  ", 50) == "hello world"
    assert clean("a\x00b\x07c", 50) == "a b c"
    assert clean("   \n ", 50) == ""
    assert clean("abcdefghij", 4) == "abcd"
    assert clean("abc defgh", 4) == "abc"


def test_the_limits_come_from_the_game_balance_file():
    limits = catalog.load()["chat"]
    assert limits["max_length"] > 0 and limits["rate_messages"] > 0 and limits["rate_seconds"] > 0


def test_members_hear_each_other_under_their_character_names(client, pool):
    w, host, other = two_talkers(client, pool)
    first = hear(client, w, other)
    assert first == {"messages": [], "last": 0}, "a first look shows nothing from before"
    r = say(client, w, host, "Well met")
    assert r.status_code == 201 and r.json()["from"] == "Aldric" and r.json()["mine"] is True
    got = hear(client, w, other, after=first["last"])
    assert [(m["from"], m["text"], m["mine"]) for m in got["messages"]] == [("Aldric", "Well met", False)]
    assert hear(client, w, other, after=got["last"])["messages"] == [], "heard once"
    mine = hear(client, w, host, after=0)["messages"]
    assert mine[0]["mine"] is True and "user" not in mine[0], "the sender's id is never sent out"


def test_late_joiners_see_only_what_is_said_after_they_look(client, pool):
    w, host, other = two_talkers(client, pool)
    say(client, w, host, "before")
    seen = hear(client, w, other)
    assert seen["messages"] == [] and seen["last"] == 1
    say(client, w, host, "after")
    assert [m["text"] for m in hear(client, w, other, after=seen["last"])["messages"]] == ["after"]


def test_worlds_do_not_hear_each_other(client, pool):
    w, host, other = two_talkers(client, pool)
    w2, [(tok2, _), _] = setup_world(client)
    make_char(client, w2["id"], tok2, "Elsewhere")
    say(client, w, host, "secret")
    assert hear(client, w2, tok2, after=0)["messages"] == []
    assert client.get(f"/worlds/{w['id']}/chat", headers=auth(tok2)).status_code == 403, "not a member"
    assert say(client, w, tok2, "hi").status_code == 403


def test_a_character_is_needed_to_speak_and_empty_messages_are_refused(client, pool):
    w, [(host, _), (other, other_id)] = setup_world(client)
    make_char(client, w["id"], host, "Aldric")
    add_member(pool, w["id"], other_id)
    assert say(client, w, other, "hi").status_code == 403, "no character yet"
    assert hear(client, w, other)["messages"] == [], "but they may listen"
    assert say(client, w, host, "  \n ").status_code == 422
    long = say(client, w, host, "x" * 500).json()
    assert len(long["text"]) == catalog.load()["chat"]["max_length"]


def test_too_many_messages_in_a_window_are_refused(client, pool):
    w, host, other = two_talkers(client, pool)
    n = catalog.load()["chat"]["rate_messages"]
    for i in range(n):
        assert say(client, w, host, f"m{i}").status_code == 201
    assert say(client, w, host, "one too many").status_code == 429
    assert say(client, w, other, "someone else is not limited by it").status_code == 201


def test_the_board_forgets_old_messages_and_lets_a_sender_speak_again_later():
    t = [0.0]
    board = ChatBoard(max_length=20, rate_messages=2, rate_seconds=10, keep=3, clock=lambda: t[0])
    import uuid
    w, u = uuid.uuid4(), uuid.uuid4()
    board.post(w, u, "A", "one")
    board.post(w, u, "A", "two")
    try:
        board.post(w, u, "A", "three")
        raise AssertionError("limit not enforced")
    except Exception as e:
        assert getattr(e, "status", None) == 429
    t[0] = 11.0
    for text in ("three", "four", "five"):
        board.post(w, u, "A", text)
        t[0] += 6
    assert [m["text"] for m in board.since(w, u, 0)["messages"]] == ["three", "four", "five"], "only the last few are kept"
    board.forget(w)
    assert board.since(w, u, 0) == {"messages": [], "last": 0}
