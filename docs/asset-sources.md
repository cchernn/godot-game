# Where to get assets for the game

Researched 2026-10-31. Licences change and reposts are often wrong: **always read the licence on the creator's own page before you download, and copy it into the pack's folder** (`docs/asset-guide.md`, section 0).
"Checked" means the licence wording was read on the creator's page this session; "reported" means it came from a search result or a third-party guide and still needs a look.

## What the game needs

| Need | Style that fits |
|---|---|
| Units (3 classes, about 12 enemies) | Low-poly, stylised, rigged, with idle, walk and a defeat animation; around 1 tile wide |
| Ground and scenery (dungeons, woods, a theatre, a pit) | Modular kits that snap to a grid (our cell is 1 x 0.5 x 1) |
| Story art (portraits, backdrops) | Painted or semi-realistic busts for dialogue; wide backgrounds |
| Icons (statuses now; skills, gear and items later) | 64 px icons, one consistent look |
| UI (panels, buttons, fonts) | Dark, readable, a frame style that stretches (9-patch) |
| Sound (none yet) | UI clicks, hits and spells, ambient loops, a few music themes |

**Keep it consistent.** Mixing creators gives a patchwork. The safest route is one creator for all units and one for the ground and props, in the same low-poly look.

## 3D models

| Source | Licence | What is there | Notes |
|---|---|---|---|
| [KayKit by Kay Lousberg](https://kaylousberg.itch.io/kaykit-adventurers) | **CC0** (checked on the Adventurers page: "no attribution required"; asks you not to resell unmodified copies) | **Adventurers**: 5 rigged, animated, low-poly dungeon-themed characters free, plus 25+ weapons and accessories (swords, shields, axes, bows, staffs, wands); `.glb`/`.gltf` and `.fbx`; one 1024 px gradient texture. More characters and recolours, and the `.blend` sources, are paid tiers. A separate paid pack adds more animations | Best match for the three player classes (warrior, hunter, mage). Basic movement animations only; you may need the animation pack for attacks |
| [KayKit Dungeon Remastered](https://kaylousberg.itch.io/kaykit-dungeon-remastered) | **CC0** (reported) | 200+ stylised dungeon pieces and props | Ground blocks, walls, props for the theatre and pit |
| [KayKit Skeletons](https://kaylousberg.itch.io/kaykit-skeletons) | **CC0** (reported; a "Legacy" version also exists, check which you download) | Skeleton characters | Undead: ghouls, cultists, the lich's minions |
| [Quaternius](https://quaternius.com/) | **Quaternius Asset License v1.0** (checked: no attribution required; you may not resell or redistribute the assets as a standalone pack). Older Quaternius listings on other sites say CC0; use the licence shown on the pack you download | Characters (Animated Knight, RPG Character Pack, modular outfits), monsters (Ultimate Monsters, Bestiary - Dungeon Monsters Kit, Animated Monster Pack), Modular Dungeon Pack, Fantasy Props MegaKit, Modular Weapons, Ultimate RPG Pack. No UI | The largest free monster set: trolls, a dragon, wolves, the leshen. Check each pack's animation list for a death animation |
| [Kenney](https://kenney.nl/support) | **CC0** (checked: "all game assets ... are public domain (CC0)"; credit optional, do not use Kenney's logo) | Mini Dungeon, Modular Dungeon Kit (40 pieces), Character Assets, many more 3D packs | A flatter, simpler look than KayKit; the dungeon kits are good for ground and props |
| [Poly Pizza](https://poly.pizza/) | Mixed per model: CC0 and CC-BY (from memory, not checked this session) | Thousands of single low-poly models | Good for one-off props; read each model's licence and credit when it is CC-BY |
| [Poly Haven](https://polyhaven.com/license) | **CC0** (reported from their FAQ and licence page) | Models, textures, HDRIs | Realistic, not low-poly; useful for textures |

## Textures

- [ambientCG](https://ambientcg.com/) and [Poly Haven](https://polyhaven.com/): both reported as **CC0** (for ambientCG I could only read a third-party description; open its licence page before using it). Stone, wood, dirt and moss PBR textures. Downsize to 1024 px or less for the web build and drop them on the materials in `game/content/tiles/materials/`.
- Beware libraries that are free only for personal use (for example FreePBR needs a paid commercial licence).

## 2D art: story portraits and backgrounds

| Source | Licence | Notes |
|---|---|---|
| [Medieval Painterly Avatars by Kalponic Studio](https://kalponic-studio.itch.io/medieval-painterly-avatars) | free version **CC0** (reported): 20 avatars | Painterly bust portraits: a good fit for dark fantasy |
| [OpenGameArt: Mixed Fantasy Backgrounds](https://opengameart.org/content/mixed-fantasy-backgrounds), [Fantasy Background](https://opengameart.org/content/fantasy-background) | **CC0** (reported) | Story backdrops |
| [OpenGameArt: CC0 Character Portraits](https://opengameart.org/content/cc0-character-portraits), [visual novel style characters](https://opengameart.org/content/visual-novel-style-characters), [VN Characters](https://opengameart.org/content/vn-characters) | **CC0** (reported) | Varied quality and styles; look before you commit |
| [VNDev image and audio pack (Klast Halc)](https://klast-halc.itch.io/vndev-pack) | **CC0** (reported) | Sprites, backgrounds and music in one pack |
| [itch.io: visual novel assets, CC0](https://itch.io/game-assets/new-and-popular/assets-cc0/genre-visual-novel) | CC0 filter | 84 results at the time of the search |
| Not usable as is | | Lorestrome portrait backgrounds are CC-BY-SA (share-alike); some "free" portrait packs ask for credit or do not state a licence. Treat anything without a clear licence as not allowed |

The art of the stories' scenes (the village, the woods, the theatre, the pit) is the kind of thing that is hard to find free in a matching dark style. If nothing matches, plain tinted backdrops (already in the stories) with good portraits carry a visual novel well.

## Icons and UI

| Source | Licence | Notes |
|---|---|---|
| [game-icons.net](https://game-icons.net/about.html) | **CC BY 3.0**: credit required ("Icons made by {author}. Available on https://game-icons.net") | Thousands of consistent SVG icons for skills, gear, statuses. Put the credit in `docs/credits.md` and the in-game credits |
| [Minimal Fantasy GUI by eta](https://etahoshi.itch.io/minimal-fantasy-gui-by-eta) | **CC0** (reported) | A minimalist fantasy GUI; a reviewer says some arrows and button highlights are missing |
| [Legends - Paladin Skill Icons by Foozle](https://foozlecc.itch.io/legends-fantasy-paladin-skill-icons) | **CC0** (reported) | 20+ icons; the creator says they were made with a mix of AI and Photoshop, which matters if you want to avoid AI art |
| [Fantasy RPG UI Pack, Moon Tribe](https://moon-tribe.itch.io/fantasy-rpg-ui-pack) | the **free** version CC0 (reported); the paid pack has its own licence | |
| [Kenney UI packs](https://kenney.nl/support) | **CC0** (checked) | Clean, flat panels and buttons |

## Fonts

On [Google Fonts](https://fonts.google.com/) (the **SIL Open Font License**: free for games, including commercial; reported by font guides, confirm on each font's page):
- **Cinzel** (classical capitals, good titles), **Almendra** (calligraphic, readable text), **Uncial Antiqua**, **Pirata One**, **Grenze Gotisch**, **UnifrakturMaguntia** / **UnifrakturCook** (heavy blackletter: titles only).
- For body text keep a plain, legible font; use the decorative ones for headings. Include the font's licence file next to the `.ttf`.

## Sound and music

| Source | Licence | Notes |
|---|---|---|
| [Kenney audio packs](https://kenney.nl/support) | **CC0** (checked) | UI and interface sounds, impacts; no dark fantasy music |
| [OpenGameArt: dark forest theme](https://opengameart.org/content/dark-forest-theme), [dungeon ambience](https://opengameart.org/content/dungeon-ambience), [dark ambiences](https://opengameart.org/content/dark-ambiences), [a darkness opus](https://opengameart.org/content/a-darkness-opus) | **mixed**: some CC0, some CC-BY, some OGA-BY (attribution) - read each page | The best free dark fantasy music is here. Record each track's licence |
| [Fantasy Sound Effects (Tinysized SFX), OpenGameArt](https://opengameart.org/content/fantasy-sound-effects-tinysized-sfx) | **CC0** (reported) | Swords, arrows and similar effects |
| [Fantasy Ambient Sound Effects Pack, kmontesdev](https://kmontesdev.itch.io/fantasy-ambient-sound-effects-pack-cc0) | **CC0** (reported); about 2 GB | Hits, spells, monsters. Far too big to ship whole: pick what you use |
| [Freesound](https://freesound.org/) | per sound: CC0, CC-BY or CC-BY-NC | Filter to CC0. Never take CC-BY-NC for a game you might sell |
| Not usable without credit | | e.g. "Heart of Sin" dark soundtrack needs credit; paid packs such as Broken Shield |

The game has no audio code yet (`docs/asset-guide.md`, section 6).

## A sensible starting set

1. **Player classes:** KayKit Adventurers (free tier).
2. **Undead enemies (ghoul, cultist, lich):** KayKit Skeletons.
3. **Troll, dragon, wolf statues, leshen:** Quaternius Ultimate Monsters or the Bestiary kit.
4. **Ground, walls and props:** KayKit Dungeon Remastered, with ambientCG textures on the woods blocks.
5. **Story portraits:** Medieval Painterly Avatars or your own commissioned art later.
6. **Icons:** game-icons.net (with the credit line).
7. **Fonts:** Cinzel for titles, a plain readable font for body text.
8. **Sound:** Kenney for UI, OpenGameArt for ambience and music (licence per track).

Start with step 1 and 2: the units are what you see most, and swapping them (guide section 2) is the quickest proof that the pipeline works. Everything above is a stand-in until you have your own art; the guide is the same either way.
