# Bringing in assets and fine-tuning the game in the editor

How to take art, models and sound from outside (see `docs/asset-sources.md` for where to get them) and make them part of this game, and how to tune the game once they are in. It is
the step-by-step companion to `docs/editor-guide.md`, which describes every scene and resource. Godot 4.7.2, GL Compatibility renderer, web export.

## 0. Before anything: the rules for outside assets

1. **Check the licence first**, on the creator's own page (not a repost). CC0 needs nothing from you. CC-BY needs a credit line. "Free for personal use" or "non-commercial" is not usable if you ever
   charge or run ads. Never take an asset that has no licence.
2. **Put each pack in its own folder** under `game/assets/<creator>_<pack>/` and copy the pack's licence text next to it as `LICENSE.txt`. The pack stays untouched; you build on it.
3. **Add a line to `docs/credits.md`** (create it the first time): pack, creator, link, licence. The in-game credits screen, when there is one, comes from it.
4. **Keep the download size in mind.** The web build downloads the whole project every first visit. Prefer low-poly models, textures at 1024 px or smaller, and music as `.ogg`.
5. Git: the folder is committed like anything else. Large originals (`.blend`, `.psd`, `.zip`) stay out of the repo; keep them on your drive.

## 1. How Godot takes a file in

Drop a file into the **FileSystem** dock (or copy it into the project folder) and Godot imports it. Select it and open the **Import** dock (next to Scene) to change how; press **Reimport** after.

| File | Use | Notes |
|---|---|---|
| `.glb` / `.gltf` | 3D models | Best choice; use it when a pack offers both `.glb` and `.fbx`. Double-click it to open **Advanced Import Settings** (a preview, the animations, the materials). |
| `.png` | Pictures, icons, textures | Import dock: Lossless or Lossy (WebP) keeps it simple. For crisp pixel art set the texture filter to *Nearest* on the node, or in Project Settings. |
| `.svg` | Icons | Scales cleanly; fine for status icons. |
| `.ogg` | Music and long sounds | Set **Loop** in the Import dock for music. |
| `.wav` | Short sound effects | Small and instant. |
| `.ttf` / `.otf` | Fonts | Used from the Theme (section 5). |

Use the **Reimport** button rather than renaming or moving a file in a file manager: Godot keeps an `.import` file beside each asset with its settings, and moving the file outside the editor loses its settings.
Move and rename files inside the FileSystem dock so references follow.

## 2. Units: a model for a class or an enemy

The game draws every unit from a scene (`game/content/units/*.tscn`, based on `unit.tscn`). A new look is one scene plus one line in `unit_visuals.tres`. The server never sees any of this.

1. **Import the model.** Copy the pack into `game/assets/...`. Double-click the `.glb` and look at the preview in **Advanced Import Settings**; in its animations tab set **Loop Mode** to *Linear* on the ones that should repeat (idle and walk). Press **Reimport**.
2. **Make the unit scene.** *Scene > New Inherited Scene* and pick `game/content/units/unit.tscn`. Save it as `game/content/units/<name>.tscn`. (Or open an existing one such as `warrior.tscn`.)
3. **Swap the body.** Drag the model `.glb` into the scene under the root. Right-click it and choose **Editable Children** if you need to reach inside. Hide or delete the capsule `Body` mesh, then in the root's Inspector (group **Parts**) set **Body** to the model's mesh node (or leave it empty if you do not want the team tint).
   - *Size*: scale the model node until it stands one tile wide. A unit is about 1 unit across; the name label sits at about 1.4 and the status badges at 2.0, so a very tall model needs those nodes moved up.
   - *Which way it faces*: the `Facing` node rotates to show the unit's facing. Put the model **under `Facing`** so it turns with it, and make sure the model's front points along the same direction as the arrow.
4. **Point the animations.** In the Inspector set **Animation Player** to the model's own `AnimationPlayer`. Then open **Animation names** and type the names the model came with for *Idle Animation*, *Walk Animation* and *Downed Animation* (look them up in the Animation panel; they are often `Idle`, `Walking_A`, `Death_A` and similar). A state with no animation simply keeps the last pose.
   If the model has no walk or death animation, leave it blank: the unit still slides and the HP bar still shows the state.
5. **Team colour.** `Body` is tinted by team (player, you, enemy, downed) only when it has a `StandardMaterial3D` as its *Material Override*. A model with its own textures does not need this; the HP bar and the name label still show the side. If you want the tint, give the model's mesh a material override with a white albedo.
6. **Register it.** Open `game/content/units/unit_visuals.tres`, add an entry under **Scenes**: the key is the lower-case template name (`warrior`, `hunter`, `mage`, `troll`, `lich`...), the value is your scene. Anything with no entry uses the default scene.
7. **Look at it.** Open `game/client/board/board_preview.tscn` and press **F6**. Orbit with the middle mouse button. Check: it stands on the tile, faces the arrow, idles, and the labels are above its head.

