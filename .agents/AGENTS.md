# TriuneAutocombat — Project Rules for Antigravity

## Project Overview

**TriuneAutocombat** is a MacroQuest ImGui Lua autocombat engine for EverQuest
progression servers. It automates targeting, spell casting, pet management, and
navigation for a "trio" of three EverQuest classes played on one character. It is
written entirely in Lua 5.1 / LuaJIT and runs inside MacroQuest via
`/lua run triune`.

The code is one **core** script, `TAC/lua/triune.lua` (UI, loadout, combat loop,
persistence, and the plugin manager), plus **in-process plugins** in
`TAC/lua/tac/*.lua`. The companion tools that used to be standalone scripts
(map, DPS, inventory, cursor, buffbot, spellbook, ...) are all plugins now: they
run inside the core's Lua state, on its main coroutine, and draw inside its
ImGui callback.

## Plugin Architecture (replaces the old Standalone File Rule)

- **Discovery and loading.** The plugin manager (`initPluginManager` /
  `runtime.pluginManager` in `triune.lua`) lists `lua/tac/` (lfs, else a
  directory listing, else a probe of the known shipped plugin names), runs each
  file's chunk and registers the returned table. A file that returns nothing,
  a non-table, or a table without an `id` / any hook is listed as a stray
  script instead of a plugin. Library modules that live in the folder but are
  `require()`d by the core (`PLUGIN_DIR_LIBRARIES`, currently
  `tac/triune_log.lua`) are skipped by the scanner.
- **A plugin file returns one table**: `id`, `name`, `version`, `author`,
  `description`, `defaultEnabled`, `tickInterval` (seconds, default 0.1),
  `runOutOfCombatOnly`, `hasThread` (run `onTick` in its own fiber), optional
  `uses` (other plugin ids it depends on), optional `window = { label, tooltip,
  flag, desc, headerButton, order }` (its window's `ctrl` visibility flag and
  main-window header button), and `help` lines, plus any of these hooks:

  | Hook | When |
  |---|---|
  | `onInit(core)` | Plugin enabled / (re)loaded. Receives the core API; register events, binds and state here. |
  | `onDestroy()` | Plugin disabled / reloaded / restarted. Release every event and bind made in `onInit`. |
  | `onTick()` | Every `tickInterval` on the main coroutine (or in its fiber with `hasThread`). Must never block. |
  | `onDrawUI()` | Every frame, from the core's ImGui callback. Draw the plugin's windows here. |
  | `onDrawSettings()` | The plugin's panel on the Plugins page. |
  | `onCombatTick(targetId)` | After each core combat-loop pass (current target id, 0 when none). |
  | `onZoned(zoneShort)` | After a zone change. |
  | `onLoadoutSaved()` | After the core saved the loadout. |
  | `onSaveSettings()` / `onLoadSettings(t)` | Plugin settings, persisted in `ctrl.plugins[id].settings`. |
  | `wantsCombatHold()` | Return true to hold the combat loop (e.g. an AA purchase with the AA window open). |
  | `onBetweenPulls()` | Return true when the plugin did work between pulls (the puller waits). |
  | `onCommand(cmd, args)` | `/ac <cmd> ...`; return true when handled. |

- **The core API** (`pm.getCoreApi()`) is the only contract with the core:
  `core.mq`, `core.ImGui`, `core.runtime`, live `core.ctrl` / `core.loadout` /
  `core.petState` / ..., `core.log`, `core.DATA`, theme and window helpers
  (`core.pushTheme`, `core.popTheme`, `core.preBeginWindow`, `core.px`, ...),
  `core.delay(ms, cond)` and `core.defer(label, fn)`. Plugins must not
  `require()` the core or each other; cross-plugin calls go through the core
  API or the Box Network message API.
- **Plugins never block or own MQ entry points.** No `mq.delay` (use
  `core.delay` inside a fiber, or split the work across ticks), no
  `mq.imgui.init` (draw from `onDrawUI`), no `mq.doevents` loop, no
  `mq.exit`. While a plugin chunk loads, `mq.delay` / `mq.bind` / `mq.event` /
  `mq.imgui.init` raise, so a file that uses them at load time is rejected as
  a standalone script. Anything a button triggers that may wait (casting,
  targeting, abilities) goes through `core.defer` so it runs on the main
  coroutine, not inside the render callback.
- **Buffbot stays standalone in scope**: never fold other features into the
  `buffbot` plugin; it is a dedicated buff station.

## Theme Rule

There is exactly **one** theme: `UI.pushTheme()` / `UI.popTheme()` in
`triune.lua`, handed to plugins as `core.pushTheme()` / `core.popTheme()`. Every
plugin window wraps its `ImGui.Begin` ... `ImGui.End` in
`core.pushTheme()` / `core.popTheme()` and uses the colours from `core.colors`.
Plugins must **not** define their own `pushTheme` / `popTheme` or push the theme
colour tuples themselves. `tests/check_theme_consistency.sh` (run by CI)
enforces this. To change the look, edit `UI.pushTheme` only.

