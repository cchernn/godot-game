"""Drives the deployed web client in headless Chromium (one browser per player) and saves screenshots to /out.
The UI is drawn on a canvas, so interaction is by coordinates; screenshots show each screen.
Env: HOST_EMAIL/HOST_PASSWORD (existing host account), TESTER_EMAIL/TESTER_PASSWORD (signs up in the page),
STAGE (party | pending | reset | session | tour), URL, CLICKS (tour: "x,y,label;x,y,label"),
ESCAPE_XY (party: "x,y;x,y" where the Escape button can be (planning, resolving); the tester presses it twice mid-battle), PROBE=request|return|1 (party: stop after the request arrives / the Party window after a reload / at the battle screen)."""
import os, time
from playwright.sync_api import sync_playwright

OUT = "/out"
W, H = 1280, 720
# The game view (1280x720): the dock along the bottom opens windows over the map
DOCK_ACTIVITY, DOCK_PARTY, DOCK_CHARACTER, DOCK_MENU = (485, 688), (585, 688), (685, 688), (785, 688)
OTHERS = (950, 360)    # first row of "Other parties here" in the Party window
ASK = (1050, 442)      # Ask to join
APPROVE = (1130, 347)  # Approve on the first join request (Party window)
RETURN = (1050, 286)   # Return to battle in the Party window
ACTIVITY = (830, 171)  # first activity in the Activity window
START = (995, 275)     # Start the selected activity
ATTACK_BTN, SKILLS_BTN = (1090, 93), (1209, 93)   # battle action bar (side panel, top right)
URL = os.environ.get("URL", "http://localhost:8080")
STAGE = os.environ.get("STAGE", "party")
LOGS = []


class Player:
    def __init__(self, browser, name):
        self.name = name
        self.page = browser.new_context(viewport={"width": W, "height": H}).new_page()
        self.page.on("console", lambda m: LOGS.append(f"[{name}][{m.type}] {m.text}"))
        self.page.on("pageerror", lambda e: LOGS.append(f"[{name}][pageerror] {e}"))
        self.page.goto(URL)
        time.sleep(float(os.environ.get("WAIT", "18")))

    def click(self, x, y, wait=0.4):
        self.page.mouse.click(x, y)
        time.sleep(wait)

    def type(self, text):
        self.page.keyboard.type(text, delay=90)   # the software-rendered page has a low frame rate: fast typing drops keys

    def shot(self, name):
        self.page.screenshot(path=f"{OUT}/{self.name}_{name}.png")

    def sign_in(self, email, password, create=False):
        self.click(640, 315)
        self.type(email)
        self.click(640, 356)
        self.type(password)
        self.click(640, 439 if create else 398, wait=7)


def state(player, want, timeout=120):
    """Waits until the client reports a screen (window.unnamedState); on failure saves a screenshot and the console."""
    try:
        player.page.wait_for_function(f"window.unnamedState === '{want}'", timeout=timeout * 1000)
    except Exception:
        player.shot(f"FAILED_waiting_for_{want}")
        with open(f"{OUT}/console.log", "w") as f:
            f.write("\n".join(LOGS) + f"\nstate={player.page.evaluate('window.unnamedState')}")
        raise


def main() -> None:
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist",
                                    "--enable-webgl", "--no-sandbox"])
        try:
            if STAGE == "party":
                party_flow(b)
            elif STAGE == "pending":
                pending_flow(b)
            elif STAGE == "reset":
                reset_flow(b)
            elif STAGE == "session":
                session_flow(b)
            elif STAGE == "tour":
                tour(b)
            else:
                raise SystemExit(f"unknown STAGE {STAGE!r} (party | pending | reset | session | tour)")
        finally:
            with open(f"{OUT}/console.log", "w") as f:
                f.write("\n".join(LOGS))
            print("\n".join(l for l in LOGS if "pageerror" in l)[:1500])
            b.close()


def tour(b):
    """The host signs in, opens Test World and clicks through CLICKS ("x,y,label;..."), with a screenshot after each.
    For looking at screens without a scripted flow; the first two clicks should pick the world."""
    host = Player(b, "host")
    host.sign_in(os.environ["HOST_EMAIL"], os.environ["HOST_PASSWORD"])
    host.shot("00_worlds")
    for i, step in enumerate(filter(None, os.environ.get("CLICKS", "").split(";")), 1):
        x, y, label = step.split(",")
        host.click(int(x), int(y), wait=3)
        host.shot(f"{i:02d}_{label}")


def open_world(player, wait=6):
    """From the world picker to the game view (the map), where the party lives."""
    player.click(640, 238, wait=1)            # "Test World"
    player.click(640, 353, wait=wait)         # Open selected world


