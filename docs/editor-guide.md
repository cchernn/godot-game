# Working in the Godot editor

Anything visual lives in scenes and resources you edit here (Godot 4.7.2). Code only reads them. Open the
project from `project.godot`; the first open imports everything.

## Where things are

| What | File | Edit it in |
|---|---|---|
| Battle map (blocks, spawns) | `game/content/maps/prototype.tscn` | the 3D editor, GridMap palette |
| Tile blocks (shape, material) | `game/content/tiles/tiles_source.tscn` -> exported to `tiles/tiles.tres` | the 3D editor |
| Tile colours / textures | `game/content/tiles/materials/*.tres` | Inspector |
| Units (model, labels, animations) | `game/content/units/unit.tscn` and `warrior.tscn`, `ghoul.tscn`... | the 3D editor, AnimationPlayer |
| Which scene draws which unit | `game/content/units/unit_visuals.tres` | Inspector |
| Camera, light, background | `game/content/board/board_3d.tscn` | Inspector |
| Fog / move / target / hover highlights | `game/content/board/materials/*.tres` | Inspector |
| Battle screen: side panel, log, result text, guest connect panel | `game/client/client_main.tscn` | the 2D editor |
| Sign-in, join, character, host-approval and lobby screens | `game/client/account_flow.tscn` | the 2D editor |
| One join request in the host's list | `game/content/ui/join_request_row.tscn` | the 2D editor |
| Victory / defeat panel | `ResultPanel` in `game/client/client_main.tscn` | the 2D editor |
| Skill button look | `game/content/ui/skill_button.tscn` | the 2D editor |
| Fonts, colours, panel style (whole UI) | `game/content/ui/theme.tres` | the Theme editor |

**See your changes without a server:** open `game/client/board/board_preview.tscn` and press **F6**. It shows the map
with a sample battle. Orbit with the middle mouse; click a tile to print its coordinates. Its Inspector has
`players`, `seed_value` and `viewer_seat`. (F5 runs the real client, which needs the stack from `scripts/stack.sh up`.)

## Camera controls (in game and in the preview)
Middle mouse drag = orbit - Shift + middle drag = pan - wheel = zoom - Q / E = quarter turn - F = reset.
Select the `CameraRig` node in `board_3d.tscn`: the Inspector has start angle, limits, speeds, smoothing and whether to
invert vertical orbit. Select `Camera3D` under it for field of view, or switch it to **Orthogonal** for a flat isometric
look (the rig then drives the camera size).

## Painting the map
1. Open `maps/prototype.tscn`, select the **Terrain** node (a GridMap). The GridMap palette opens at the bottom.
2. Pick a block and paint. The grid is the battlefield: grid **x** and **z** are the board's x and y.
   - **Start at (0, 0) and paint towards +x / +z.** Negative cells are rejected.
   - **Elevation = stack height.** One block at y = 0 is flat ground; two stacked is elevation 1, and so on.
   - **The block's name decides the tile kind** (looked at on the top block of each column):
     names starting with `wall` = blocked, `rough` = difficult terrain (costs more AP), anything else = normal.
   - A column with no blocks is blocked (a hole). The prototype's walls are 4 blocks tall for looks; any height works.
3. **Spawns:** the `Spawns` node holds `Marker3D`s. `P0`..`P3` are the player seats, `E0`..`E2` the enemy spots. Drag them
   (they snap to whichever tile column they sit above). Names must start with `P` or `E`.
4. Keep the GridMap's **Cell Size** at 1 x 0.5 x 1 and cell centering on, unless you also change the tile meshes.

**After changing a map, rebuild so the server and the web build both have it:** `scripts/stack.sh up game web`.
If they disagree, the client logs a warning and draws the server's layout, and the game follows the server's.

