"""Drives the deployed web client in headless Chromium (one browser per player) and saves screenshots to /out.
The UI is drawn on a canvas, so interaction is by coordinates; screenshots show each screen.
Env: HOST_EMAIL/HOST_PASSWORD (existing host account), TESTER_EMAIL/TESTER_PASSWORD (signs up in the page),
STAGE (party | pending | reset | tour), URL, CLICKS (tour: "x,y,label;x,y,label"),
ESCAPE_XY (party: "x,y;x,y" where the Escape button can be (planning, resolving); the tester presses it twice mid-battle), PROBE=1 (party: stop at the battle screen)."""
import os, time
from playwright.sync_api import sync_playwright

OUT = "/out"
W, H = 1280, 720
# Overworld side panel, with a party of one at Hollowmere (set from the screenshots in tests/browser/README.md)
OTHERS = (950, 513)    # first row of "Other parties here"
ASK = (950, 585)       # Ask to join
APPROVE = (1020, 299)  # Approve on the first join request
ACTIVITY = (950, 394)  # first activity at the party's place
START = (950, 477)     # Start the selected activity
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
            elif STAGE == "tour":
                tour(b)
            else:
                raise SystemExit(f"unknown STAGE {STAGE!r} (party | pending | reset | tour)")
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


def party_flow(b):
    """The host (a party of one at Hollowmere) and the tester meet on the overworld: the tester asks the host's party to
    let them in, the host approves and starts an activity, the tester is taken into the battle by itself, drops out and
    comes back, and both play to the result and return to the hub. Needs both accounts to be members of the world with
    a character each, both parties idle at the same place (tests/browser/parties.py lists them)."""
    host = Player(b, "host")
    tester = Player(b, "tester")
    host.sign_in(os.environ["HOST_EMAIL"], os.environ["HOST_PASSWORD"])
    host.click(640, 238, wait=1)              # "Test World" (the host's only world)
    host.click(640, 353, wait=4)              # Open selected world
    host.shot("01_hub")
    host.click(640, 327, wait=3)              # Overworld
    host.shot("02_overworld_alone")
    tester.sign_in(os.environ["TESTER_EMAIL"], os.environ["TESTER_PASSWORD"])
    tester.click(640, 238, wait=1)            # "Test World"
    tester.click(640, 353, wait=4)            # Open selected world
    tester.click(640, 348, wait=3)            # Overworld (no World management button for a member, so a row lower)
    tester.shot("01_overworld")
    tester.click(OTHERS[0], OTHERS[1], wait=1)    # the host's party in "Other parties here"
    tester.click(ASK[0], ASK[1], wait=3)          # Ask to join
    tester.shot("02_requested")
    time.sleep(5)
    host.shot("03_request_arrived")
    host.click(APPROVE[0], APPROVE[1], wait=3)    # Approve
    host.shot("04_party_of_two")
    time.sleep(6)                             # the tester's overworld notices on its own
    tester.shot("03_in_the_party")
    host.click(ACTIVITY[0], ACTIVITY[1], wait=1)  # Training skirmish
    host.click(START[0], START[1], wait=2)        # Start
    state(host, "battle", 90)                 # (the gather lobby can be over before a screen can see it)
    state(tester, "battle", 90)
    host.shot("05_battle")
    tester.page.reload()                      # the tester's tab dies mid-battle...
    time.sleep(float(os.environ.get("WAIT", "18")))
    tester.shot("04_after_reload")
    tester.click(640, 238, wait=1)            # ...they sign back in (the session is restored) and pick the world
    tester.click(640, 353, wait=9)            # (the hub fills in the party line a moment after it opens)
    tester.shot("05_hub_with_battle")
    tester.click(640, 327, wait=1)            # Return to battle
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
    host.shot("09_hub_after")
    tester.shot("07_hub_after")
    state(host, "menu", 10)


def reset_flow(b):
    """The tester opens the world after being away longer than the presence window while in the host's party: the hub
    should show a party of one (the party was reset), and the host's party should be without them.
    Needs the tester to be a member of the host's party and both to have been offline for a minute (tests/browser/parties.py)."""
    tester = Player(b, "tester")
    tester.sign_in(os.environ["TESTER_EMAIL"], os.environ["TESTER_PASSWORD"])
    tester.click(640, 238, wait=1)            # "Test World"
    tester.click(640, 353, wait=9)            # Open selected world (the hub fills in the party line a moment later)
    tester.shot("01_hub_after_the_gap")


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
