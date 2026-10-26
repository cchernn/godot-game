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
| What each skill does (damage, AP, range, speed, stages, hint text) | `game/content/skills/*.tres`, listed in `skills/skill_set.tres` | Inspector |
| Class and enemy attributes (might, dexterity, agility, vitality), progression fields and skills | `game/content/stats/classes/*.tres`, `stats/enemies/*.tres` | Inspector |
| Which classes and enemies a battle uses | `game/content/encounters/prototype.tres` | Inspector |
| Camera, light, background | `game/content/board/board_3d.tscn` | Inspector |
| Fog / move / target / hover highlights | `game/content/board/materials/*.tres` | Inspector |
| Battle screen: side panel, log, result text, guest connect panel | `game/client/client_main.tscn` | the 2D editor |
| Each pre-battle screen: sign-in, world picker, join, character, character creator, overworld (the game view), world management, settings, battle-server lobby | `game/client/screens/*.tscn` (one scene each) | the 2D editor |
| How those screens are put together and switched | `game/client/account_flow.tscn` (+ `account_flow.gd`) | the 2D editor |
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

## The game view and its windows (2D editor)
`game/client/screens/overworld_screen.tscn` is the game view: the map fills the screen, the `Dock` along the bottom has a toggle per window, and the `Windows` node holds the
four windows (`ActivityWindow`, `PartyWindow`, `CharacterWindow`, `MenuWindow`), each an instance of `game/content/ui/floating_window.tscn` with **Editable Children** on.
The four windows share one spot (the right side) and only one is open at a time: opening one closes the other (`_close_others` in `overworld_screen.gd`). To move them, change the anchors and offsets of each (keep them the same). Rename a window with its `title`, and give the scrolling area a size with `body_min_size`. Put controls under
`<window>/Layout/Scroll/Body`; add a window by instancing the scene again, adding a dock button and listing both in the `_toggles` dictionary of `overworld_screen.gd`.
The panel look is in the `floating_window.tscn` root's Theme Overrides. `Backdrop` is the map's background colour (put a painted map there later).
The map itself is the `MapCanvas` node. The map itself is the `MapCanvas` node: its Inspector has the colours (route lines, the party's
place, the picked place), the line width and the margin, and `node_scene` (`game/content/ui/map_node.tscn`, the button used for every place - restyle it there).
**Where each place sits** is `game/content/overworld/map_layout.tres`: open it, expand `positions` and edit the Vector2 for a node id (x and y are fractions
of the map area, 0 to 1, top-left is 0,0). A place missing from the list is placed on a ring automatically. Which places and routes exist, and what you can do
there, comes from the world template (`services/api/templates/*.json`), not from the scene.

`client_main.tscn` holds the whole battle screen: `SidePanel` (status, AP, skill list, facing buttons, plan queue, Undo / Clear / Ready,
error line, combat log), `Banner`, the guest `ConnectPanel`, `ResultPanel`, and the `AccountFlow` coordinator. Every screen before a battle is its own
scene in `game/client/screens/` (`sign_in_screen`, `world_picker_screen`, `join_screen`, `character_screen`,
`character_creator`, `overworld_screen`, `world_management_screen`, `settings_screen`, `lobby_screen`). `account_flow.tscn` instances the game view full-screen and the other screens in a centred `MenuPanel`, and shows one at a time; open a screen's own
scene to edit it. The character creator is deliberately a separate scene so it can grow (see docs/guide/01-login-screen.md).
The battle view (`BoardHolder`, `SidePanel`) starts hidden and is shown by the code when a battle begins; `ResultPanel` appears when it ends.
- **Move, resize, restyle anything**: containers, margins, fonts, colours, icons, extra decoration labels or images.
- **Keep the node names that have a `%` marker** (shown as a green percent badge in the Scene tree). The code finds them by name.
  Renaming or deleting one breaks that part of the screen; moving it elsewhere in the tree is fine.
