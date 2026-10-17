# Triune AutoCombat Releases

Short, human-readable notes for each release. The GitHub release page is built
from the entry that matches the tag (`v3.0` -> `## 3.0`). The full, detailed
history of every change stays in [CHANGELOG.md](CHANGELOG.md).

## 3.2-Morte.11-test

Test integration of Gennro 3.2 with NeroMorte's existing features. Keep the current Global/zone NPC list UI, JSON sharing and management, Manual/MA target ownership, fixed Camp radius, optional pet return, XYZ movement, EQBC connections, updater mappings and verified AA purchase guards. Add upstream casting/healing, chat, inventory, map, persistence and performance fixes, plus optional GM Commands. Upstream pet reconciliation does not replace the fork's unique remaining pet/class inference. No change to MQ2WebUpdate engine binaries; native gameplay validation is pending.

---

## 3.1-Morte.10

Cumulative October 13 NeroMorte update, based on Gennro **3.1**. Includes the current
verified RoF2 Win32 MQ2WebUpdate **4.1.8**, MQ2Nav **1.3.3.5**, and EQBC discovery payloads.

- Fix Auto AA order sorting, exact purchase-row checks, duplicate Train actions and queued combat guards.
- Fix Bot Net Connection crashes caused by unevaluated indexed EQBC values; render literal wrapped text.
- Propagate plugin render errors to MacroQuest's overlay handler safely.
- Camp uses its fixed Pull Radius circle for XTargets and movement, with no competing chase slider.
- Ordinary Camp fights at the mob. Stationary pets return mobs only through the visible checked pet return option.
- Fresh pulls choose nearest eligible reachable mobs across the allowed height range; similar elevation only breaks close ties.
- Keep current fights and XTarget lowest-HP priority; distinguish an attack toggle from an engaged target during approach.
- Include Hunt map/radius updates, consistent distant-group gates and improved diagnostic selection details.
- Retain the completed per-zone Attack/Ignore sharing, management and updater improvements from Morte.9 and earlier.

James authorizes this cumulative main release. Connection and AA order controls have
game confirmation; Camp/nearest pulling has positive game feedback. Actual AA buying
and remaining group/Hunt/pet/radius cases are not all game-verified. Repository checks
validate code behavior, not every live server case.

Existing installations should use the in-game updater against **main**. These notes
approve main updates; they do not publish a new first-install archive. Preserve character
settings. Native binaries require the matching RoF2 32-bit MacroQuest build.

---

## 3.1-Morte.5

September 30 cumulative NeroMorte update. Gennro's base remains **3.1** and
MQ2WebUpdate remains **4.1.6**.

- Stationary pet camp combat, separate Player Assist Radius, optional batch
  pet pulls back to camp, and a saved recall delay (default 5 seconds).
- Cached pet-button states and corrected pet class dispatch; confirmed XTarget
  pulls and completed fights before fresh pulls.
- Optional tell/addressed-guild invite and dzadd commands.
- Expanded distance sliders and Auto AA Bank minimum 1.
- True Self-target spells preserve the current target.
- Native EQ camp X/radius circle, automatic camp refresh, and precise slider redraw.
- Debug-only pet-command output and optional quiet Auto AA purchase/skip messages.
- Fixed the Control-window recall-delay input crash.

See the [full September 30 changelog](docs/changelog/2026-09-30-Morte.5.md)
for behavior and validation details. Update from **main** using the in-game
updater; development links remain protected. The original Morte.1 installer
baseline/tag is retained. These notes do not publish a new installer archive.

---

## 3.1-Morte.1

First installer release for NeroMorte's Triune fork, based on Gennro 3.1 and
the current upstream main, including the Med Break group-combat option.

### In-game updates

- **MQ2WebUpdate 4.1.6** ships in `plugins/` with the Lua Update Manager and
  independent DLL coordinator. On first launch, load it with
  `/plugin mq2webupdate load` and open **Updates** in Triune.
- The updater checks the NeroMorte Main Download repository and monitors
  Gennro Official. It shows file plans, protects linked files, verifies staged
  downloads, applies changed Lua files, and can safely replace its own DLL.
- Plugin mappings, repository roles, and destinations are editable in the GUI
  and saved in the updater profile INI. Existing character settings are not
  included in the release archive.