## Changing tile blocks
- Colours and textures: edit `tiles/materials/ground.tres`, `rough.tres`, `wall.tres` directly; the blocks update at once.
- Shapes or new block types: open `tiles/tiles_source.tscn`. Each `MeshInstance3D` child is one block, and its **node name
  is the block name** (so a new `wall_stone` child is a blocked block). Then **Scene > Export As > MeshLibrary...** and save over
  `tiles/tiles.tres`. Add new blocks at the end: maps remember blocks by their position in the library.

## Units
- Each unit is a scene whose root uses `unit_3d.gd`. `unit.tscn` is the base; `warrior.tscn` etc. are inherited from it
  (open one and change just what differs, e.g. its `Body Scale`).
- To use your own model: in `unit.tscn` (or a variant) replace or edit `Body` (import a `.glb`, drop it in as a child, hide or delete the
  capsule). In the root's Inspector, the **Parts** group tells the script which nodes to use (`Body`, `Facing Pivot`, labels, health
  bar `Hp Fill`, `Animation Player`); point them at your nodes. Team colour tints `Body` only if it has a
  StandardMaterial3D override.
- **Animations:** the AnimationPlayer already has `idle`, `walk` and `downed`. Edit or replace them; the script plays them by those names.
- **Giving a class or enemy its own look:** create a new scene (Scene > New Inherited Scene > `unit.tscn`), save it in `units/`, then open
  `unit_visuals.tres` and add an entry under **Scenes**. The key is the **lower-case template name** (`warrior`, `ranger`, `cleric`,
  `rogue`, `ghoul`, `cultist`); anything without an entry uses the default scene.
- Colours, health-bar size and pick size are exported on the root (`Look` and `Picking` groups).

## Highlights and look
- `board/materials/fog.tres` (unseen tiles), `move.tres` (planned path), `target.tres` (planned attack), `hover.tres` (cursor).
  They are flat planes laid on the tiles: change colour or transparency in the Inspector.
- Sun, shadows, ambient light and background colour: `Sun` and `WorldEnvironment` in `board_3d.tscn`.
- The control hint at the top is the `Hud/Hint` label there.

## The UI (2D editor)
`client_main.tscn` holds the whole battle screen: `SidePanel` (status, AP, skill list, facing buttons, plan queue, Undo / Clear / Ready,
error line, combat log), `Banner`, `ResultLabel`, the guest `ConnectPanel`, and the `AccountFlow` screens. `account_flow.tscn` has one
container per step: `SignInStep`, `WorldsStep` (the world picker), `JoinStep`, `CharacterStep`, `HostStep`, `CreateCharacterStep`, `WaitStep` (the lobby).
The battle view (`BoardHolder`, `SidePanel`) starts hidden and is shown by the code when a battle begins; `ResultPanel` appears when it ends.
- **Move, resize, restyle anything**: containers, margins, fonts, colours, icons, extra decoration labels or images.
- **Keep the node names that have a `%` marker** (shown as a green percent badge in the Scene tree). The code finds them by name.
  Renaming or deleting one breaks that part of the screen; moving it elsewhere in the tree is fine.
- **Skill buttons** are made from `ui/skill_button.tscn` (one per skill, filled in by the code). Restyle that scene.
- **One look for everything:** `ui/theme.tres` is applied on the root; edit it in the Theme editor (default font size, panel style, button styles).
- The 3D board area is the `BoardHolder` node; its width is set by `SidePanel`'s left offset (360 px), so resize both together.
- To preview the screens without a server, press **F6** on `client_main.tscn` (guest connect panel). The battle panel fills in once connected.

## Things that are still code (for now)
Class and enemy stats and which units appear in the encounter (`game/combat/encounter.gd`) are next to move into resources. Game rules,
networking and the API stay in code. The dropdown choices for origin and class mirror the server's rules (`account_flow.gd`).

## `tools/generate_content.gd`
The one-time scaffold that created these files. It never overwrites existing files; `-- --force` regenerates everything and
**discards your edits**. You should not need it again.
