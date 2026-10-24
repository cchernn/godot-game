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
- `STAGE=party`: host starts a party, the tester asks to join, the host approves and starts, the tester reloads their tab mid-battle and returns from the hub, both play to the result and Continue. Start from no live parties: `uv run --project services/api python tests/browser/parties.py <email> <password> [--cancel]` lists them (and cancels the ones the account leads).
- `STAGE=pending`: the tester opens a world where their join request is still pending; the join screen waits and can go back. (Needs a pending request; the one-time stages that created the tester's membership and character are in the git history.)
- The container forwards localhost:8080-8082 to the host, because those are the addresses baked into the web build.
- Row positions in the world picker depend on how many worlds exist and how they sort (joined worlds first, newest first); the scripts assume the two worlds of the development project. Coordinates are for a 1280x720 viewport; if you move UI around in the editor, re-take a screenshot and adjust them.
- Typing is slowed (`delay=90`): the software-rendered page has a low frame rate and drops keystrokes otherwise.
