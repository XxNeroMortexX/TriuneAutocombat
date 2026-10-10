# Triune AutoCombat

A combat bot and set of in-game tools for the **[Project Triune](https://nms.bestemu.com/)** EverQuest server, running on [MacroQuest](https://macroquest.org/).

On Project Triune every character is three classes at once. Triune AutoCombat runs all three for you: it casts your spells, fires your AAs and discs, pulls mobs, controls your pets, keeps your boxes together, and sits to med when it is safe. Everything is set up from one in-game window - no macros to write.

## Morte tweak baseline

The [v3.1-Morte.1 release](https://github.com/XxNeroMortexX/TriuneAutocombat/releases/tag/v3.1-Morte.1) at commit [`3b2ce13`](https://github.com/XxNeroMortexX/TriuneAutocombat/commit/3b2ce131a5496eac319a698471f317e1b4ec9265) is the fixed starting point: Gennro's Triune 3.1 Lua code plus the separate MQ2WebUpdate integration. Future Morte gameplay tweaks are developed and recorded after this tag; the tag stays on the original baseline.

---

## Install

1. Download the latest **RoF2** MacroQuest from [macroquest/macroquest/releases](https://github.com/macroquest/macroquest/releases) and extract it somewhere like `C:\MacroQuest`.
2. Download **`TriuneAutocombat-Install.zip`** from [NeroMorte's Triune releases](https://github.com/XxNeroMortexX/TriuneAutocombat/releases/latest).
3. Extract the ZIP **into the root of your MacroQuest folder**. Its `lua/`, `config/`, `resources/`, and `plugins/` directories merge into those folders. Existing character loadouts are not part of the archive.
4. For MQ2Nav navigation, download the [complete mesh pack](https://mqmesh.com/resources/zips/MQ2Nav_meshes.zip) separately and extract its `.navmesh` files into `resources/MQ2Nav/` under your MacroQuest folder. The mesh pack is hosted by a separate site and is not bundled with this release.
5. Start `MacroQuest.exe`, then log into Project Triune.

Triune opens by itself when you log in. If you close it, type `/ac` or `/lua run triune`.

On the first install, load the backend with `/plugin mq2webupdate load`. Open **Updates** in Triune to check the NeroMorte Main Download repository. For later updates, use **Check for Updates**, **Stage Updates**, and the appropriate confirmed apply button in game. Plugin DLL replacements use an independent Lua coordinator so the updater can unload and reload its own DLL. Files linked into MacroQuest are protected; update their source checkout separately. Repository and deployment mappings can be edited in the updater GUI and saved in its profile INI.

> Windows users: add your MacroQuest folder as an antivirus exception before running it.

---

## First run

1. **Check your classes.** The main window shows the three classes it detected. Click **Re-detect** if they are wrong.
2. **Set up what to cast.** Go through the tabs: **Spell Gems** (spells), **Abilities** (kick, bash, backstab...), **AAs**, **Disciplines** and **Clickies**. Each entry gets a simple rule for when to fire it, such as *Target HP < 90%*, *My HP < 40%*, *Missing Buff* or *Always*. **Import Bar** fills the spell list from whatever you have memorized.
3. **Pick a mode** on the **Control** tab and click **Start** (or type `/ac run`).

Your setup is saved automatically and reloads next time.

---

## Combat modes

| Mode | Use it when | What Triune does |
|---|---|---|
| **Manual** | You want to drive | You move and pick targets. Triune attacks, casts, heals and uses your abilities. |
| **Puller - Camp** | You are the puller | Runs out, tags a mob, brings it back to camp and fights it there. |
| **Puller - Hunt** | Solo roaming | Wanders the zone and kills mobs where they stand. |
| **Assist - Chase** | Boxed melee | Follows the Main Assist and attacks their target. |
| **Assist - Camp** | Boxed, stay put | Holds at camp and only fights what comes in. |
| **Assist - Backline** | Boxed healers and casters | Stays at range and never runs into melee. |

Set the Main Assist with `/ac ma <name>` or from the Control tab.

**Combat style** (Settings tab, or `/ac style melee|ranged|spell`) decides how you fight: close to melee, shoot a bow from a distance, or stand back and only cast.

**Pulling** options live on the Control tab: pull with melee, a spell, your pet or a bow; an **Include list** (only pull these) and an **Ignore list** (never pull these); faction filters so you never pull a guard; and **waypoint routes** for patrolling a path (`/ac wp add` while walking).

**Waypoint combat anchors** are optional in Puller - Hunt. Enable **Use Combat Anchors at Waypoints** to give nodes Travel or Hunt behavior. Hunt nodes have their own combat radius, no-target wait, and roam setting; leaving the option off keeps the existing patrol behavior. Stationary pet camp pulling remains a separate Camp-mode option.

**Ordered group targets** for spells, disciplines, and clickies offer **Me, then Group** or **Group, then Me**. Triune chooses the first living, in-range recipient whose condition is met. True Self spells keep your selected target unchanged.

**Burn mode** (`/ac burn`) fires anything you marked *Burn Only* - flip it on for named mobs.

**Trash Mode** (button beside Burn, or `/ac trash on|off|toggle`) temporarily clears easy mobs with melee, skills, disciplines and existing pets. It blocks automated spells (including heals, buffs and pet summons), activated AAs and clickies, including Buffbot and automatic repeatable-AA activations. Spell pulls temporarily use melee; other pull methods remain available. Combat mode, loadout selections and saved styles are unchanged. Turning it off restores normal behavior; restarting Triune resets it off. An already-issued cast can finish. Manual EQ commands and independent scripts remain under your control.

---

## Windows and tools

Everything below is built in. Open them from the buttons on the main window's header or with the command shown.

| Window | Command | What it is |
|---|---|---|
| Status | main window tab | Live view of what the bot is doing, your target, pets and XTarget threats. |
| Pets | main window tab | Control up to three pets: attack, back off, hold, taunt, and the server's `#petcmd` commands. |
| Target & Player HUD | `/ac hud` | Compact unit frames for you, your target and your pets. |
| Group | `/ac group` | Replacement group window with vitals, roles and click-to-target. |
| XTarget | `/ac xtar` | Replacement extended target window with HP, aggro and distance. |
| Effects & Songs | `/ac eff` | Your buffs and songs with time left. |
| Spell Gem Bar | `/ac gems` | Replacement spell bar with recast timers and spell sets. |
| Cooldowns | `/ac cd` | Every ability, AA and disc timer in one place. |
| Spellbook | `/ac spellbook` | Browse and search the spells of all three classes; mem to a gem from here. |
| Map | `/ac map` | 2D zone map, Norrath atlas and an NPC tracker (`/ac track`). Camp, waypoints and hazards are drawn on it. |
| Chat Windows | `/tacchat` | Chat window replacement: tabs, filters, colours, highlights, a Tells window, item links, NPC dialogue links (click to answer), logging. |
| Game Database | `/ac db` | Offline copy of the server's item, NPC and spell database. `/ac item`, `/ac npc`, `/ac spell` search it. |
| Inventory & Bank | `/ac inv` | Search, sort and move items; see every box's bags; hand items between boxes. |
| Hot Buttons | `/ac btn` | Button Master-style hotbars with cooldown overlays and share strings. |
| Box Network | `/ac net` | See and steer boxes using local Actors or connected EQBC across PCs. `/ac net all burn on` runs a command on all of them. |
| NMS Loot | `/ac nms` | The server's `#nms` loot system as a window, shared across your boxes. |
| DPS Parser | `/dps` | Per-fight damage for you and your pets, plus a group meter over the Box Network. |
| Auto-Accept | `/ac autoaccept` | Auto-accepts group, trade and DZ invites by your rules. |
| Auto AA | `/ac aawin` | Spends AA points on the checked priorities only; the fireworks cap spender runs once every priority is maxed (or none is checked). `/ac aastatus` shows why each priority is or is not next. |
| Buffbot | `/ac buffbot on` | A buff station: players `/tell` you for buffs, it casts them. Off unless you turn it on. |
| Cursor Manager | `/ac cursorui` | Clears whatever is stuck on your cursor. |
| Parcels | `/ac parcels` | Tells you when parcels arrive and collects them all at a parcel merchant. |
| Floating damage | Settings -> Plugins | Big animated numbers for crits. |
| Updates | Header **Updates** button | Compares, stages, and applies files from the configured Main Download repository; monitors Gennro separately. |
| Compact Mini HUD | `/ac compact` | The whole bot shrunk to a small strip. |

Each of these is a plugin in `lua/tac/`. Turn them on or off under **Settings -> Plugins**.

---

Player Chase measures distance in 3D. When nearby with clear line of sight, swimming or levitating followers can use MoveUtils Stick UW for the final vertical approach. Nav continues to provide distant mesh routing; Chase and combat Nav commands use the selected GUI range without hidden approach padding; combat movement uses the same XYZ range checks and nearby UW handoff while retaining its existing engagement permissions.

## Commands you will actually use

Type `/ac help` in game for the full list.

| Command | What it does |
|---|---|
| `/ac` | Start or pause |
| `/ac run` / `/ac pause` | Start / pause |
| `/ac manual`, `/ac puller camp`, `/ac puller hunt`, `/ac assist chase`, `/ac assist camp`, `/ac backline` | Switch mode |
| `/ac ma <name>` | Set the Main Assist |
| `/ac chasedist <0-100>` | Set player Chase distance in 3D; zero uses a one-unit arrival tolerance |
| `/ac burn` | Toggle Burn mode |
| `/ac trash [on\|off\|toggle]` | Temporarily block spells, AAs and clickies for melee trash clearing |
| `/ac memall` | Memorize any missing spells |
| `/ac importbar` | Build the spell list from your memorized gems |
| `/ac style melee\|ranged\|spell` | Set combat style |
| `/ac wp add` / `/ac wp clear` | Add a waypoint here / clear the route |
| `/ac pet attack\|back\|hold on` | Pet commands (any `#petcmd` verb) |
| `/ac net <all\|zone\|group\|Name> <command>` | Run a command on the boxes: an `/ac` command (`/ac net all burn on`) or any slash command as typed (`/ac net group /ac manual`, `/ac net all /camp`) |
| `/ac scale 1.25` | Make every Triune window bigger (or smaller) |
| `/ac status` | Print what the bot is doing |
| `/ac restart` | Reload the whole script |
| `/triunerun` | Start/pause - bind this to a key |

---

## When something goes wrong

- **Not moving or pulling?** Look at the Status tab. It shows whether MQ2Nav and MQ2MoveUtils are loaded and whether the zone has a navmesh, with buttons to load or reload them.
- **Stuck on terrain?** Triune remembers where it got stuck and routes around it next time. Clear those spots under **Settings -> Navigation**.
- **Need to report a bug?** Turn on **Log To File** (`/ac log on`) and, when it happens, run `/ac dump`. Attach the files from your MacroQuest `Logs/` folder (`triune_<server>_<char>.log` and `triune_dump_...log`). `/ac debug` prints extra detail to chat.
- **Game feels slow with Lua scripts?** Triune sets MQ2Lua's `turboNum` to 10000 on first start (the default of 500 makes every Lua script crawl). If you set it higher yourself, Triune leaves it alone.
- **A plugin broke?** It is isolated - it shows an error under Settings -> Plugins and the rest keeps running. Fix or disable it there.

---

## Where your files live

All paths are inside your MacroQuest folder.

| File | What it holds |
|---|---|
| `config/triune_loadout_<server>_<char>.lua` | Each character's settings and loadouts. Never overwritten by updates. |
| `config/triune_chat_<Name>.lua` | Chat Windows layout and colours, per character. |
| `Logs/triune_*.log` | Diagnostic logs (when Log To File is on). |
| `lua/triune.lua` | The bot itself. |
| `lua/tac/*.lua` | The plugins listed above. Drop your own `.lua` plugin here and it loads. |
| `lua/TAC_support_modules/webupdate_dll_handoff.lua` | Independent coordinator for verified plugin DLL replacement. |
| `plugins/MQ2WebUpdate.dll` | Generic update backend; load with `/plugin mq2webupdate load`. |
| `resources/gamedb/` | The offline game database (in both release zips). |
| `resources/MQ2Nav/` | Zone navmeshes installed separately from the linked mesh pack. |

---

## Writing a plugin

A plugin is one Lua file in `lua/tac/` that returns a table with an `id`, a `name`, and any of the hooks `onInit(core)`, `onTick()`, `onDrawUI()`, `onDrawSettings()`, `onCommand(cmd, args)`, `onSaveSettings()` and `onLoadSettings(t)`. `core` gives you `mq`, `ImGui`, the live `ctrl` config, `core.log` for logging and `core.delay(ms)` instead of `mq.delay`. Add `plugin.window = { label = 'Mine', flag = 'show_mine' }` and it gets a header button and a place in the window manager. The shipped plugins are the best examples - `cursor.lua` is the smallest.

---

## Links

- [NeroMorte fork releases](https://github.com/XxNeroMortexX/TriuneAutocombat/releases/latest)
- [Gennro official project](https://github.com/gennro/TriuneAutocombat)
- [MacroQuest releases (RoF2)](https://github.com/macroquest/macroquest/releases)
- [Project Triune](https://nms.bestemu.com/)
- [Release notes](RELEASES.md) - short summary per release
- [Change log](CHANGELOG.md) - every change in detail

---

## Version

Current version: **3.1**

See [CHANGELOG.md](CHANGELOG.md) for what changed in each release.


### NeroMorte Nav integration

Morte.6 includes the game-tested NeroMorte MQ2Nav 1.3.3.5 integration. Triune prefers valid Nav routes for Chase and permitted combat approaches. Nav's saved **Auto XYZ in water or while levitating** setting enables the native vertical steering; `/nav ... xyz=on` and `xyz=off` remain route overrides. Triune does not overwrite your Nav settings. A successful close stalled spawn arrival remains settled until the leader moves; cancelled routes do not count as arrival. When Nav cannot approach, clear nearby swimming/levitation approaches use persistent MoveUtils UW fallback.

`MQ2Nav/source/` preserves the reviewed custom Nav sources and `MQ2Nav/Install.ps1` builds a new DLL from the installed 1.3.3.4 test. `tools/install_nav_integration_test.ps1` builds Nav first and switches the Lua test checkout through the existing runtime links. Stop Triune and unload Nav in every client before installation. Backups and exact restore commands are printed.

The verified Windows DLL is published at `MQ2Nav/MQ2Nav.dll`. The Update Manager adds the MQ2Nav mapping to enabled NeroMorte repository profiles automatically. Existing user mappings are retained; no manual repository or file-mapping setup is needed. Download/apply and DLL unload/reload still use the normal updater flow. The binary targets the verified **RoF2 Win32 MacroQuest build**; other client/ABI builds require their own compatible compilation. The published DLL matches its SHA256 release metadata. Future changes must pass game testing and PR checks before main merge. See [Nav build and distribution details](MQ2Nav/README.md).

<!-- Edited By: NeroMorte -->
### Box Network EQBC transport (test)

Connect the standard MQ2EQBC plugin on each PC to the same EQBC server. Select
**EQBC (network)** in Settings → Plugins → Box Network, or use
`/ac net transport eqbc` on each Triune box. `/ac net transport actors` restores
local-only Actors. Existing loadouts default to Actors. Only the selected
transport sends/receives; there is no automatic fallback or duplicate bridging.

Enable EQBC remote control (`/bccmd set control on`) on each participating box.
Optional `/bccmd set silentcmd on` hides MQ2EQBC's incoming command-frame echo.
The EQBC server must be one you trust: the standard EQBC plugin already allows
its connected clients to issue remote commands. Triune's accept-command,
accept-slash and character allowlist settings still apply inside Boxnet.

Existing `/ac net all|zone|group|Name <command>` syntax, peer heartbeats,
Camp Here and RPC ping work through EQBC. `all` excludes the sender; `group`
uses the sender's current in-game group and discovered Triune peers. Other
sections and subscriber messages use the same plain-data protocol. Frames are
bounded and assembled without evaluating Lua; expired requests report routing
failure. Unknown/disabled receivers cannot acknowledge a named command.

Use `/ac net peers`, `/ac net ping Name`, and `/ac net debug` to inspect delivery.
All participating clients need this test revision and the same transport.
On reconnect, the EQBC transport re-announces the character and rebuilds peers.
Local Actors subscribers and mailbox reuse are preserved when switching back.

This transport test retains existing Follow Me behavior (MA + Assist/Chase,
without starting a paused engine). Pure Follow is a separate pending change.

New files: `TAC/lua/TAC_support_modules/boxnet_eqbc.lua`,
`tests/test_boxnet_eqbc.lua`, `tools/install_boxnet_eqbc_test.ps1`.

### BoxNet Connection tab (focused test)

Start EQBCS-Go on one LAN machine and open Triune on each toon. The Connection tab discovers its actual address/port, automatically selects EQBC transport and enables command control. With several servers, select one; the choice is saved. Disconnect switches to local Actors and disables reconnect. Password-protected servers need a password once, saved by MQ2EQBC rather than Triune. Manual address/port entry supports the standard RedGuides server.

LAN discovery requires the NeroMorte MQ2EQBC client and Go server 1.0-NeroMorte.3. Allow UDP 2114 and the server's TCP port through Windows Firewall for the intended network. Internal Triune frames are hidden automatically; ordinary EQBC chat/commands keep their existing settings. The client DLL is pending the focused Windows build and game test; main is unchanged. The updater uses its existing Check/Stage/Apply and verified DLL handoff for all published payloads; it does not replace a running server EXE.