## File Map

| File | Role |
|---|---|
| `TAC/lua/triune.lua` | Core: main window UI and theme, loadout, combat loop, persistence, plugin manager. Entry point (`/lua run triune`). |
| `TAC/lua/tac/triune_log.lua` | Library module (`require('tac.triune_log')`), not a plugin: leveled logger, print() tee, diagnostic dump. |
| `TAC/lua/tac/auto_aa.lua` | Auto AA: priority purchasing through the AA window, Fireworks cap spender, Auto AA window. |
| `TAC/lua/tac/auto_accept.lua` | Auto-accept group / trade / expedition invites from whitelisted, group or guild players. |
| `TAC/lua/tac/boxnet.lua` | Box Network (MQ Actors): peer roster, remote `/ac` commands, message API for other plugins. |
| `TAC/lua/tac/buffbot.lua` | Tell-driven buffbot station. |
| `TAC/lua/tac/buttons.lua` | Button Master-style hot button bars. |
| `TAC/lua/tac/chat.lua` | Chat window replacement (filtered tabs, multiple windows). |
| `TAC/lua/tac/cursor.lua` | Cursor item manager. |
| `TAC/lua/tac/dps.lua` | Combat-log DPS parser with its own version number. |
| `TAC/lua/tac/floating_damage.lua` | Floating crit damage numbers (overlay, no window). |
| `TAC/lua/tac/gamedb.lua` | Offline item / NPC / spell database browser (data in `TAC/resources/gamedb/`). |
| `TAC/lua/tac/gm_commands.lua` | EQEmu GM (#) command reference and runner (off by default). |
| `TAC/lua/tac/hud_*.lua` | Popout HUD windows: cooldowns, effects, group, spell gems, unit frames, XTarget. |
| `TAC/lua/tac/inventory.lua` | Inventory / bank manager with offline bank cache and box inventories. |
| `TAC/lua/tac/map.lua` | 2D map, Norrath zone atlas, NPC tracker, camp / waypoint overlays. |
| `TAC/lua/tac/nmsloot.lua` | Personal loot (#nms) console over the Box Network. |
| `TAC/lua/tac/parcels.lua` | Parcel notifier and Collect All. |
| `TAC/lua/tac/spellbook.lua` | Per-class spell browser and mem-to-gem queue. |
| `TAC/lua/tac/update_check.lua` | GitHub release check (non-blocking, no external process). |
| `TAC/config/triune_data.lua` | Era-correct spell/disc/AA database (generated, not hand-edited). |
| `TAC/resources/gamedb/` | Game database files, built by `tools/build_gamedb.py` from the server SQL dump. |
| `tests/test_pure_logic.lua` | Unit tests (`luajit tests/test_pure_logic.lua`); test the real functions via `loadFunc` / plugin loading, not local copies. |
| `tests/check_theme_consistency.sh`, `tests/ci_local.sh` | Theme check; local run of every CI check. |
| `CHANGELOG.md` | Full history of changes, newest date first. |
| `RELEASES.md` | Short per-release summary (`## <version>`), used for the GitHub release body. |
| `README.md` | User-facing documentation including commands, features, file structure. |

> **Note:** `triune_loadout_<server>_<char>.lua` and the plugins' settings are written to the MQ config directory at runtime — they are NOT in this repo.


---

## MANDATORY: CHANGELOG.md Update Rule

**After every meaningful code change, you MUST update `CHANGELOG.md`.**

"Meaningful" includes: bug fixes, new features, refactors, new helpers, UI changes,
performance improvements, new slash commands, new config fields, or any behavioral change.

### CHANGELOG Format

```markdown
## YYYY-MM-DD

- Short present-tense description of change.
  - Sub-bullet for implementation detail if needed.
- Another change on the same date.

> **TLDR:** One-sentence summary of the day's changes (optional, for large batches).

---
```

Rules:
- Dates are always `YYYY-MM-DD` format (current local date).
- Newest date goes at the **top** of the file, below the `# Triune AutoCombat Change Log` heading.
- Each bullet describes **what changed and why**, not just what the code does.
- Sub-bullets explain implementation choices when the top-level bullet alone is unclear.
- The `---` horizontal rule separates date sections.
- If the current date section already exists, **append new bullets to it** rather than creating a duplicate date section.

---

## MANDATORY: README.md Update Rule

**Update `README.md` whenever any of the following change:**

- A new combat mode is added (update the mode table in Features)
- A new slash command is added (update the Commands table)
- The file structure changes (update the File Structure block)
- A new major feature section is added (add a new `###` subsection)
- The version number changes (update the "Current version:" line at the bottom)

### Version Number Locations

The canonical version is defined in `TAC/lua/triune.lua`:
```lua
local VERSION           = '3.2'
```

The README must always reflect this value:
```markdown
Current version: **3.2**
```

When you bump the version, update `TAC/lua/triune.lua` and the `README.md`.
CI (`.github/workflows/ci.yml`) fails if these drift apart, and the release
workflow refuses a tag that does not match `VERSION` or has no `## <version>`
entry in `RELEASES.md`.

### Binary Files Policy (Do NOT use Git LFS)

The committed binary / large data files (MQ2Nav navmeshes, `ItemDB.txt`, the
`gamedb` data files, etc.) must stay as regular git objects. Do NOT migrate them to Git LFS: GitHub source archives
and `git archive` emit LFS *pointer files* instead of real content, which would
corrupt every distribution path (release zips, repo ZIP downloads, and
release asset downloads).

---

## Lua Compatibility Rules

This project runs on **Lua 5.1 / LuaJIT** inside MacroQuest. Do NOT use:

- `//` (integer division — not valid in Lua 5.1; use `math.floor(a/b)`)
- `|`, `&`, `~` bitwise operators — use the `bit` library: `bit.bor()`, `bit.band()`, etc.
- `<< >>` shift operators — use `bit.lshift()`, `bit.rshift()`
- `goto` — LuaJIT accepts it, but Lua 5.1 does not, and CI compiles every file
  with `luac5.1` as well as LuaJIT, so `goto` (and `::labels::`) fail the build
- String methods not in 5.1 (`string.pack`, `utf8`, etc.)

Prefer:
- `pcall()` guards around all TLO (Top Level Object) accesses — they can return nil unexpectedly
- `local` for every variable; never rely on implicit globals
- Explicit `nil` checks before indexing any MQ TLO result

---

## MacroQuest API Conventions

### TLO Access Pattern
```lua
-- GOOD: pcall guard prevents crashes on nil/missing spawns
local ok, val = pcall(function() return mq.TLO.Me.Gem(slot).Name() end)
if ok and val then ... end

-- BAD: direct access crashes if TLO returns nil unexpectedly
local val = mq.TLO.Me.Gem(slot).Name()
```

### ImGui Thread Safety & Window Rules
- **Never call `mq.delay()` from an ImGui render callback** — it is a non-yieldable thread and will crash with "Cannot delay from non-yieldable thread".
- Queue actions via a `pending*` flag (e.g., `reDetectRequested`, `pendingAction`) and execute them in the main coroutine loop.
- Pattern used in `tac/cursor.lua` (pendingAction) and `triune.lua` (reDetectRequested). Plugins can also hand the work to `core.defer(label, fn)`.
- **Unique Element & Table IDs across Windows**: Every ImGui table, child window, tab bar, or button rendered in the same frame MUST have unique string IDs (e.g. `InspectTable` vs `MainTable`). Duplicate IDs across separate windows cause ImGui ID collisions, freezing inputs and routing clicks to the wrong window.
- **No Nested `ImGui.Begin()` Window Callbacks**: Never call `ImGui.Begin()` for a secondary window inside the render callback of a primary window (between its `ImGui.Begin()` and `ImGui.End()`). Nested `ImGui.Begin()` calls corrupt ImGui's focus stack, causing buttons, tab bars, and titlebar `X` close buttons on the secondary window to freeze. Draw each top-level window as its own `Begin` ... `End` pair, one after the other (in the core: its own `mq.imgui.init` callback; in a plugin: sequentially inside `onDrawUI` — plugins may not call `mq.imgui.init`).
- **Secondary Window Focus & Inspectors**: Secondary top-level windows in MQ Lua do not automatically steal mouse focus from the main window, causing clicks on secondary window controls to freeze or fall through. To present detailed inspection UI, use **In-Tab Detail Views** (with a `< Back to List` button) or **ImGui Modal Popups** (`ImGui.BeginPopupModal` / `ImGui.OpenPopup`), which force 100% input focus and guarantee responsive clicks.
- **Window Close Tuple Handling & Safe Exit**: `ImGui.Begin(title, openFlag)` returns `open, draw`. When `open` returns false (titlebar `X` button clicked), update the open flag state, call `ImGui.End()`, and return cleanly. `ImGui.End()` MUST be called once for every `ImGui.Begin()` call. **NEVER call `mq.exit()` or `mq.imgui.destroy()` inside an ImGui draw callback or event handler** — destroying the Lua context mid-render triggers a Fatal C++ Access Violation Crash in MacroQuest/EverQuest. Set `isRunning = false`, return cleanly, and let the main script coroutine loop exit naturally outside the callback.
- **Window Corner Rounding & `ImGuiWindowFlags.NoCollapse`**: Do NOT pass `ImGuiWindowFlags.NoCollapse` to `ImGui.Begin()`. In MacroQuest ImGui, passing `NoCollapse` overrides the theme's `WindowRounding` style token and forces ImGui to render a square window frame with sharp 90-degree titlebar corners. Omit `NoCollapse` (or use `ImGuiWindowFlags.AlwaysUseWindowPadding`) so `ImGuiStyleVar.WindowRounding` (e.g. 6.0) applies rounded corners to top-level windows.
- **Sequential Toolbar Layout (No Hardcoded Offsets)**: Avoid hardcoded x-position offsets like `ImGui.SameLine(390)` for toolbars. Hardcoded offsets collide and overlap when window width or button labels change. Use sequential `ImGui.SameLine()` without arguments for toolbars.
- **Child Window Lifetime & Unconditional `ImGui.EndChild()`**: In Dear ImGui, `ImGui.BeginChild()` pushes onto the window stack whether it returns `true` or `false`. A matching `ImGui.EndChild()` MUST ALWAYS be called unconditionally OUTSIDE of any `if ImGui.BeginChild(...) then ... end` block. Nesting `ImGui.EndChild()` inside the `if` causes skipped child window closures whenever the child window is clipped or culled, causing the outer parent window's `ImGui.End()` to trigger a fatal C++ crash: `Must call EndChild() and not End()! ImGui Critical Failure: Missing EndChild()`.
- **ImGui Tooltip Format String Safety (`ImGui.SetTooltip`)**: `ImGui.SetTooltip(fmt, ...)` treats its first argument as a `printf`/`string.format` specifier. Any literal `%` symbol (such as `100%`, `%d%%`, or `HP %`) in single-argument tooltips triggers a fatal Lua runtime error (`invalid option '%. ' to 'format'`). ALWAYS pass tooltip strings using an explicit format specifier: `ImGui.SetTooltip('%s', text)` or escape all percent characters as `%%`.

### Command Execution
```lua
mq.cmd('/command arg')       -- fire and forget
mq.cmdf('/command %s', arg)  -- formatted string version
```

### Event Handling
- Register chat events with `mq.event('name', 'pattern', handler)`
- `mq.doevents()` is called by the core's main loop; plugins register events in `onInit`, unregister them (`mq.unevent`) in `onDestroy`, and never run their own `doevents` loop

---

## State Table Conventions

All runtime state of the core is stored in **five structured tables** (not bare locals), alongside `loadout` (the saved spell/AA/disc lists) and `UI` (draw helpers):

| Table | Purpose |
|---|---|
| `ctrl` | User-configurable control surface (mode, settings, thresholds). Persisted. |
| `runtime` | Transient combat/loop state (timestamps, pending flags, last-cast tracking). |
| `petState` | Pet management state (pet list, last command, manual hunter hold). |
| `pursuit` | Navigation/targeting state (target id, nav stalls, wander loc, unreachable set). |
| `stuckState` | Anti-stuck system state (position history, counters, recovery timestamps). |

When adding new state, always add it to the appropriate table — never add a bare top-level local (Lua 5.1 main chunk has a 200-local limit that was already hit once in this project).

### MANDATORY: Lua 5.1 Main Chunk 200 Local Variables Limit Rule

**In Lua 5.1 / LuaJIT, the main chunk (and any function) cannot exceed 200 local variables (`MAXVARS`).**
- Top-level `local function name(...)` statements count as local variables in the main chunk.
- Top-level `local var = ...` statements count as local variables in the main chunk.
- Block locals at the file level (e.g. inside file-level `if ... end` blocks) count against the main chunk's active register slots.
- **NEVER define bare top-level functions or state when extending `triune.lua`.** Attach functions and state to `runtime` (e.g., `function runtime.myHelper(...)`), `UI` (e.g., `function UI.myWindow(...)`), or other structured tables.
- **ALWAYS verify local variable counts with `luac -l -p TAC/lua/triune.lua`**: Verify that the main chunk slots count is well below 200 (target `<= 185`). CI automatically enforces `luac -p` compilation and unit tests verify this threshold.


---

## Code Style

- Section headers use `-- ====` / `-- ----` banner comments as present throughout the files.
- Color constants use descriptive names: `GOOD`, `WARN`, `ERR`, `ARC`, `GOLD`, `MUTED`.
- The unified dark theme lives only in `UI.pushTheme` / `UI.popTheme` in `triune.lua`;
  plugins call `core.pushTheme()` / `core.popTheme()` and never carry a copy (see Theme Rule).
- Class abbreviations always use the mixed-case data-file format: `War`, `Clr`, `Pal`, `Rng`, `SK`, `Dru`, `Mnk`, `Brd`, `Rog`, `Shm`, `Nec`, `Wiz`, `Mag`, `Enc`, `Bst`, `Ber`.


## Macroquest Lua Definitions
Located here /home/gennro/Documents/github/mq-definitions/