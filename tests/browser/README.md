# Real-browser test

Drives the deployed web client in headless Chromium (software WebGL), so the real page, the Godot web build,
the API (CORS) and the WebSocket path are exercised. The UI is a canvas, so the script clicks by coordinates and
waits on `window.unnamedState` (`menu` / `lobby` / `battle` / `result`, published by `client_main.gd`).
Screenshots of every screen go to the output folder.

```bash
scripts/stack.sh up                                   # the stack must be running
docker build -t unnamed-browser-test tests/browser
docker run --rm --add-host host.docker.internal:host-gateway \
  -v "$PWD/render_out/browser:/out" \
  -e STAGE=party -e HOST_EMAIL=you@example.com -e HOST_PASSWORD=... unnamed-browser-test
```
- `STAGE=party`: the host and the tester (both members of Test World with a character, each a party of one at Kampung Lama) meet on the map (the dock opens the Party and Activity windows). The tester
  asks to join the host's party, the host approves and starts Training skirmish, the tester is taken into the battle, reloads their tab mid-battle and returns
  from the Party window (Return to battle), both play to the result (a defeat is fine) and Continue. It takes up to about 12 minutes. **Start clean**: both parties idle at the same place,
  no pending asks, the tester not in the host's party. `uv run --project services/api python tests/browser/parties.py <email> <password> [--clean]` lists the
  parties and, with `--clean`, withdraws that account's pending asks and leaves a party it is only a member of (run it for the tester before every run). A battle
  nobody is connected to is cancelled by the game server after its 5-minute grace, so after a failed run wait that long. The click positions of the
  dock and windows are the constants at the top of `run.py`; they move when a window's content changes (a party of two is taller).
  With `ESCAPE_XY="1210,132"` (the Retreat button, top right of the side panel; this was 1112,425 / 1200,425 before the action bar grew) the tester also presses Escape after returning to the battle and watches to the end (each press tries every listed spot). `PROBE=1` stops at the battle screen, to find click positions.
- `STAGE=session`: two browsers sign in with the tester's credentials; the second must be refused ("signed in on another device") and the first must stay signed in. Needs only `TESTER_EMAIL` and `TESTER_PASSWORD`.
- `STAGE=reset`: the tester opens the world after being away longer than the presence window while in the host's party; the Party window should show a party of one. Set it up by
  putting the tester in the host's party over the API, then wait a minute with nobody signed in.
- `STAGE=tour`: the host opens Test World and clicks through `CLICKS="x,y,label;..."`, with a screenshot after each. For looking at screens (character page, settings, world management) without a scripted flow.
- `STAGE=pending`: the tester opens a world where their join request is still pending; the join screen waits and can go back. (Needs a pending request; the one-time stages that created the tester's membership and character are in the git history.)
- The container forwards localhost:8080-8082 to the host, because those are the addresses baked into the web build.
- Row positions in the world picker depend on how many worlds exist and how they sort (joined worlds first, newest first); the scripts assume the two worlds of the development project. Coordinates are for a 1280x720 viewport; if you move UI around in the editor, re-take a screenshot and adjust them.
- Typing is slowed (`delay=90`): the software-rendered page has a low frame rate and drops keystrokes otherwise.