Tuning a unit's look without touching the model: `Body Scale`, the colours, `Hp Width`, `Pick Height` and `Pick Radius` (how easy it is to click) are exported on the root.

## 3. The map: tiles, scenery and objects

**Ground blocks.** The battle grid is a `GridMap` that uses the `MeshLibrary` `game/content/tiles/tiles.tres`, which is exported from `tiles_source.tscn`. Each `MeshInstance3D` child there is one block, and **its node name decides the kind**: names starting with `wall` block movement, `rough` costs extra AP, anything else is ordinary.
1. Import the pack's tile models (for example a dungeon kit's floor and wall pieces) and instance them as children of `tiles_source.tscn`. **Scale them to a cell of 1 x 0.5 x 1** (a floor block is half a unit tall; stacking two makes elevation 1).
2. Name them with the rule above (`ground_cobble`, `rough_mud`, `wall_brick`...).
3. *Scene > Export As > MeshLibrary...* and save over `tiles/tiles.tres`. **Add new blocks at the end**: maps remember blocks by their position in the library.
4. Paint maps with the GridMap palette (see the editor guide: start at (0, 0), elevation is stack height).
5. A block's colour or texture is its material in `tiles/materials/`. To retexture without changing shapes, just edit those: drop a PNG into the material's *Albedo > Texture*.

**Scenery that is only decoration** (trees, pillars, rubble, torches) can be instanced straight into the map scene under a plain `Node3D` you add (call it `Scenery`). The game ignores it: it does not block movement, so for anything that should block, paint a `wall_` block under or around it.

**Things players interact with** (chests, doors, levers) are map objects; see the editor guide section *Map objects*. Swap the placeholder box in `game/content/objects/map_object.tscn` (or a copy) for a model.

After changing a map or the tile library: **`scripts/stack.sh up game web`** so the server and the web build have the same layout. If they disagree the client draws the server's layout and logs a warning.

## 4. Pictures: stories, status icons, menus

- **Story portraits and backgrounds.** A story actor is `game/content/stories/actors/<name>.tres`. Open it and set **Portrait** to a PNG (a tall bust works best; a transparent background is needed). A slide's **Background** is a `Texture2D` on the slide in the story file; leave it empty to use the colour. The picture is scaled to fit a 300 x 460 frame (`screens/story_portrait.tscn`), keeping its proportions, so a 2:3 portrait of 512 x 768 is plenty.
- **Status icons.** Each status in `game/content/statuses/*.tres` has an **Icon** (`Texture2D`). 64 x 64 PNG or an SVG. The badge over a unit's head (`markers/status_icon.tscn`) shows it.
- **Menu background.** `game/content/ui/menu_background.tscn` is layered placeholders (sky, moon, hills, fog). Replace a layer with your own `TextureRect` or sprite and keep it ignoring the mouse; the `drift` animation moves the layers.
- **Map of the world.** The overworld backdrop is the `Backdrop` node in `overworld_screen.tscn`; swap the `ColorRect` for a `TextureRect` with a painted map. Where places sit on it is `game/content/overworld/map_layout.tres` (fractions 0 to 1).
- **Skill, gear and item icons.** Each has an **Icon** field in the Inspector (`game/content/skills/*.tres` under *Look and sound*, `gear/*.tres`, `items/*.tres`). Drop a 64 x 64 PNG or an SVG there. It shows in the Inventory lists, the battle's ability list and the click menu. No icon = text only, so you can add them one by one. Scale and fit are set on the lists and `ui/action_button.tscn` (see `docs/editor-guide.md`, *Icons*).

## 5. Fonts, colours and the look of the UI

Everything in the UI inherits `game/content/ui/theme.tres`. Open it in the **Theme editor** (bottom panel).
- **Font:** import a `.ttf`, then in the theme set *Default Font* and the default size. Dark fantasy usually wants a plain, readable font for body text (size 16 to 18) and a decorative one only for titles (give the title `Label`s a Theme Override instead). Keep text readable on a laptop screen first.
- **Panels and buttons:** edit the `StyleBoxFlat`s (colours, borders, corner radius). A `StyleBoxTexture` with a 9-patch PNG lets you use a framed-UI kit; set its margins so the corners do not stretch.
- **Floating windows** use their own panel style in `game/content/ui/floating_window.tscn` (Theme Overrides on the root).
- **One-off colours** (the chat names, damage numbers, highlights) are exported on the scene root that owns them; select it and look in the Inspector.

## 6. Sound