- **Action bar** (`ActionBar`): Move, Attack, Defend, Item, Retreat, Context. Move and Defend queue the unit's skill in that slot; Attack opens `SkillBox`, the list of its other skills;
  Retreat is the old Escape; Item and Context are disabled until they exist.
- **Skill buttons** (the Attack list) are made from `ui/skill_button.tscn` (one per skill, filled in by the code). Restyle that scene.
- **One look for everything:** `ui/theme.tres` is applied on the root; edit it in the Theme editor (default font size, panel style, button styles).
- The 3D board area is the `BoardHolder` node; its width is set by `SidePanel`'s left offset (360 px), so resize both together.
- To preview the screens without a server, press **F6** on `client_main.tscn` (guest connect panel). The battle panel fills in once connected.

## Menu background

`game/content/ui/menu_background.tscn` is the animated backdrop behind sign-in, the world picker and the other menu screens. It is a normal scene, so everything is editable in the editor:
- **Layers** (back to front): `Sky` (a vertical gradient), `Moon` (a radial gradient), `Hills` (`Far`, `Mid`, `Near`: `Polygon2D` silhouettes you can reshape with the polygon tool), `FogLayer/Fog`. All of this is **placeholder art**:
  replace any layer with your own `TextureRect` or sprites, or add layers.
- **Motion:** the `AnimationPlayer` has one looping animation, `drift` (40 s, ping-pong): the hills sway at different speeds (parallax), the fog drifts and the moon breathes. Add tracks for new layers there.
  Animate a layer's `position` only on nodes that sit at the top-left of their parent (as `FogLayer` does); a `Control` placed with anchors loses its anchored place if its `position` is keyed.
- Leave `mouse_filter` on *Ignore* for every layer, or the backdrop would swallow clicks meant for the menu.
- `client_main.tscn` has it as `MenuBackground`. The client shows and plays it in the menus and hides and pauses it during a battle.

## Escape button and presence timer

- `client_main.tscn` → `SidePanel/Layout/ButtonRow/EscapeButton` is a normal button: move, restyle or rename its text there. The script only reads its `%EscapeButton` name.
  How long the second press counts is the `escape_confirm_seconds` export on the root node.
- `account_flow.tscn` → `PresenceTimer` sends the "still here" signal; `Wait Time` is the interval (10 s). The server's 30 second window is not set in the editor.

## Stats (Inspector)
Every class and enemy is a `UnitTemplate` resource. Double-click one in the FileSystem dock (e.g. `stats/classes/warrior.tres`) and edit
the **Attributes** group: vitality (max HP), might (added to damage and healing), dexterity (AP and accuracy), agility (tiles moved per AP and evasion), the **Progression** group (growth per level, point value, points per level, cap per attribute; all unused while `progression.enabled` is false in `balance.json`) and the **Skills** list. How attributes become battle numbers is `balance.json` "stats". Armor is not a class stat: it will come from gear
(pick skill resources from `game/content/skills`). Each field has a tooltip. All values
are provisional. Godot only writes non-default values into the file, so a stat at its default (e.g. 0) will not appear in the text, but it is
there in the Inspector.
- **Which activity runs which battle:** each activity in the world template (`services/api/templates/prototype@1.json`) has an `"encounter"` (the file name,
  without `.tres`, in `game/content/encounters`) and a `"max_players"`. Keep `max_players` no larger than the encounter's Classes list; a test fails if it is.
- **Which units a battle uses:** open `encounters/prototype.tres`. **Map** takes a painted map scene; **Classes** is the party: seat 0 uses the
  first, seat 1 the second, and so on, and a player's character class picks the matching entry. The list length is the maximum party size.
  **Enemies** is the roster in order: the first stands on spawn marker `E0`, the second on `E1`, and so on (the same enemy can appear twice).