def party_flow(b):
    """The host (a party of one at Hollowmere) and the tester meet on the map: the tester asks the host's party to let
    them in (Party window), the host approves and starts an activity (Activity window), the tester is taken into the
    battle by itself, drops out and comes back (Party window > Return to battle), and both play to the result and return
    to the map. Needs both accounts to be members of the world with a character each, both parties idle at the same place
    (tests/browser/parties.py lists them)."""
    host = Player(b, "host")
    tester = Player(b, "tester")
    host.sign_in(os.environ["HOST_EMAIL"], os.environ["HOST_PASSWORD"])
    open_world(host)
    host.click(*DOCK_PARTY, wait=2)
    host.shot("01_game_alone")
    tester.sign_in(os.environ["TESTER_EMAIL"], os.environ["TESTER_PASSWORD"])
    open_world(tester)
    tester.click(*DOCK_PARTY, wait=2)
    tester.shot("01_game")
    tester.click(*OTHERS, wait=1)             # the host's party in "Other parties here"
    tester.click(*ASK, wait=3)                # Ask to join
    tester.shot("02_requested")
    time.sleep(5)
    host.shot("03_request_arrived")
    if os.environ.get("PROBE") == "request":
        return
    host.click(*APPROVE, wait=3)              # Approve
    host.shot("04_party_of_two")
    time.sleep(6)                             # the tester's map notices on its own
    tester.shot("03_in_the_party")
    host.click(*DOCK_PARTY, wait=1)           # close the Party window, open Activity
    host.click(*DOCK_ACTIVITY, wait=1)
    host.click(*ACTIVITY, wait=1)             # Training skirmish
    host.shot("04b_activity_picked")
    host.click(*START, wait=2)                # Start
    state(host, "battle", 90)                 # (the gather lobby can be over before a screen can see it)
    state(tester, "battle", 90)
    host.shot("05_battle")
    host.click(*ATTACK_BTN, wait=1)           # the Attack submenu (basic attacks), then the Skills submenu (class skills)
    host.shot("05a_attack_menu")
    host.click(*SKILLS_BTN, wait=1)
    host.shot("05b_skills_menu")
    host.click(*SKILLS_BTN, wait=1)           # close it again: the Ready button moves while a submenu is open
    tester.page.reload()                      # the tester's tab dies mid-battle...
    time.sleep(float(os.environ.get("WAIT", "18")))
    tester.shot("04_after_reload")
    open_world(tester, wait=6)                # ...they sign back in (the session is restored) and pick the world
    tester.click(*DOCK_PARTY, wait=3)
    tester.shot("05_party_with_battle")
    if os.environ.get("PROBE") == "return":
        return
    tester.click(*RETURN, wait=1)             # Return to battle
    state(tester, "battle", 60)
    tester.shot("06_back_in_battle")
    if os.environ.get("PROBE"):                # only look at the battle screen, to find click positions
        host.shot("06_probe")
        return
    if os.environ.get("ESCAPE_XY"):           # the tester leaves the fight (two presses) and watches
        spots = [tuple(map(int, xy.split(","))) for xy in os.environ["ESCAPE_XY"].split(";")]
        for press in (1, 2):                  # the button sits further right while resolving, so every press tries each spot
            for x, y in spots:
                tester.click(x, y, wait=0.5)
            tester.shot(f"06{'bc'[press - 1]}_escape_press_{press}")
        time.sleep(4)
        tester.shot("06d_escaped_spectating")
        host.shot("06e_host_sees_escape")
    deadline = time.time() + 720
    while time.time() < deadline:
        if host.page.evaluate("window.unnamedState") == "result" and tester.page.evaluate("window.unnamedState") == "result":
            break
        for pl in (host, tester):
            if pl.page.evaluate("window.unnamedState") == "battle":
                pl.click(1043, 421, wait=0)   # Ready
        time.sleep(3)
    state(host, "result", 5)
    state(tester, "result", 5)
    time.sleep(2)
    host.shot("08_result")
    host.click(440, 445, wait=4)              # Continue
    tester.click(440, 445, wait=4)
    host.shot("09_game_after")
    tester.shot("07_game_after")
    state(host, "menu", 10)


def reset_flow(b):
    """The tester opens the world after being away longer than the presence window while in the host's party: the hub
    should show a party of one (the party was reset), and the host's party should be without them.
    Needs the tester to be a member of the host's party and both to have been offline for a minute (tests/browser/parties.py)."""
    tester = Player(b, "tester")
    tester.sign_in(os.environ["TESTER_EMAIL"], os.environ["TESTER_PASSWORD"])
    open_world(tester, wait=6)
    tester.click(*DOCK_PARTY, wait=3)
    tester.shot("01_party_after_the_gap")


def session_flow(b):
    """One login per account: a second browser signing in with the same credentials is refused and the first carries on."""
    first = Player(b, "first")
    first.sign_in(os.environ["TESTER_EMAIL"], os.environ["TESTER_PASSWORD"])
    time.sleep(2)
    first.shot("01_signed_in")
    second = Player(b, "second")
    second.sign_in(os.environ["TESTER_EMAIL"], os.environ["TESTER_PASSWORD"])
    second.shot("02_second_refused")
    time.sleep(12)                            # past a heartbeat of the first: it must still be signed in
    first.shot("03_first_still_in")


def pending_flow(b):
    """The tester opens a world where their join request is still pending: the join screen polls and can go back."""
    tester = Player(b, "tester")
    tester.sign_in(os.environ["TESTER_EMAIL"], os.environ["TESTER_PASSWORD"])
    tester.shot("01_picker")
    tester.click(640, 282, wait=1)            # second row: the world with the pending request
    tester.click(640, 368, wait=4)            # Open selected world
    tester.shot("02_pending")
    tester.click(640, 391, wait=3)            # Choose another world
    tester.shot("03_back_on_picker")


main()