For a first install, extract `TriuneAutocombat-Install.zip` at the MacroQuest
root. It puts files directly under `lua/`, `config/`, `resources/`, and
`plugins/`. MQ2Nav navmeshes are not bundled: download the
[complete mesh pack](https://mqmesh.com/resources/zips/MQ2Nav_meshes.zip)
separately and extract its `.navmesh` files into MacroQuest's
`resources/MQ2Nav/` folder. After installation, use the in-game updater.
## 3.2

A fix-and-hardening release from a full code review, plus one new (opt-in)
plugin. Drop-in update from 3.1. A few behaviours changed on purpose; they are
listed under **Changed**.

### New

- **GM Commands plugin** (`/ac gm`, off by default). A searchable reference and
  runner for the server's `#` GM commands with argument boxes, a quick bar,
  history and favourites. Destructive commands ask first; password and
  login-server commands are never saved or echoed.
- **NMS Looter Handoff plugin** (off by default): hands the active-looter role
  between your boxes by priority, in all zones or dynamic zones only.
- **High Priority spells.** Mark emergency heals, lifetaps or other Spell Gems
  to be checked right after Abilities, before clickies.
- **Boss option for Spell Gems and AAs**: fire only on named mobs.
- **Ordered self/group targets** (Me, then Group / Group, then Me) for spells,
  discs and clickies.
- **Puller: Universal and per-zone Pull / Ignore lists** with a zone NPC
  picker.
- **Waypoint patrol combat anchors** and redesigned node settings.
- **Med Break can ignore group combat.**

### Fixed

- **Targeting an NPC no longer counts as combat.** Clicking a merchant or
  conning a distant mob used to fire in-combat rules and repositioning.
- **"You have entered an area where levitation..." no longer acts like a zone
  change** (it paused the bot and cleared the camp and lockouts).
- **Heals no longer freeze movement or stand you up** when the chosen heal
  cannot fire; the next eligible heal is tried.
- **Buffs on groupmates and pets are recast when they wear off** (non-bard
  "missing buff" entries were cast once per life).
- **Puller (Hunt) closes on XTargets out to the Hunt radius** instead of
  marking them unreachable.
- **Player chat can no longer trigger** the "too far away", "can't see your
  target", line-of-sight, crit DoT / heal floaters or DPS melee parsing.
- **Settings that did not save:** Clickies-tab edits, Min XT on Disciplines /
  Abilities. The Pull Spell no longer resets to gem 1.
- **Memorizing an unscribed spell no longer empties the gem first.**
- **Switching characters** saves the old character first and no longer copies
  its data into the new one.
- **Swarm pets and familiars are not mistaken for your main pet.**
- **Map NPC tracker no longer re-targets the selected mob every frame**, and a
  click on the map no longer turns Follow off.
- **Game Database prefix search no longer skips names.**
- **Hot Buttons: a set named `end`, `for`, etc. no longer wipes the button
  library.** A library that fails to load is kept as `.corrupt` and saving is
  paused until you reload or `/ac btn reset confirm`.
- **Cursor Manager only destroys the exact item you confirmed.**
- **Inventory give never trades equipped gear** unless you picked that slot, a
  cancelled trade is reported as failed, and drag-and-drop onto an occupied
  slot completes the swap.
- **DPS meter counts only your damage** (not other players' damage shields,
  nukes or pets).
- **Auto AA stops reopening the AA window** for rows that are maxed or
  unaffordable.
- **Chat Windows: mute / unmute apply to lines already shown**, history is never
  wiped by Clear notifications, and native item-link clicks are no longer
  hijacked while the chat is hidden.
- **One error in a chat event no longer stops the script.**
- **Self-targeted cures during combat** no longer drop your hostile target.

### Changed

- **Auto-Accept trusts exact names only** (stored IDs no longer authorize), and
  expedition invites are accepted only when the dialog's own sender is
  whitelisted.
- **Box Network trust now gates** inventory snapshots, remote trade-accept and
  group-scoped Camp Here; a remote NMS Destroy needs Arm Destroy on the
  receiving box.
- **Entering a zone with no saved waypoint route clears the live route.**
- **Buffbot caps queued tells** and answers thank-yous / bans at most once per
  few minutes per player.
- **Cursor Manager: tick Confirm Destroy again for each destroy.**

---

## 3.1

A bug-fix release for 3.0. No new plugins; if you are on 3.0 this is a
straight drop-in update.

### Fixed

- **Box Network: crash in mq2lua.dll.** Pressing a group- or single-box Box
  Control button more than once (or any `/ac net group ...` / `/ac net Bob ...`
  command, ping, buffme) could crash the client. The RPC reply was read after
  MacroQuest had already freed it; it is now read immediately.
- **Box Network: `/ac net all /camp` runs `/camp`.** A full slash command sent
  over the network now runs on the boxes exactly as typed instead of being
  mangled into an `/ac` command.
- **Effects & Songs / Spell Gems: wrong buff totals and missing rows.** Buff
  durations were read through a string fallback that mistook ticks for
  seconds, so a 60-minute buff showed as 600 s and a 2h30 buff as 1.5 s with
  the bar pinned full; disc reuse timers past 50 minutes had the same hole.
  The Effects window also walks all 42 buff slots and shows the running
  discipline, and the Spell Gem bar no longer trusts `Me.NumGems` alone.
- **Auto AA: priorities are bought first.** Checked priority abilities are
  trained before the fireworks cap spender gets to spend anything; the spender
  no longer runs while a priority is still saving up.
- **Puller (Hunt): the Combat Radius Anchor is a hard limit.** XTarget adds and
  chases no longer drag the character outside the anchor circle.
- **Manual mode: with Stick to Target off, a selected hostile in reach is
  fought** instead of being ignored until something else engaged it.
- **Floating Damage: melee, ranged and skill crits float.** Only spell and heal
  crits used to show.
- **Chat Windows: NPC dialogue links answer the NPC** (`[ready]`,
  `[Non-Respawning]` and other EQEmu saylinks) instead of searching for an
  item.
- **Chat Windows: every tab keeps its own history**, so guild / ooc lines are
  no longer pushed out by one fight's combat spam.
- **Parcels: Collect All works on UIs where Parcels is not the third tab**, and
  the parcel list shows Item / Qty / From / Sent / Note in the right columns.
- **Navigation: a character stranded on a navmesh island no longer waits
  forever.**

### Improved

- **Hot Buttons: custom Box Network commands** and a single-box scope on the
  Box Control tab of the Add From Game browser.
- **Chat Windows: NMS loot lines get their own channel.**

---

## 3.0

The biggest update yet. Triune is now a plugin system: every window and tool is
its own file in `lua/tac/`, can be turned on or off under **Settings -> Plugins**,
and a broken plugin no longer takes the bot down with it.

### New

- **Box Network** - your Triune instances on one PC now talk to each other over
  MacroQuest Actors (nothing extra to install). Assist boxes follow the main
  assist's real target, pullers stay off each other's mobs, boxes count as
  allies for cures and buff requests, and `/ac net all <command>` runs a command
  on every box.
- **Chat Windows** (`/tacchat`) - a full chat window replacement: tabs, filters,
  colours, highlights, a Tells window, `@Name` completion, input history,
  clickable item / spell / NPC links, and tells that survive a crash.
- **Game Database** (`/ac db`) - an offline copy of the server's items, NPCs and
  spells with search, item filters and a Spell Info replacement window. Ships in
  `resources/gamedb/` (included in the update zip).
- **Hot Buttons** (`/ac btn`) - Button Master-style hotbars with cooldown
  overlays, share strings and Group / Zone / All box-control buttons.
- **NMS Loot** (`/ac nms`) - the server's `#nms` personal loot system as a
  window, shared across your boxes.
- **Inventory & Bank: Box Inventories** - see every box's bags and hand items
  between characters from one window.
- **Parcels** (`/ac parcels`) - tells you when parcels arrive and collects them
  all at a parcel merchant.
- **Update Checker** (`/ac update`) - tells you when a newer release is out.
  Nothing is downloaded automatically.
- **Group DPS meter** in the DPS Parser, fed by the Box Network.
- **Floating Damage 2.0** - impact pops, damage tiers, combos and records.
- **Diagnostic logging** - `/ac log on` writes to a file in `Logs/`, `/ac dump`
  saves a one-shot state dump for bug reports.

### Improved

- **Every window**: one right-click menu, hide title bar, ghost fade, and a
  global UI scale (`/ac scale 1.25`).
- **Target & Player HUD**: cast bars, every pet you own, and the target frame
  as its own popout window.
- **Extended Target**: per-spawn Force / Ignore toggles; pets and friendly
  players are hidden.
- **Manual mode**: stick-to-target and auto-nav are optional, and another
  character's fights no longer count as your combat.
- **Ranged and Spell combat styles** are back (`/ac style melee|ranged|spell`).
- **Multi-pet tracking**: one pet per class, no duplicates, no re-summon loops.
- **Auto AA** no longer needs MQ2AAspend - every purchase goes through the AA
  window - and fireworks are summoned only after the AA is actually bought.
- **Navigation**: a character stranded on a navmesh island no longer waits
  forever; the map draws player movement smoothly.
- **Compact Mini HUD** reworked, with Ghost mode as its own option.
- Only heals cast through a hostile target; everything else selects the caster.
- Separate *has Poison* and *has Disease* triggers.

### Removed

- The popout Character Stats / Inventory / Currency window (the Inventory &
  Bank plugin replaces it).
- The standalone companion scripts (`triune_spellbook.lua`, map, DPS, inventory,
  buffbot, cursor) - they are all plugins now and open from the header buttons.
- The MQ2AAspend dependency for Auto AA.

---