The game is ready for sound but ships **silent**: no sound files are included, and every cue in the bank is empty.
1. Copy the pack into `game/assets/<creator>_<pack>/` (with its licence) and let Godot import it. For music, select the file, tick **Loop** in the Import dock and press Reimport. Use `.ogg` for music and long sounds, `.wav` for short effects.
2. Open `game/content/audio/sound_bank.tres`. Click a cue (for example `hit`) and drag a sound file into its **Streams**. Do the same for `miss`, `heal`, `shield`, `downed`, `ui_click` and `round_start` first: those carry most of the feel.
3. Add the music: `music_menu`, `music_battle`, `music_story`, and the two result stingers. Lower a loud track with the cue's **Volume Db**.
4. For a signature sound on one skill, open the skill and fill **Cast Sound** and **Hit Sound** (Inspector, *Look and sound*).
5. Press F5 / reload the web build and listen. The three sliders on the Settings screen (Music, Sound effects, Interface sounds) are what players will use; set the cue volumes so that the defaults sound right.
6. The list of cues and when each plays is in `game/client/audio/sound_bank.gd`; the full explanation is in `docs/editor-guide.md`, *Sound*. Browsers play nothing until the first click, so music starts after it.

## 7. Fine-tuning the game itself

Where the numbers live. Provisional values are listed in `docs/provisional-values.md`; everything below changes without code.

| To change | Edit | In |
|---|---|---|
| Round length, planning time, hit and crit chances, round limit, chat limits | `game/shared/config/balance.json` | any text editor (or Godot's script editor) |
| What a skill does (damage, AP, range, speed, stages, text) | `game/content/skills/*.tres` | Inspector |
| Enemy and class attributes, skills, behaviour | `game/content/stats/classes/*.tres`, `stats/enemies/*.tres` | Inspector |
| Gear and consumables, and what enemies drop | `game/content/gear/*.tres`, `items/*.tres`, and the Drops list on `encounters/*.tres` | Inspector |
| Who fights where, triggers, gold | `game/content/encounters/*.tres` | Inspector |
| Story text and choices | `game/content/stories/*.tres` | Inspector |
| Camera, light, shadows, background | `game/content/board/board_3d.tscn` | Inspector |
| Which places exist, what they offer, rewards | `services/api/templates/*.json` | a text editor (not the Inspector) |

**The loop for tuning**
1. Edit the value.
2. Look at it: F6 on `board_preview.tscn` for the board; F6 on a UI scene for its layout.
3. Run the checks: `timeout 600 scripts/godot.sh --headless --path . --script res://tests/run_tests.gd` (about 5 minutes; add `-- --only=gear` to run just the files with that word). After adding any new `class_name` script run `scripts/godot.sh --headless --path . --import --quit` first.
4. After changing gear, items, class loadouts or `balance.json` chat limits, regenerate the API's copy: `scripts/godot.sh --headless --path . --script res://tools/export_catalog.gd`. A test fails until you do.
5. Put it on the stack: `scripts/stack.sh up game web` for content and visuals, `up api` as well when the API changed. **Reload the browser tab** afterwards. Recreating `game` drops battles in progress.
6. Test a real fight. For a quick scripted playthrough of the Emerald Serpent: `uv run --project services/api python scripts/e2e_event.py --minutes=20` (add `--hub-only` for just the first story).

**Tuning tips**
- Change one thing at a time and write the old value next to it in the commit message; balance work is full of regrets.
- Balance in small steps (10 to 20 percent). A hit chance, an AP cost or a range of 1 is a big change.
- A fight that goes to the round limit (30) ends as a draw and counts as a failed run: if testers hit it, the fight is too long or an enemy cannot be reached.
- The server decides everything. A clever client edit cannot change a number, only how it looks.

## 8. Web export notes

- **Size:** after `scripts/stack.sh up web`, open the game in the browser and look at the `index.pck` and `index.wasm` sizes in the developer tools' Network tab. A few MB of models and textures is fine; tens of MB makes the first load slow. If it grows, shrink textures first.
- **Renderer:** GL Compatibility. Avoid things it does not do well in a browser: heavy real-time shadows from many lights, large particle counts, and big transparent overlays. One sun with shadows is already the budget.
- **Textures:** 1024 px is plenty for a unit on a small tile; 2048 only for hero art. Put pixel art on *Nearest* filtering.
- **Fonts and sound:** a font file adds 100 to 500 KB; prefer `.ogg` for music, mono `.wav` for effects.
- **Try it in a real browser** before calling an asset done: what looks fine in the editor can be too dark or too heavy there. `http://localhost:8080` after `scripts/stack.sh up web`.

## 9. Troubleshooting

- *The model is huge, tiny or lying down:* scale and rotate the model node (not the whole unit root). Models authored in Z-up tools sometimes need a 90 degree turn on X.
- *The unit does not animate:* the Animation Player export is empty, or the names in **Animation names** do not match; also check the animation's loop setting.
- *Pink or black materials:* the texture did not import; select it and Reimport, and keep textures next to the model.
- *A block shows the wrong kind after editing the library:* blocks are remembered by position; re-export keeping the old order and add new blocks at the end.
- *No sound:* the cue has no stream; the stream's bus is not one of Music, Effects or UI; the slider is at zero (Settings); or the page has not been clicked yet in the browser.
- *The preview and the live game differ:* the web build or the game server is stale. Rebuild: `scripts/stack.sh up game web`, then reload the tab.
- *Everything changed after I moved a folder:* move files inside the editor's FileSystem dock; if you moved them outside, reopen the project and fix the broken references the editor lists.
