"""Drives the deployed web client in headless Chromium (one browser per player) and saves screenshots to /out.
The UI is drawn on a canvas, so interaction is by coordinates; screenshots show each screen.
Env: HOST_EMAIL/HOST_PASSWORD (existing host account), TESTER_EMAIL/TESTER_PASSWORD (signs up in the page),
STAGE (party | pending), URL."""
import os, time
from playwright.sync_api import sync_playwright

OUT = "/out"
W, H = 1280, 720
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
            else:
                raise SystemExit(f"unknown STAGE {STAGE!r} (party | pending)")
        finally:
            with open(f"{OUT}/console.log", "w") as f:
                f.write("\n".join(LOGS))
            print("\n".join(l for l in LOGS if "pageerror" in l)[:1500])
            b.close()


def party_flow(b):
    """Host starts a party; the tester asks to join; the host lets them in and starts; the tester drops out and
    comes back to the battle; both play to the result and return to the hub. Needs no live parties to start with
    (tests/browser/parties.py lists them)."""
    host = Player(b, "host")
    tester = Player(b, "tester")
    host.sign_in(os.environ["HOST_EMAIL"], os.environ["HOST_PASSWORD"])
    host.click(640, 268, wait=1)              # "Test World" (second row for the host)
    host.click(640, 353, wait=4)              # Open selected world
    host.shot("01_hub")
    host.click(640, 306, wait=3)              # Parties
    host.shot("02_parties_empty")
    host.click(640, 427, wait=3)              # Start a party
    host.shot("03_create_party")
    host.click(640, 300, wait=1)              # first activity (Training skirmish)
    host.click(640, 415, wait=3)              # Start party
    host.shot("04_party_lobby_alone")
    tester.sign_in(os.environ["TESTER_EMAIL"], os.environ["TESTER_PASSWORD"])
    tester.click(640, 252, wait=1)            # "Test World" (joined worlds sort first)
    tester.click(640, 368, wait=4)            # Open selected world
    tester.shot("01_hub")
    tester.click(640, 326, wait=3)            # Parties
    tester.click(640, 248, wait=1)            # the party
    tester.click(640, 385, wait=3)            # Request to join
    tester.shot("02_requested")
    time.sleep(5)
    host.shot("05_lobby_with_request")
    host.click(806, 401, wait=3)              # Approve
    host.shot("06_lobby_two")
    time.sleep(6)                             # the tester's parties list notices on its own
    tester.shot("03_party_lobby")
    host.click(640, 424, wait=1)              # Start battle
    state(host, "lobby", 40)
    state(tester, "lobby", 40)
    state(host, "battle", 60)
    state(tester, "battle", 60)
    host.shot("07_battle")
    tester.page.reload()                      # the tester's tab dies mid-battle...
    time.sleep(float(os.environ.get("WAIT", "18")))
    tester.shot("04_after_reload")
    tester.click(640, 252, wait=1)            # ...they sign back in (the session is restored) and pick the world
    tester.click(640, 368, wait=4)
    tester.shot("05_hub_with_battle")
    tester.click(640, 306, wait=1)            # Return to battle
    state(tester, "battle", 60)
    tester.shot("06_back_in_battle")
    deadline = time.time() + 300
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
