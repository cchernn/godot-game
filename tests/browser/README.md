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
  -e STAGE=battle -e HOST_EMAIL=you@example.com -e HOST_PASSWORD=... unnamed-browser-test
```
- `STAGE=join`: a tester account (`TESTER_EMAIL` / `TESTER_PASSWORD`, already confirmed) asks to join the world, the host approves, the tester's waiting page advances by itself and they create a character. Run once; re-running after the tester joined needs `STAGE=char`.
- `STAGE=char`: the already-approved tester opens the world and creates their character.
- `STAGE=duo`: host and tester both enter the same world (party size 2: `PLAYERS=2 scripts/stack.sh init && scripts/stack.sh up game`), play one battle together and press Continue.
- `STAGE=lobby`: sign in, pick the first world, open the join-requests screen, enter the lobby, leave (use `PLAYERS=2 scripts/stack.sh init && scripts/stack.sh up game` first).
- `STAGE=battle`: sign in, pick the first world, enter a battle (party size 1), ready each round until the result screen, press Continue.
- The container forwards localhost:8080-8082 to the host, because those are the addresses baked into the web build.
- Row positions in the world picker depend on how many worlds exist and how they sort (joined worlds first, newest first); the scripts assume the two worlds of the development project. Coordinates are for a 1280x720 viewport; if you move UI around in the editor, re-take a screenshot and adjust them.
- Typing is slowed (`delay=90`): the software-rendered page has a low frame rate and drops keystrokes otherwise.