- **A new enemy:** right-click `stats/enemies` > New Resource > `UnitTemplate`, set its id (lower-case) and stats, save it, then add it to the
  encounter's **Enemies** list. To give it a look, add an entry with the same id in `units/unit_visuals.tres`.
- **A new player class** also needs two lines of code, because the API and the sign-in screen keep their own list: add the id to `CLASSES` in
  `services/api/app/rules.py` and in `game/client/screens/character_creator.gd`. Tests fail if these lists and `stats/classes` disagree.
- **What is checked:** a skill missing from the skill set, an empty name or a duplicate class are reported when a battle is built and by the tests.
- **Rebuild to see it in a real battle:** the server holds the stats, so `scripts/stack.sh up game` (the design preview, F6 on
  `game/client/board/board_preview.tscn`, uses them directly).

## Skills (Inspector)
Every skill is a `SkillDef` resource in `game/content/skills/` (e.g. `strike.tres`); `skills/skill_set.tres` is the list of all of them. Open one:
- **Identity:** id (the file name), display name, **hint** (the tooltip and the line shown when you pick the skill), the **action slot** (which button of the
  battle's action bar it belongs to: *Attack* skills are listed under the Attack button; *Defend* is the Defend button; moves always sit on Move) and **kind**
  (move, attack, reaction, revive, support; the kind decides how the rules treat it).
- **Targeting:** what the player clicks (a character, a tile, yourself, or nothing) and the reach in tiles. Hidden for moves and reactions. **Anyone can be aimed at**,
  friend or foe, and you too: a heal on an enemy heals it, a strike on an ally hurts it. *Character* skills follow the target and are checked when they land (still in range = hit);
  *tile* skills hit whoever stands on the tile when they land (so they are usually given more damage).
- **Area:** leave empty for one target, or pick an *AreaShape* resource: *Radius* (every tile within *size* steps of the centre), *Line* (*size* tiles straight from the user
  toward the aimed tile) or *Cone* (*size* rows in front of the user, 1, 3, 5... tiles wide). *Requires LOS* lets walls (and higher ground) stop it: a radius is checked from its
  centre, a line or cone from the user. Everyone on a covered tile is hit: friend, foe and the user too. A *tile* skill's area is shown on the board while the player picks; a *character*
  skill's area is centred on the target when it lands, so it follows a target that moved, and only the single target is visible while planning. Each victim gets its own hit and crit
  roll (in id order); effects aimed at the target apply to every victim, effects *On = Caster* apply once. Area skills hitting the caster's own tile (Targeting = self) make a nova.
- **Timing:** speed (higher resolves first in a beat), frequency (once per turn or unlimited) and stability (interruption points that cancel it).
- **Stages:** the steps of the skill, each with its own **AP** and a list of **effects** (below). Power Strike has two stages: a wind-up (no effects) and a smash (damage and an interrupt).
- **Effects** (`SkillStage > Effects`, pick the type, then fill it in; every effect has *On*: the skill's target, or the caster):
  - **Damage:** base damage, whether it can miss, whether it can crit/flank, whether the attacker's power is added. Order: hit roll, bonuses, minus armor, then the target's shield, then HP.
  - **Heal:** HP restored, never above the maximum. Does nothing to a downed unit (use a revive skill).
  - **Shield:** points that absorb damage after armor and before HP, until the end of the round. They do not stack: a new shield only replaces a lower one.
  - **Interrupt:** points against the skill the target is in the middle of. Only lands if the damage in the same stage connected.
  - **Apply Status:** puts a status (a `StatusDef`, see below) on its target. Optional *duration turns* overrides the status's own. After a damage effect it only lands if the damage connected.
  - **Remove Status:** a cleanse. *Mode*: one named status, all buffs, all debuffs, or everything.
  A skill that does two things (an attack that also shields its user) is just two effects, the second one *On = Caster*.
- **Reaction:** range, duration and interrupt. Only shown when the kind is *reaction*.
- **A new skill needs no code:** create a `SkillDef` resource (right-click `skills` > New Resource > SkillDef), save it as `<id>.tres`, set the
  fields, add it to `skill_set.tres`, and add it to a unit's **Skills** list. The skill button, planning and AI pick it up from the data. A new
  *kind* of skill or a new *effect type* is new game logic and is code.
- Edits need `scripts/stack.sh up game web` to reach the running game (the server resolves skills; the web client lists them).

## Statuses (Inspector)
A status is a timed condition on a unit: a buff, a debuff, bleeding, a stun. Each is a `StatusDef` resource in `game/content/statuses/` (make the folder when you add the
first one: right-click > New Resource > StatusDef, save as `<id>.tres`). No statuses ship with the framework yet. To use one, add an **Apply Status** effect to a
skill stage and drag the status into its *Status* slot (no list to register it in). Fields:
- **Id**, **display name**, **hint** (shown on hover), **glyph** and **color** (what the unit card shows for now; real icons come later), **kind** (buff, debuff, other: used by cleanses).
- **Duration turns:** counted in turns (rounds), not beats. A status applied during a turn counts the rest of that turn as its first turn.
- **Stacking:** *Refresh* restarts the timer; *Stack* adds a stack (up to *max stacks*) and restarts the timer; *Ignore* does nothing if it is already on.
- **Stat changes (per stack):** armor, power, accuracy, evasion, dexterity, agility. Dexterity also changes AP (from the next turn) and agility changes tiles per AP.
- **Each turn:** a list of Damage, Heal or Shield effects run on the bearer once at the start of every turn, once per stack. Their hit and crit boxes must be off (statuses use no random numbers).
- **Conditions:** *Stunned* (the bearer takes no actions and cannot react; not an interruption) and *Rooted* (cannot move).
A downed or eliminated unit loses all statuses. A unit card lists its statuses with the turns left; hovering shows the hints.

## Items (Inspector)
An item is a consumable a character brings into a battle. Each is an `ItemDef` resource in `game/content/items/`, listed in `items/item_set.tres` (right-click > New Resource > ItemDef,
save as `<id>.tres`, then add it to the set). No items ship yet. Fields: **id** (lower-case, no spaces), **display name**, **hint**, **max stack** (most copies a character can carry),
and **Use**, which is an embedded skill: targeting, range, area, speed and stages with effects, exactly as in *Skills* above (so an item can heal, shield, damage, hit an area or apply
a status). You do not set the skill's id or frequency: the game gives it the id `item:<id>` and lets it be used as often as the character has copies and AP.
In a fight the **Item** button lists what you carry with the copies left (the ones already in your queue are counted as spoken for). A copy is used up when its skill *begins*; if the
action is skipped (target gone, out of range) nothing is used. What is used is saved with the battle result; a battle that never finishes saves nothing.
A character brings at most `items.battle_slots` kinds into a battle (`balance.json`, provisional 4). To give a character items for testing:
`GAME_API_SERVER_KEY=... scripts/grant_item.sh <character_id> <item_id> <quantity> [max_stack]` (needs the API running; there are no shops or loot yet).
Item changes need `scripts/stack.sh up game web` (and `up api` for a new migration).

## Things that are still code (for now)
The global tuning in `config/balance.json` (hit chance, the AP table, rewards) is a JSON file, not an Inspector resource. Game rules,
networking and the API stay in code. The dropdown choices for class on the character creator mirror the server's rules (`character_creator.gd`).

## `tools/generate_content.gd`
The one-time scaffold that created these files. It never overwrites existing files; `-- --force` regenerates everything and
**discards your edits**. You should not need it again.

The Character page lists the stats and skills of the character's class from the `.tres` files in `game/content/stats/classes`; change them in the Inspector and the page follows.
Settings (`settings_screen.tscn`) holds the account block only (email, change password, sign out); add other options there when the features exist.
