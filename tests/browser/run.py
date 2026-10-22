"""Drives the deployed web client in headless Chromium (one browser per player) and saves screenshots to /out.
The UI is drawn on a canvas, so interaction is by coordinates; screenshots show each screen.
Env: HOST_EMAIL/HOST_PASSWORD (existing host account), TESTER_EMAIL/TESTER_PASSWORD (signs up in the page),
STAGE (how far to run), URL."""
import os, time
from playwright.sync_api import sync_playwright

OUT = "/out"
W, H = 1280, 720
URL = os.environ.get("URL", "http://localhost:8080")
STAGE = os.environ.get("STAGE", "signup")
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


def open_first_world(player):
    player.click(640, 238, wait=1)    # the first world in the picker
    player.click(640, 353, wait=4)    # Open selected world


def main() -> None:
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist",
                                    "--enable-webgl", "--no-sandbox"])
        try:
            if STAGE == "duo":
                duo_flow(b)
            elif STAGE == "char":
                char_flow(b)
            elif STAGE.startswith("join"):
                join_flow(b)
            else:
                solo_flow(b)
        finally:
            with open(f"{OUT}/console.log", "w") as f:
                f.write("\n".join(LOGS))
            print("\n".join(l for l in LOGS if "pageerror" in l)[:1500])
            b.close()


def join_flow(b):
    """A tester who is not in the world asks to join; the host approves; the tester makes a character."""
    tester = Player(b, "tester")
    tester.sign_in(os.environ["TESTER_EMAIL"], os.environ["TESTER_PASSWORD"])
    tester.shot("01_picker")
    tester.click(640, 282, wait=1)            # "Test World" (second row)
    tester.click(640, 368, wait=4)            # Open selected world
    tester.shot("02_join_screen")
    tester.click(640, 330, wait=3)            # Request to join
    tester.shot("03_request_pending")
    host = Player(b, "host")
    host.sign_in(os.environ["HOST_EMAIL"], os.environ["HOST_PASSWORD"])
    host.click(640, 268, wait=1)              # "Test World" (second row)
    host.click(640, 353, wait=4)              # Open selected world
    host.shot("02_character")
    host.click(640, 393, wait=3)              # Join requests (n)
    host.shot("03_requests")
    host.click(750, 357, wait=4)              # Approve
    host.shot("04_after_approve")
    time.sleep(8)                             # the tester's page re-checks every 4 s
    tester.shot("04_after_approval")
    tester.click(640, 294)                    # Character name
    tester.type(os.environ.get("TESTER_CHARACTER", "Tessa"))
    tester.click(640, 418, wait=5)            # Create (Outcast warrior: the defaults)
    tester.shot("05_character")


def char_flow(b):
    """The tester (already approved, joined worlds sort first) creates their character."""
    tester = Player(b, "tester")
    tester.sign_in(os.environ["TESTER_EMAIL"], os.environ["TESTER_PASSWORD"])
    tester.shot("01_picker")
    tester.click(640, 252, wait=1)            # "Test World", now the first row
    tester.click(640, 368, wait=4)            # Open selected world
    tester.shot("02_create_character")
    tester.click(640, 294)                    # Character name
    tester.type(os.environ.get("TESTER_CHARACTER", "Tessa"))
    tester.click(640, 418, wait=5)            # Create (Outcast warrior: the defaults)
    tester.shot("03_character")


def duo_flow(b):
    """Two members enter the same world: the lobby fills, the battle starts, both play it out and press Continue."""
    host = Player(b, "host")
    tester = Player(b, "tester")
    host.sign_in(os.environ["HOST_EMAIL"], os.environ["HOST_PASSWORD"])
    host.click(640, 268, wait=1)              # "Test World" (second row for the host)
    host.click(640, 353, wait=4)              # Open selected world
    host.click(640, 352, wait=1)              # Enter battle
    state(host, "lobby", 40)
    time.sleep(1)
    host.shot("01_lobby_alone")
    tester.sign_in(os.environ["TESTER_EMAIL"], os.environ["TESTER_PASSWORD"])
    tester.click(640, 252, wait=1)            # "Test World" (joined worlds sort first)
    tester.click(640, 368, wait=4)            # Open selected world
    tester.click(640, 372, wait=1)            # Enter battle
    state(tester, "battle", 40)
    state(host, "battle", 40)
    time.sleep(2)
    host.shot("02_battle")
    tester.shot("02_battle")
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
    host.shot("03_result")
    tester.shot("03_result")
    host.click(440, 445, wait=4)              # Continue
    tester.click(440, 445, wait=4)
    host.shot("04_after_continue")
    tester.shot("04_after_continue")


def solo_flow(b):
    host = Player(b, "host")
    host.sign_in(os.environ["HOST_EMAIL"], os.environ["HOST_PASSWORD"])
    host.shot("02_world_picker")
    open_first_world(host)
    host.shot("04_character")
    host.click(640, 393, wait=3)          # Join requests (host only)
    host.shot("05_host_requests")
    host.click(640, 380, wait=3)          # Back
    host.click(640, 352, wait=1)          # Enter battle
    if STAGE == "lobby":
        state(host, "lobby", 40)
        time.sleep(1)
        host.shot("06_lobby")
        host.click(640, 444, wait=4)      # Leave
        state(host, "menu", 10)
        host.shot("07_after_leave")
    else:
        state(host, "battle", 40)
        time.sleep(2)
        host.shot("06_battle")
        deadline = time.time() + 240
        while time.time() < deadline:
            if host.page.evaluate("window.unnamedState") == "result":
                break
            host.click(1043, 421, wait=0)  # Ready (no plan: the unit forfeits its AP)
            time.sleep(3)
        state(host, "result", 5)
        time.sleep(2)
        host.shot("07_result")
        host.click(440, 445, wait=4)      # Continue
        host.shot("08_after_continue")


main()
