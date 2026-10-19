-- Edited By: NeroMorte - Integrate Gennro 3.2 fixes while preserving this fork's behavior.
---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- ============================================================================
-- TAC/lua/tac/gm_commands.lua — Triune GM Commands Plugin
-- ============================================================================
-- A reference and runner for the EQEmu server's `#` GM commands. Off by
-- default: it only does anything for an account with GM status, and a normal
-- player has no use for the window.
--
--  * Reference. Every `#command`, its subcommands, arguments, aliases and the
--    account status table, searchable and grouped by what the command works
--    on (travel, players, NPCs, spawns, corpses, zone editing, accounts,
--    server, find / set / show).
--  * Runner. Pick a command (and subcommand), fill the argument boxes - the
--    boxes come from the `[...]` tokens of the syntax line, with helpers that
--    drop in your target's name, the current zone or your location - and the
--    line is sent the way the game sends it: `/say #command args` (EQEmu
--    picks `#` lines out of say before they reach the zone). A free-form
--    line box takes anything else.
--  * Safety. Commands that ban, delete, wipe or shut things down are marked
--    and, with Confirm on (default), ask first. Every sent line lands in a
--    history that can be re-run or pinned as a favourite, and `/ac gm <line>`
--    runs a line from a hot button or over the Box Network.
--
-- Nothing here reads the server's replies; they arrive in chat as usual.
-- ============================================================================

local plugin = {
    id                 = 'gm_commands',
    name               = 'GM Commands',
    version            = '1.0.0',
    author             = 'Triune',
    description        = 'EQEmu GM (#) command reference and runner: search every command, fill in its arguments, run it, keep favourites. Off by default; needs GM status on the account.',
    defaultEnabled     = false,
    tickInterval       = 0.5,
    runOutOfCombatOnly = false,
    hasThread          = false,
    window             = { label = 'GM', tooltip = 'Toggles the GM Commands window (gm_commands plugin).', flag = 'show_gm_commands', key = 'gm_commands', desc = 'EQEmu GM command reference and runner', headerButton = false, order = 96 },
}

local core = nil  ---@type table
local ctrl, ImGui, mq = nil, nil, nil  ---@type table, table, table

local HISTORY_MAX_DEFAULT = 30
local HISTORY_MAX_CAP = 100
local FAVORITES_MAX = 60
local POLL_SEC = 0.5

-- ============================================================================
-- Reference data
-- ============================================================================
local STATUS_LEVELS = {
    { 0, 'Player' }, { 1, 'ApprenticeGuide' }, { 2, 'Guide' }, { 3, 'QuestTroupe' }, { 4, 'Steward' },
    { 5, 'Apprentice GM' }, { 80, 'GMAdmin' }, { 81, 'GMAreas' }, { 85, 'GMLeadAdmin' }, { 90, 'GMMgmt' },
    { 95, 'GMCoder' }, { 100, 'GMMgmt' }, { 150, 'GMImpossible' },
}

local CATEGORIES = {
    'Travel & Zones',
    'Players & Characters',
    'Appearance & Effects',
    'NPCs & AI',
    'Spawns, Grids & Paths',
    'Corpses',
    'Zone Editing',
    'Factions, Guilds & Tasks',
    'Accounts & Moderation',
    'Server & Admin',
    'Find',
    'Set',
    'Show',
    'Misc',
}

-- Each command: name, syntax line, description, options
--   cat     category (above)
--   target  'npc' (needs an NPC target), 'pc' (a player target),
--           'any' (yourself or your target), 'self'
--   danger  asks for confirmation when Confirm is on
--   subs    { syntax, desc, { danger = true, aliases = {...} } }
--   aliases other # names for the same thing
--   note    extra line under the description
local COMMANDS = {}
local BY_NAME = {}
local function E(name, syntax, desc, o)
    o = o or {}
    local e = {
        name = name, syntax = syntax, desc = desc, cat = o.cat or 'Misc',
        target = o.target, danger = o.danger == true, subs = o.subs, aliases = o.aliases, note = o.note,
    }
    COMMANDS[#COMMANDS + 1] = e
    BY_NAME[name] = e
    return e
end
--   secret  the line carries credentials: never kept in history / favourites,
--           echoed redacted, refused from /ac gm (it can arrive over the Box Network)
local function S(syntax, desc, o) return { syntax = syntax, desc = desc, danger = o and o.danger == true, secret = o and o.secret == true, aliases = o and o.aliases } end

-- Travel & Zones ---------------------------------------------------------------
E('zone', '#zone [Zone ID|Short Name] [X] [Y] [Z]', 'Teleport to a zone by ID or short name. Coordinates are optional.', { cat = 'Travel & Zones' })
E('goto', '#goto [Player Name | X] [Y] [Z] [H]', 'Teleport to a player by name, or to coordinates.', { cat = 'Travel & Zones' })
E('gmzone', '#gmzone [Zone ID|Short Name] [Version] [Instance Identifier]', 'Zone to a private GM instance. Version defaults to 0, identifier defaults to gmzone.', { cat = 'Travel & Zones' })
E('peqzone', '#peqzone [Zone ID|Short Name]', 'Teleport to a zone if you meet requirements (player-accessible).', { cat = 'Travel & Zones' })
E('zoneinstance', '#zoneinstance [Instance ID] [X] [Y] [Z]', 'Teleport to a zone instance by ID. Coordinates optional.', { cat = 'Travel & Zones' })
E('zoneshard', '#zoneshard [Zone] [Instance ID]', 'Teleport explicitly to a zone shard.', { cat = 'Travel & Zones' })
E('summon', '#summon [Character Name]', 'Summon a corpse, NPC, or player to you. Optionally name a player.', { cat = 'Travel & Zones', target = 'any' })
E('loc', '#loc', 'Print your or your target\'s current location and heading.', { cat = 'Travel & Zones', target = 'any' })
E('movechar', '#movechar [Char ID|Name] [Zone ID|Short Name]', 'Move an offline character to the specified zone.', { cat = 'Travel & Zones' })
E('instance', '#instance', 'Manage zone instances.', { cat = 'Travel & Zones', subs = {
    S('add [Instance ID] [Name]', 'Add a character to an instance'),
    S('create [Zone ID|Short Name] [Version] [Duration]', 'Create a new instance'),
    S('destroy [Instance ID]', 'Destroy an instance', { danger = true }),
    S('list [Name]', 'List instances for a character'),
    S('remove [Instance ID] [Name]', 'Remove a character from an instance'),
} })
E('dz', '#dz', 'Manage expeditions and dynamic zone instances.', { cat = 'Travel & Zones', subs = {
    S('cache reload', 'Reload all dynamic zones from the database'),
    S('destroy [ID]', 'Destroy a dynamic zone by ID', { danger = true }),
    S('list', 'List all dynamic zones in the zone cache'),
    S('listdb [all]', 'List dynamic zones from the database; all includes expired'),
    S('lockouts', 'Manage lockouts'),
} })

-- Players & Characters ---------------------------------------------------------
E('grantaa', '#grantaa [Level]', 'Grant all available AA points up to the specified level. Omit level to grant all AAs.', { cat = 'Players & Characters', target = 'any' })
E('resetaa', '#resetaa [aa|leadership]', 'Reset a player\'s AAs or Leadership AAs and refund them to unspent.', { cat = 'Players & Characters', target = 'any', danger = true })
E('resetaa_timer', '#resetaa_timer [All|Timer ID]', 'Reset AA cooldown timers for yourself or your target.', { cat = 'Players & Characters', target = 'any' })
E('resetdisc_timer', '#resetdisc_timer [All|Timer ID]', 'Reset discipline timers.', { cat = 'Players & Characters', target = 'any' })
E('scribespell', '#scribespell [Spell ID]', 'Scribe a spell into your or your target\'s spellbook.', { cat = 'Players & Characters', target = 'any' })
E('scribespells', '#scribespells [Max Level] [Min Level]', 'Scribe all usable spells up to the specified level.', { cat = 'Players & Characters', target = 'any' })
E('unscribespell', '#unscribespell [Spell ID]', 'Unscribe a spell from your or your target\'s spellbook.', { cat = 'Players & Characters', target = 'any' })
E('unscribespells', '#unscribespells', 'Clear your or your target\'s entire spellbook.', { cat = 'Players & Characters', target = 'any', danger = true })
E('memspell', '#memspell [Spell ID] [Gem]', 'Memorize a spell into the specified gem slot for yourself or your target.', { cat = 'Players & Characters', target = 'any' })
E('unmemspell', '#unmemspell [Spell ID]', 'Unmemorize a spell by ID for yourself or your target.', { cat = 'Players & Characters', target = 'any' })
E('unmemspells', '#unmemspells', 'Unmemorize all spells for yourself or your target.', { cat = 'Players & Characters', target = 'any' })
E('traindisc', '#traindisc [Level]', 'Train all disciplines usable by the target up to the specified level.', { cat = 'Players & Characters', target = 'any' })
E('untraindisc', '#untraindisc [Spell ID]', 'Untrain a discipline from you or your target by spell ID.', { cat = 'Players & Characters', target = 'any' })
E('untraindiscs', '#untraindiscs', 'Untrain all disciplines from your target.', { cat = 'Players & Characters', target = 'any', danger = true })
E('exptoggle', '#exptoggle [Toggle]', 'Toggle experience gain for yourself or your target.', { cat = 'Players & Characters', target = 'any' })
E('givemoney', '#givemoney [Platinum] [Gold] [Silver] [Copper]', 'Give money to yourself or your player target.', { cat = 'Players & Characters', target = 'any' })
E('takeplatinum', '#takeplatinum [Amount]', 'Take platinum from yourself or your player target.', { cat = 'Players & Characters', target = 'any' })
E('giveitem', '#giveitem [Item ID] [Charges]', 'Summon an item onto your target\'s cursor. Charges optional.', { cat = 'Players & Characters', target = 'pc' })
E('summonitem', '#summonitem [Item ID] [Charges]', 'Summon an item onto your cursor. Charges optional.', { cat = 'Players & Characters', target = 'self' })
E('nukeitem', '#nukeitem [Item ID]', 'Remove a specific item from your or your target\'s inventory.', { cat = 'Players & Characters', target = 'any', danger = true })
E('removeitem', '#removeitem [Item ID] [Amount]', 'Remove an item by ID from your or your target\'s inventory. Amount defaults to 1.', { cat = 'Players & Characters', target = 'any', danger = true })
E('countitem', '#countitem [Item ID]', 'Count how many of a specific item are in your or your target\'s inventory.', { cat = 'Players & Characters', target = 'any' })
E('emptyinventory', '#emptyinventory', 'Clear your or your target\'s entire inventory (equipment, general, bank, shared bank).', { cat = 'Players & Characters', target = 'any', danger = true })
E('gearup', '#gearup', 'Developer tool to quickly equip yourself or your target.', { cat = 'Players & Characters', target = 'any' })
E('nukebuffs', '#nukebuffs [Beneficial|Detrimental]', 'Strip all buffs from yourself or your target. No argument removes all buffs.', { cat = 'Players & Characters', target = 'any' })
E('castspell', '#castspell [Spell ID] [Instant]', 'Cast a spell. Instant defaults to 1 (true). Example: #castspell 1 1', { cat = 'Players & Characters' })
E('castspellnms', '#castspellnms [Spell ID|Spell Name]', 'Cast a spell from your spellbook out of combat.', { cat = 'Players & Characters' })
E('alttoggle', '#alttoggle [AA ID]', 'Toggle the effectiveness of a passive AA by AA ID.', { cat = 'Players & Characters', target = 'self' })
E('myskills', '#myskills', 'Show your current skill levels.', { cat = 'Players & Characters', target = 'self' })
E('mystats', '#mystats', 'Show stats for yourself or your pet.', { cat = 'Players & Characters', target = 'self' })
E('hp', '#hp', 'Refresh your HP bar from the server.', { cat = 'Players & Characters', target = 'self' })
E('refreshgroup', '#refreshgroup', 'Refresh your group data from the server.', { cat = 'Players & Characters', target = 'self' })
E('clearxtargets', '#clearxtargets', 'Clear your extended targets list.', { cat = 'Players & Characters', target = 'self' })
E('interrupt', '#interrupt [Message ID] [Color]', 'Interrupt your current cast. Arguments are optional.', { cat = 'Players & Characters', target = 'self' })
E('illusionblock', '#illusionblock', 'Toggle whether illusion effects cast by other players / bots land on you.', { cat = 'Players & Characters', target = 'self' })
E('attackmode', '#attackmode', 'Toggle between ranged and melee autoattack modes.', { cat = 'Players & Characters', target = 'self' })
E('autoskill', '#autoskill', 'Configure automatic combat skill usage.', { cat = 'Players & Characters', target = 'self' })
E('petcmd', '#petcmd', 'Issue commands to specific pets.', { cat = 'Players & Characters', target = 'self' })
E('petname', '#petname [New Name]', 'Temporarily rename your pet. Leave blank to restore the original name.', { cat = 'Players & Characters', target = 'self' })
E('makepet', '#makepet [Pet Name]', 'Create a pet.', { cat = 'Players & Characters', target = 'self' })
E('evolve', '#evolve', 'Evolving item manipulation. Use #evolve help for details.', { cat = 'Players & Characters', target = 'self' })
E('flagedit', '#flagedit', 'Edit zone flags on your target. Use #flagedit help for details.', { cat = 'Players & Characters', target = 'pc' })
E('invsnapshot', '#invsnapshot', 'Manipulate inventory snapshots for your current target.', { cat = 'Players & Characters', target = 'pc' })
E('interrogateinv', '#interrogateinv', 'Inspect your inventory. Use #interrogateinv help for options.', { cat = 'Players & Characters', target = 'self' })
E('save', '#save', 'Force your player or player-corpse target to save to the database.', { cat = 'Players & Characters', target = 'pc' })
E('kill', '#kill', 'Kill your target.', { cat = 'Players & Characters', target = 'any' })
E('damage', '#damage [Amount]', 'Deal damage to yourself or your target.', { cat = 'Players & Characters', target = 'any' })
E('stun', '#stun [Duration]', 'Stun yourself or your target for the specified duration in milliseconds.', { cat = 'Players & Characters', target = 'any' })
E('push', '#push [Back Push] [Up Push]', 'Apply spell-style push to your target.', { cat = 'Players & Characters', target = 'any' })
E('copycharacter', '#copycharacter [Source Name] [Dest Name] [Dest Account]', 'Copy a character to a destination account.', { cat = 'Players & Characters', danger = true })

-- Appearance & Effects ---------------------------------------------------------
E('appearance', '#appearance [Type] [Value]', 'Send an appearance packet for yourself or your target. No arguments lists every type ID.', { cat = 'Appearance & Effects', target = 'any' })
E('appearanceeffects', '#appearanceeffects', 'Modify appearance effects on yourself or your target.', { cat = 'Appearance & Effects', target = 'any', subs = {
    S('help', 'Display the help menu'),
    S('remove', 'Remove all saved appearance effects'),
    S('set [Effect ID] [Slot ID]', 'Set an appearance effect in a slot'),
    S('view', 'Display all saved appearance effects'),
} })
E('doanim', '#doanim [Animation ID|Name] [Speed]', 'Play an animation on yourself or your target. Speed is optional. Example: #doanim 3 10', { cat = 'Appearance & Effects', target = 'any' })
E('dye', '#dye [Slot|help] [Red] [Green] [Blue]', 'Dye an armor slot. Bypasses darkness limits. Example: #dye chest 255 0 0', { cat = 'Appearance & Effects', target = 'any' })
E('undye', '#undye', 'Remove dye from all armor slots on yourself or your target.', { cat = 'Appearance & Effects', target = 'any' })
E('wc', '#wc [Slot ID] [Material] [Hero Forge Model] [Elite Material]', 'Set the weapon / armor material for a specific slot on yourself or your target.', { cat = 'Appearance & Effects', target = 'any' })
E('feature', '#feature', 'Temporarily change appearance features on yourself or your target. Same as #size for size changes.', { cat = 'Appearance & Effects', target = 'any' })
E('size', '#size [Value]', 'Change your target\'s size. Alias of #feature size.', { cat = 'Appearance & Effects', target = 'any' })
E('fixmob', '#fixmob [Stat] [next|prev]', 'Cycle through appearance options on your target.', { cat = 'Appearance & Effects', target = 'npc',
    note = 'Stats: race, gender, texture, helm, face, hair, haircolor, beard, beardcolor, heritage, tattoo, detail.' })
E('randomfeatures', '#randomfeatures', 'Temporarily randomize facial features on your target.', { cat = 'Appearance & Effects', target = 'any' })
E('camerashake', '#camerashake [Duration (ms)] [Intensity (1-10)]', 'Shake the camera globally for all players.', { cat = 'Appearance & Effects', danger = true })
E('tim', '#tim', 'Toggle improved NPC models.', { cat = 'Appearance & Effects' })

-- NPCs & AI ------------------------------------------------------------------
E('ai', '#ai', 'Modify AI settings on a targeted NPC.', { cat = 'NPCs & AI', target = 'npc', subs = {
    S('consider [Mob Name]', 'Show how the targeted NPC considers another mob'),
    S('faction [Faction ID]', 'Set the NPC\'s faction ID'),
    S('guard', 'Save the NPC\'s current location as its guard spot'),
    S('roambox [Distance] [Min X] [Max X] [Min Y] [Max Y] [Delay] [Min Delay]', 'Set a roambox using coordinates'),
    S('roambox [Distance] [Roam Distance] [Delay] [Min Delay]', 'Set a roambox using roam distance'),
    S('spells [Spell List ID]', 'Set the NPC\'s spell list ID'),
} })
E('attack', '#attack [Entity Name]', 'Make your targeted NPC attack the specified entity by name.', { cat = 'NPCs & AI', target = 'npc' })
E('npccast', '#npccast [Target Name|Entity ID] [Spell ID]', 'Make your targeted NPC cast a spell on the specified target.', { cat = 'NPCs & AI', target = 'npc' })
E('npcsay', '#npcsay [Message]', 'Make your targeted NPC say a message.', { cat = 'NPCs & AI', target = 'npc' })
E('npcshout', '#npcshout [Message]', 'Make your targeted NPC shout a message.', { cat = 'NPCs & AI', target = 'npc' })
E('npcemote', '#npcemote [Message]', 'Make your targeted NPC emote a message.', { cat = 'NPCs & AI', target = 'npc' })
E('npcloot', '#npcloot', 'Manipulate loot an NPC is carrying. Use #npcloot help for details.', { cat = 'NPCs & AI', target = 'npc' })
E('modifynpcstat', '#modifynpcstat [Stat] [Value]', 'Temporarily modify a stat on a targeted NPC.', { cat = 'NPCs & AI', target = 'npc' })
E('scale', '#scale [dynamic|static]', 'Scale NPC stats. Target an NPC to scale it, or pass a name search for zone-wide scaling. Use all for every NPC in the zone.', { cat = 'NPCs & AI', target = 'npc' })
E('fleeinfo', '#fleeinfo', 'Display whether a targeted NPC will flee, using you as the top hate entry.', { cat = 'NPCs & AI', target = 'npc' })
E('killallnpcs', '#killallnpcs [NPC Name]', 'Kill all NPCs by name search. Leave blank to kill every attackable NPC.', { cat = 'NPCs & AI', danger = true })
E('merchantshop', '#merchantshop', 'Open or close your targeted NPC merchant\'s shop.', { cat = 'NPCs & AI', target = 'npc' })
E('movement', '#movement', 'Movement utilities.', { cat = 'NPCs & AI', target = 'npc', subs = {
    S('clear', 'Clear movement stats'),
    S('packet [X] [Y] [Z] [Heading] [Animation]', 'Send a movement command packet'),
    S('rotate', 'Rotate target to face you'),
    S('run', 'Force target to run'),
    S('stats', 'Show movement stats'),
    S('stop', 'Stop target movement'),
    S('walk', 'Force target to walk'),
} })
E('tune', '#tune', 'Calculate combat statistical values. A = attacker perspective, D = defender perspective.', { cat = 'NPCs & AI', target = 'npc', subs = {
    S('stats [A/D]', 'Show AC mitigation %, hit chance, avoidance chance'),
    S('FindATK [A/D] [Target %] [Interval] [Loop Max] [AC Override] [Info Level]', 'Find ATK for a target mitigation %'),
    S('FindAC [A/D] [Target %] [Interval] [Loop Max] [ATK Override] [Info Level]', 'Find AC for a target mitigation %'),
    S('FindAccuracy [A/D] [Hit %] [Interval] [Loop Max] [Avoidance Override] [Info Level]', 'Find Accuracy for a target hit %'),
    S('FindAvoidance [A/D] [Hit %] [Interval] [Loop Max] [Accuracy Override] [Info Level]', 'Find Avoidance for a target hit %'),
} })
E('aggrozone', '#aggrozone [Aggro]', 'Aggro every NPC in the zone with the specified aggro value (default 0). Recommended while invulnerable.', { cat = 'NPCs & AI', danger = true })
E('depop', '#depop [Start Spawn Timer]', 'Depop your targeted NPC, optionally starting its spawn timer. Example: #depop 1', { cat = 'NPCs & AI', target = 'npc' })
E('sendzonespawns', '#sendzonespawns', 'Refresh the spawn list for all clients in the zone.', { cat = 'NPCs & AI' })
E('npcedit', '#npcedit [Subcommand] [Value]', 'Edit NPC data on the targeted NPC. Changes are written to the database.', { cat = 'NPCs & AI', target = 'npc', subs = {
    S('ac [AC]', 'Armor class'), S('accuracy [Value]', 'Accuracy'), S('agi [Value]', 'Agility'), S('aggroradius [Radius]', 'Aggro radius'),
    S('alt_currency_id [ID]', 'Alternate currency ID'), S('always_aggro [0|1]', 'Always aggro flag'), S('ammoidfile [ID]', 'Ammo ID file'),
    S('armortint_id [ID]', 'Armor tint ID'), S('armtexture [Texture]', 'Arm texture'), S('assistradius [Radius]', 'Assist radius'),
    S('atk [Value]', 'Attack'), S('attackcount [Count]', 'Attack count'), S('attackdelay [Delay]', 'Attack delay'), S('attackspeed [Speed]', 'Attack speed modifier'),
    S('avoidance [Value]', 'Avoidance'), S('bodytype [ID]', 'Body type'), S('bracertexture [Texture]', 'Bracer texture'), S('cha [Value]', 'Charisma'),
    S('charm_ac [AC]', 'AC while charmed'), S('charm_accuracy_rating [Value]', 'Accuracy while charmed'), S('charm_atk [Value]', 'Attack while charmed'),
    S('charm_attack_delay [Value]', 'Attack delay while charmed'), S('charm_avoidance_rating [Value]', 'Avoidance while charmed'),
    S('charm_max_dmg [Value]', 'Max damage while charmed'), S('charm_min_dmg [Value]', 'Min damage while charmed'), S('class [Class ID]', 'Class'),
    S('color [R] [G] [B]', 'Armor tint (RGB)'), S('corrup [Value]', 'Corruption resistance'), S('cr [Value]', 'Cold resistance'), S('damage [Min] [Max]', 'Min / max damage'),
    S('dex [Value]', 'Dexterity'), S('dr [Value]', 'Disease resistance'), S('emoteid [ID]', 'Emote ID'), S('exp_mod [%]', 'Experience modifier'),
    S('faction [ID]', 'Faction ID'), S('faction_amount [Value]', 'Faction amount'), S('featuresave', 'Save current facial features to the DB'),
    S('feettexture [Texture]', 'Feet texture'), S('findable [0|1]', 'Findable flag'),
    S('flymode [0-5]', 'Fly mode (0 Ground, 1 Flying, 2 Levitating, 3 Water, 4 Floating, 5 Levitating while running)'),
    S('fr [Value]', 'Fire resistance'), S('gender [ID]', 'Gender'), S('handtexture [Texture]', 'Hand texture'), S('healscale [%]', 'Heal scaling rate'),
    S('helmtexture [Texture]', 'Helmet texture'), S('herosforgemodel [Model]', "Hero's Forge model"), S('hp [Value]', 'Max HP'),
    S('hp_regen_per_second [Value]', 'HP regen per second'), S('hpregen [Value]', 'HP regen per tick'), S('int [Value]', 'Intelligence'),
    S('is_parcel_merchant [0|1]', 'Parcel merchant flag'), S('keeps_sold_items [0|1]', 'Keeps sold items flag'), S('lastname [Name]', 'Last name'),
    S('level [Level]', 'Level'), S('legtexture [Texture]', 'Leg texture'), S('loottable [ID]', 'Loottable ID'), S('mana [Value]', 'Max mana'),
    S('manaregen [Value]', 'Mana regen per tick'), S('maxlevel [Level]', 'Maximum level'), S('meleetype [Primary] [Secondary]', 'Melee skill types'),
    S('merchantid [ID]', 'Merchant ID'), S('model [Race ID]', 'Race model'), S('mr [Value]', 'Magic resistance'), S('name [Name]', 'NPC name'),
    S('no_target [0|1]', 'No target hotkey flag'), S('npcaggro [0|1]', 'NPC aggro flag'), S('npc_spells_effects_id [ID]', 'Spell effects ID'),
    S('phr [Value]', 'Physical resistance'), S('pr [Value]', 'Poison resistance'), S('qglobal [0|1]', 'Quest global flag'), S('raidtarget [0|1]', 'Raid target flag'),
    S('rangedtype [Type]', 'Ranged skill type'), S('rarespawn [0|1]', 'Rare spawn flag'), S('respawntime [Seconds]', 'Respawn timer (spawn2 table)'),
    S('runspeed [Speed]', 'Run speed'), S('scalerate [%]', 'Scale rate (50 = 50%, 100 = 100%, 200 = 200%)'), S('seehide [0|1]', 'See hide flag'),
    S('seeinvis [0|1]', 'See invisible flag'), S('seeinvisundead [0|1]', 'See invisible vs. undead flag'), S('seeimprovedhide [0|1]', 'See improved hide flag'),
    S('set_grid [Grid ID]', "Assign a grid to this NPC's spawn entry"), S('setanimation [Animation ID]', 'Spawn animation (spawn2 table)'), S('size [Size]', 'Size'),
    S('skip_global_loot [0|1]', 'Skip global loot flag'), S('slow_mitigation [Value]', 'Slow mitigation'), S('spawn_limit [Limit]', 'Spawn limit counter'),
    S('special_abilities [Value]', 'Special abilities string'), S('special_attacks [Value]', 'Special attacks'), S('spell [List ID]', 'Spell list ID'),
    S('spellscale [%]', 'Spell scaling rate'), S('sta [Value]', 'Stamina'), S('str [Value]', 'Strength'),
    S('stuck_behavior [0-3]', 'Stuck behavior (0 Run to Target, 1 Warp to Target, 2 No Action, 3 Evade Combat)'), S('texture [Texture]', 'Texture'),
    S('trackable [0|1]', 'Trackable flag'), S('trap_template [ID]', 'Trap template ID'), S('untargetable [0|1]', 'Untargetable flag'),
    S('version [Version]', 'NPC version'), S('walkspeed [Speed]', 'Walk speed'), S('weapon [Primary] [Secondary]', 'Primary / secondary weapon model'),
    S('wis [Value]', 'Wisdom'), S('show_name [0|1]', 'Show name flag'),
} })
E('npceditmass', '#npceditmass [Name Search] [Column] [Value]', 'Zone-wide NPC data edit matching a name search.', { cat = 'NPCs & AI', danger = true })

-- Spawns, Grids & Paths ------------------------------------------------------
E('spawn', '#spawn [Name] [Race] [Level] [Material] [HP] [Gender] [Class] [PriWeapon] [SecWeapon] [MerchantID]', 'Spawn an NPC with the specified parameters.', { cat = 'Spawns, Grids & Paths' })
E('npcspawn', '#npcspawn', 'Manage NPC spawns in the database.', { cat = 'Spawns, Grids & Paths', target = 'npc', subs = {
    S('add [Respawn Time]', 'Create a new spawn2 / spawngroup entry for the targeted NPC'),
    S('clone [Respawn Time]', "Copy the targeted NPC's spawngroup; create a spawn2 at your location"),
    S('create [Respawn Time]', 'Create a new NPC type copied from the targeted NPC, with new spawn2 / spawngroup'),
    S('delete', 'Delete spawn2, spawngroup, spawnentry, and npc_types for the targeted NPC', { danger = true }),
    S('remove [Remove Spawngroups]', 'Delete the spawn2 row; also removes spawngroup / spawnentry if > 0', { danger = true }),
    S('update', 'Update NPC appearance in the database'),
} })
E('npctypespawn', '#npctypespawn [NPC ID] [Faction ID]', 'Spawn an NPC by type ID from the database. Faction ID is optional.', { cat = 'Spawns, Grids & Paths' })
E('dbspawn2', '#dbspawn2 [Spawngroup ID] [Respawn] [Variance] [Condition ID] [Condition Min]', 'Spawn an NPC from a spawn2 table row. Respawn and Variance are in seconds. Condition is optional.', { cat = 'Spawns, Grids & Paths' })
E('advnpcspawn', '#advnpcspawn', 'Advanced NPC spawn management.', { cat = 'Spawns, Grids & Paths', subs = {
    S('addentry [Spawngroup ID] [NPC ID] [Spawn Chance]', 'Add an entry to a spawngroup'),
    S('addspawn [Spawngroup ID]', 'Add a spawn from an existing spawngroup'),
    S('clearbox [Spawngroup ID]', "Clear a spawngroup's roambox"),
    S('deletespawn', 'Delete a spawngroup', { danger = true }),
    S('editbox [Spawngroup ID] [Distance] [Min X] [Max X] [Min Y] [Max Y] [Delay]', "Edit a spawngroup's roambox"),
    S('editrespawn [Respawn Timer] [Variance]', "Edit a spawngroup's respawn timer"),
    S('makegroup [Name] [Limit] [Distance] [Min X] [Max X] [Min Y] [Max Y] [Delay]', 'Create a new spawngroup'),
    S('makenpc', 'Create a new NPC'),
    S('movespawn', 'Move a spawngroup to your current location'),
    S('setversion [Version]', "Set a spawngroup's version"),
} })
E('spawnfix', '#spawnfix', 'Find the targeted NPC in the database by X / Y / heading and update it to spawn at your current location and heading.', { cat = 'Spawns, Grids & Paths', target = 'npc' })
E('spawneditmass', '#spawneditmass [Search] [Option] [Value] [Apply]', 'Zone-wide spawn editing. Pass 1 for Apply to commit changes.', { cat = 'Spawns, Grids & Paths', danger = true })
E('editmassrespawn', '#editmassrespawn [Name Search] [Seconds]', 'Zone-wide NPC respawn timer edit by name search.', { cat = 'Spawns, Grids & Paths', danger = true })
E('repop', '#repop [Force]', 'Repop the zone. Pass 1 to force repop.', { cat = 'Spawns, Grids & Paths' })
E('depopzone', '#depopzone [Start Spawn Timers]', 'Depop the entire zone. Pass 1 to also start spawn timers.', { cat = 'Spawns, Grids & Paths', danger = true })
E('roambox', '#roambox', 'Manage the roambox on a targeted NPC.', { cat = 'Spawns, Grids & Paths', target = 'npc', subs = {
    S('remove', "Remove the NPC's roambox"),
    S('set [Box Size] [Delay]', 'Set a roambox with the given size and delay'),
} })
E('grid', '#grid', 'Manage NPC wandering grids in the current zone.', { cat = 'Spawns, Grids & Paths', subs = {
    S('add [Grid ID] [Wander Type] [Pause Type]', 'Create a new grid'),
    S('delete [Grid ID]', 'Delete a grid', { danger = true }),
    S('hide', "Despawn visual node markers for the targeted NPC's grid"),
    S('max', 'Show the highest grid ID used in this zone'),
    S('show', "Spawn visual node markers for the targeted NPC's grid"),
} })
E('wp', '#wp [add|delete] [Grid ID] [Pause] [Waypoint ID] [-h]', 'Add or delete a waypoint by grid ID. Pause and Waypoint ID can be 0 to auto-append. -h applies your current heading.', { cat = 'Spawns, Grids & Paths' })
E('wpadd', '#wpadd [Pause] [-h]', "Add your current position as a waypoint to your targeted NPC's path. Creates a new grid if none exists. Pause defaults to 0; -h for current heading.", { cat = 'Spawns, Grids & Paths', target = 'npc' })
E('path', '#path', 'View and edit zone pathing.', { cat = 'Spawns, Grids & Paths' })

-- Corpses ----------------------------------------------------------------------
E('corpse', '#corpse', 'Manipulate corpses.', { cat = 'Corpses', target = 'any', subs = {
    S('charid [Character ID]', "Change a player corpse's owner"),
    S('delete', 'Delete the targeted corpse', { danger = true }),
    S('deletenpccorpses', 'Delete all NPC corpses', { danger = true }),
    S('deleteplayercorpses', 'Delete all player corpses', { danger = true }),
    S('depop [Bury]', 'Depop the targeted corpse (Bury = 0 skips burying)'),
    S('depopall [Bury]', "Depop all of a player's corpses", { danger = true }),
    S('inspectloot', 'Inspect loot on a corpse'),
    S('listnpc', 'List all NPC corpses'),
    S('listplayer', 'List all player corpses'),
    S('lock', 'Lock a corpse (GM-only loot)'),
    S('moveallgraveyard', 'Move all player corpses to the zone graveyard'),
    S('removecash', 'Remove cash from a corpse'),
    S('unlock', 'Unlock a corpse'),
} })
E('corpsefix', '#corpsefix', 'Attempt to bring nearby corpses up from beneath the ground.', { cat = 'Corpses' })
E('summonburiedplayercorpse', '#summonburiedplayercorpse', "Summon your target's oldest buried corpse.", { cat = 'Corpses', target = 'pc' })

-- Zone Editing -----------------------------------------------------------------
E('door', '#door', 'Interactive door editing. Use with no arguments for the help menu.', { cat = 'Zone Editing' })
E('object', '#object', 'Manage static and tradeskill objects. Subcommands: List, Add, Edit, Move, Rotate, Copy, Save, Undo, Delete. No arguments shows the help menu.', { cat = 'Zone Editing' })
E('zsave', '#zsave', 'Save the zone header to the database.', { cat = 'Zone Editing' })
E('zonevariable', '#zonevariable', 'Manage variables for the current zone. Use quotes for names / values with spaces.', { cat = 'Zone Editing', subs = {
    S('clear', 'Clear all zone variables', { danger = true }),
    S('delete [Variable Name]', 'Delete a zone variable'),
    S('set [Variable Name] [Value]', 'Set a zone variable'),
    S('view [Variable Name]', 'View a zone variable'),
} })
E('entityvariable', '#entityvariable', 'Manage entity variables on yourself or your target. Use quotes for names / values with spaces. Example: #entityvariable set "my_var" "hello world"', { cat = 'Zone Editing', target = 'any', subs = {
    S('clear', 'Clear all entity variables', { danger = true }),
    S('delete [Variable Name]', 'Delete a specific entity variable'),
    S('set [Variable Name] [Value]', 'Set an entity variable'),
    S('view [Variable Name]', 'View an entity variable'),
} })
E('list', '#list [npcs|players|corpses|doors|objects] [Search]', 'Search entities in the zone.', { cat = 'Zone Editing' })
E('databuckets', '#databuckets', 'View and manage data buckets. Character ID, NPC ID and Bot ID are optional filters.', { cat = 'Zone Editing', subs = {
    S('delete [Key] [Char ID] [NPC ID] [Bot ID]', 'Delete matching data buckets', { danger = true }),
    S('edit [Key] [Char ID] [NPC ID] [Bot ID] [Value] [Expires]', 'Edit a data bucket'),
    S('view [Partial Key] [Char ID] [NPC ID] [Bot ID]', 'View matching data buckets'),
} })

-- Factions, Guilds & Tasks ---------------------------------------------------
E('faction', '#faction', 'Manage faction.', { cat = 'Factions, Guilds & Tasks', target = 'any', subs = {
    S('review [Search|All]', "Review a targeted player's faction hits"),
    S('reset [Faction ID]', "Reset a targeted player's faction to its base value"),
    S('view', "Display the targeted NPC's primary faction"),
} })
E('factionassociation', '#factionassociation [Faction ID] [Amount]', 'Trigger faction hits via faction association.', { cat = 'Factions, Guilds & Tasks' })
E('guild', '#guild', 'Guild management.', { cat = 'Factions, Guilds & Tasks', subs = {
    S('create [Char ID|Name] [Guild Name]', 'Create a guild'),
    S('delete [Guild ID]', 'Delete a guild', { danger = true }),
    S('details [Guild ID]', 'Show guild details'),
    S('info [Guild ID]', 'Show guild info'),
    S('list', 'List all guilds'),
    S('rename [Guild ID] [New Name]', 'Rename a guild'),
    S('search [Search Criteria]', 'Search guilds'),
    S('set [Char ID|Name] [Guild ID]', "Set a character's guild (0 = guildless)"),
    S('setleader [Guild ID] [Char ID|Name]', "Set a guild's leader"),
    S('setrank [Char ID|Name] [Rank]', "Set a character's guild rank"),
    S('status [Char ID|Name]', "Show a character's guild status"),
} })
E('task', '#task', 'Task system management.', { cat = 'Factions, Guilds & Tasks', target = 'pc', subs = {
    S('assign [Task ID]', 'Assign a task to the target'),
    S('complete [Task ID]', 'Complete a task'),
    S('purgetimers', 'Purge task timers for the target'),
    S('reload lists', 'Reload goal / reward list data'),
    S('reload sets', 'Reload task set data'),
    S('reload task [Task ID]', 'Reload a single task'),
    S('reloadall', 'Reload all task data from the database'),
    S('sharedpurge', 'Purge all active shared tasks', { danger = true }),
    S('show', 'List active tasks for the target'),
    S('uncomplete [Task ID]', 'Uncomplete a completed task'),
    S('update [Task ID] [Activity ID] [Count]', 'Update task progress'),
} })
E('parcels', '#parcels', 'View and edit the parcel system (requires parcels enabled in rules).', { cat = 'Factions, Guilds & Tasks' })
E('disablerecipe', '#disablerecipe [Recipe ID]', 'Disable a crafting recipe.', { cat = 'Factions, Guilds & Tasks' })
E('enablerecipe', '#enablerecipe [Recipe ID]', 'Enable a crafting recipe.', { cat = 'Factions, Guilds & Tasks' })

-- Accounts & Moderation ------------------------------------------------------
E('ban', '#ban [Character Name] [Reason]', 'Ban an account by character name.', { cat = 'Accounts & Moderation', danger = true })
E('ipban', '#ipban [IP]', 'Ban an IP address.', { cat = 'Accounts & Moderation', danger = true })
E('kick', '#kick [Character Name]', 'Disconnect a player by name.', { cat = 'Accounts & Moderation', danger = true })
E('suspend', '#suspend [Name] [Days] [Reason]', 'Suspend a character for the specified number of days.', { cat = 'Accounts & Moderation', danger = true })
E('suspendmulti', '#suspendmulti [Name One|Name Two|...] [Days] [Reason]', 'Suspend multiple characters. Separate names with |.', { cat = 'Accounts & Moderation', danger = true })
E('revoke', '#revoke [Character Name] [0|1]', "Revoke or unrevoke a player's OOC chat access. 1 = revoke, 0 = unrevoke.", { cat = 'Accounts & Moderation' })
E('soulmark', '#soulmark [add|remove] [Character] [Reason]', 'Manipulate account flags. Reason is required for add.', { cat = 'Accounts & Moderation' })
E('delacct', '#delacct [Account ID|Account Name]', 'Delete an account by ID or name.', { cat = 'Accounts & Moderation', danger = true })
E('delpetition', '#delpetition [Petition Number]', 'Delete a petition by number.', { cat = 'Accounts & Moderation' })
E('bugs', '#bugs', 'Manage player bug reports.', { cat = 'Accounts & Moderation', subs = {
    S('close [Bug ID]', 'Close a bug report'),
    S('delete [Bug ID]', 'Delete a bug report', { danger = true }),
    S('review [Bug ID] [Review]', 'Add a review to a bug report'),
    S('search [Search Criteria]', 'Search bug reports'),
    S('view [Bug ID]', 'View a bug report'),
} })
E('profanity', '#profanity', 'Manage the censored language list.', { cat = 'Accounts & Moderation' })
E('chat', '#chat [Channel ID] [Message]', 'Send a channel message to all zones.', { cat = 'Accounts & Moderation' })
E('emote', '#emote [Name|World|Zone] [Type] [Message]', 'Send an emote message. Separate multiple messages with ^.', { cat = 'Accounts & Moderation' })

-- Server & Admin -------------------------------------------------------------
E('reload', '#reload [Type]', 'Reload server data globally. Use #reload with no arguments for the full subcommand list.', { cat = 'Server & Admin',
    note = 'Common aliases: #rq reload quests, #rl reload logs, #opcode reload opcodes.', aliases = { 'rq', 'rl', 'opcode' } })
E('logs', '#logs', 'Manage server logging.', { cat = 'Server & Admin', subs = {
    S('list [Start Category ID]', 'Show up to 50 log categories (starting at the ID if given)'),
    S('reload', 'Reload log settings in world and all zone processes from the database'),
    S('set [console|file|gmsay] [Category ID] [Level (1-3)]', 'Set log output for the zone lifetime'),
} })
E('rules', '#rules', 'Manage server rules.', { cat = 'Server & Admin', subs = {
    S('current', 'Show the currently active ruleset name'),
    S('get [Rule]', "Get a rule's current local value"),
    S('list [Category]', 'List all rules in a category (or all)'),
    S('listsets', 'List available rule sets'),
    S('load [Ruleset Name]', 'Load a ruleset in this zone only'),
    S('reload', 'Reload the selected ruleset in this zone'),
    S('reset', 'Reset all rules to default values', { danger = true }),
    S('set [Rule] [Value]', 'Set a rule locally'),
    S('setdb [Rule] [Value]', 'Set a rule locally and in the database', { danger = true }),
    S('store [Ruleset Name]', 'Store the running ruleset under a name'),
    S('switch [Ruleset Name]', 'Change the active ruleset and load it', { danger = true }),
    S('values [Category]', 'List values of all rules in a category'),
} })
E('shutdown', '#shutdown', 'Shut down the current zone process.', { cat = 'Server & Admin', danger = true })
E('worldshutdown', '#worldshutdown', 'Shut down world and all zone servers.', { cat = 'Server & Admin', danger = true })
E('worldwide', '#worldwide', 'Perform world-wide GM functions such as zone-wide casting. Use with caution.', { cat = 'Server & Admin', danger = true })
E('zonebootup', '#zonebootup [Zone Server ID] [Short Name]', 'Boot a specific zone on a zone server.', { cat = 'Server & Admin' })
E('zoneshutdown', '#zoneshutdown [instance|zone] [Instance ID|Zone ID|Short Name]', 'Shut down a zone server by instance ID, zone ID, or short name.', { cat = 'Server & Admin', danger = true })
E('acceptrules', '#acceptrules', 'Accept the EQEmu server rules agreement.', { cat = 'Server & Admin' })
E('serverrules', '#serverrules', 'Display the server rules (player-accessible).', { cat = 'Server & Admin' })
E('devtools', '#devtools [menu|window] [0|1]', 'Manage Developer Tools. No arguments opens the dev tools menu; menu or window with 0 / 1 toggles.', { cat = 'Server & Admin' })

-- Find ---------------------------------------------------------------------
E('find', '#find', 'Search for game data. Every subcommand takes a search string.', { cat = 'Find', subs = {
    S('aa [Search]', 'Alternate abilities'),
    S('account [Search]', 'Accounts', { aliases = { 'findaccount' } }),
    S('body_type [Search]', 'Body types', { aliases = { 'findbodytype' } }),
    S('bug_category [Search]', 'Bug categories', { aliases = { 'findbugcategory' } }),
    S('character [Search]', 'Characters', { aliases = { 'findcharacter' } }),
    S('class [Search]', 'Classes', { aliases = { 'findclass' } }),
    S('currency [Search]', 'Currencies', { aliases = { 'findcurrency' } }),
    S('deity [Search]', 'Deities', { aliases = { 'finddeity' } }),
    S('emote [Search]', 'Emotes', { aliases = { 'findemote' } }),
    S('faction [Search]', 'Factions', { aliases = { 'findfaction' } }),
    S('item [Search]', 'Items', { aliases = { 'fi', 'finditem' } }),
    S('language [Search]', 'Languages', { aliases = { 'findlanguage' } }),
    S('npctype [Search]', 'NPC types', { aliases = { 'fn', 'findnpc', 'findnpctype' } }),
    S('race [Search]', 'Races', { aliases = { 'findrace' } }),
    S('recipe [Search]', 'Recipes', { aliases = { 'findrecipe' } }),
    S('skill [Search]', 'Skills', { aliases = { 'findskill' } }),
    S('special_ability [Search]', 'Special abilities', { aliases = { 'fsa', 'findspecialability' } }),
    S('spell [Search]', 'Spells', { aliases = { 'fs', 'findspell' } }),
    S('task [Search]', 'Tasks', { aliases = { 'findtask' } }),
    S('zone [Search]', 'Zones', { aliases = { 'fz', 'findzone' } }),
} })

-- Set ----------------------------------------------------------------------
E('set', '#set', 'Set player / server properties. Most subcommands also exist as their own legacy # command (listed as aliases).', { cat = 'Set', target = 'any', subs = {
    S('aa_exp [aa|group|raid] [Amount]', 'Set AA experience', { aliases = { 'setaaxp' } }),
    S('aa_points [aa|group|raid] [Amount]', 'Set AA points', { aliases = { 'setaapts' } }),
    S('adventure_points [Theme ID] [Amount]', 'Set adventure points'),
    S('alternate_currency [Currency ID] [Amount]', 'Set alternate currency', { aliases = { 'setaltcurrency' } }),
    S('animation [Animation ID]', 'Set animation', { aliases = { 'setanim' } }),
    S('anon [Anonymous Flag]', 'Set anonymous flag', { aliases = { 'setanon' } }),
    S('auto_login [0|1]', 'Toggle auto-login', { aliases = { 'setautologin' } }),
    S('bind_point', 'Set bind point to current location', { aliases = { 'setbind' } }),
    S('class_permanent [Class ID]', 'Permanently set class', { aliases = { 'permaclass' }, danger = true }),
    S('crystals [ebon|radiant] [Amount]', 'Set crystal currency', { aliases = { 'setcrystals' } }),
    S('date [Year] [Month] [Day] [Hour] [Minute]', 'Set in-game date / time', { aliases = { 'date' } }),
    S('endurance [Amount]', 'Set endurance', { aliases = { 'setendurance' } }),
    S('endurance_full', 'Fill endurance', { aliases = { 'endurance' } }),
    S('exp [aa|exp] [Amount]', 'Set experience', { aliases = { 'setxp' } }),
    S('flymode [Flymode ID]', 'Set fly mode (0-5)', { aliases = { 'flymode' } }),
    S('frozen [on|off]', 'Freeze / unfreeze target', { aliases = { 'freeze', 'unfreeze' } }),
    S('gender [ID]', 'Set gender', { aliases = { 'gender' } }),
    S('gender_permanent [ID]', 'Permanently set gender', { aliases = { 'permagender' }, danger = true }),
    S('gm [on|off]', 'Toggle GM mode', { aliases = { 'gm' } }),
    S('gm_speed [on|off]', 'Toggle GM speed', { aliases = { 'gmspeed' } }),
    S('gm_status [Status] [Account]', 'Set account GM status', { aliases = { 'flag' }, danger = true }),
    S('god_mode [on|off]', 'Toggle god mode', { aliases = { 'godmode' } }),
    S('haste [%]', 'Set haste percentage', { aliases = { 'haste' } }),
    S('hero_model [Model] [Slot]', 'Set hero model', { aliases = { 'heromodel' } }),
    S('hide_me [on|off]', 'Toggle visibility to players', { aliases = { 'hideme' } }),
    S('hp [Amount]', 'Set HP', { aliases = { 'sethp' } }),
    S('hp_full', 'Fill HP', { aliases = { 'heal' } }),
    S('invulnerable', 'Toggle invulnerability', { aliases = { 'invul' } }),
    S('language [ID] [Level]', 'Set language skill', { aliases = { 'setlanguage' } }),
    S('last_name [Name]', 'Set last name', { aliases = { 'lastname' } }),
    S('level [Level]', 'Set level', { aliases = { 'level' } }),
    S('loginserver_info [Email] [Pass]', 'Set login server credentials', { aliases = { 'setlsinfo' }, danger = true, secret = true }),
    S('mana [Amount]', 'Set mana', { aliases = { 'setmana' } }),
    S('mana_full', 'Fill mana', { aliases = { 'mana' } }),
    S('motd [Message]', 'Set message of the day', { aliases = { 'motd' } }),
    S('name [Name]', 'Set name', { aliases = { 'name' }, danger = true }),
    S('ooc_mute', 'Mute OOC for a player', { aliases = { 'oocmute' } }),
    S('password [Account] [Pass]', 'Set account password', { aliases = { 'setpass' }, danger = true, secret = true }),
    S('pvp [on|off]', 'Toggle PvP', { aliases = { 'pvp' } }),
    S('pvp_points [Amount]', 'Set PvP points', { aliases = { 'setpvppoints' } }),
    S('race [Race ID]', 'Set race', { aliases = { 'race' } }),
    S('race_permanent [Race ID]', 'Permanently set race', { aliases = { 'permarace' }, danger = true }),
    S('server_locked [on|off]', 'Lock / unlock the server', { aliases = { 'lock', 'unlock', 'serverlock' }, danger = true }),
    S('skill [Skill ID] [Level]', 'Set a skill level', { aliases = { 'setskill' } }),
    S('skill_all [Level]', 'Set all skill levels', { aliases = { 'setskillall' } }),
    S('skill_all_max', 'Max all skills', { aliases = { 'maxskills' } }),
    S('start_zone', 'Set start zone', { aliases = { 'setstartzone' } }),
    S('temporary_name [Name]', 'Temporarily rename target', { aliases = { 'tempname' } }),
    S('texture [Texture ID]', 'Set texture', { aliases = { 'texture' } }),
    S('time [Hour] [Minute]', 'Set in-game time', { aliases = { 'time' } }),
    S('time_zone [Hour] [Minute]', 'Set time zone offset', { aliases = { 'timezone' } }),
    S('title [Title]', 'Set title', { aliases = { 'title' } }),
    S('title_suffix [Suffix]', 'Set title suffix', { aliases = { 'titlesuffix' } }),
    S('weather [0-3]', 'Set weather (0 None, 1 Rain, 2 Snow, 3 Reset)', { aliases = { 'weather' } }),
    S('zone [option]', 'Zone header options', { aliases = { 'zclip', 'zcolor', 'zheader', 'zonelock', 'zsafecoords', 'zsky', 'zunderworld' } }),
} })

-- Show ---------------------------------------------------------------------
E('show', '#show', 'Display information. Every subcommand also has a legacy # alias.', { cat = 'Show', subs = {
    S('aas', 'Show AA list', { aliases = { 'showaas' } }),
    S('aa_points', 'Show AA points', { aliases = { 'showaapoints', 'showaapts' } }),
    S('aggro [Distance] [-v]', 'Show aggro info; -v for verbose faction info', { aliases = { 'aggro' } }),
    S('auto_login', 'Show auto-login status', { aliases = { 'showautologin' } }),
    S('buffs', 'Show buffs on target', { aliases = { 'showbuffs' } }),
    S('buried_corpse_count', 'Show buried corpse count', { aliases = { 'getplayerburiedcorpsecount' } }),
    S('client_version_summary', 'Show client version summary', { aliases = { 'cvs' } }),
    S('content_flags', 'Show content flags', { aliases = { 'showcontentflags' } }),
    S('currencies', 'Show currency balances', { aliases = { 'viewcurrencies' } }),
    S('distance', 'Show distance to target', { aliases = { 'distance' } }),
    S('emotes', 'List emotes', { aliases = { 'emoteview' } }),
    S('field_of_view', 'Check field of view to target', { aliases = { 'fov' } }),
    S('flags', 'Show zone flags', { aliases = { 'flags' } }),
    S('group_info', 'Show group information', { aliases = { 'ginfo' } }),
    S('hatelist', 'Show NPC hate list', { aliases = { 'hatelist' } }),
    S('inventory', "Inspect target's inventory", { aliases = { 'peekinv' } }),
    S('ip_lookup', "Look up a player's IP", { aliases = { 'iplookup' } }),
    S('line_of_sight', 'Check line of sight to target', { aliases = { 'checklos' } }),
    S('network', 'Show network info', { aliases = { 'network' } }),
    S('network_stats', 'Show network statistics', { aliases = { 'netstats' } }),
    S('npc_global_loot', 'Show global loot for the targeted NPC', { aliases = { 'shownpcgloballoot' } }),
    S('npc_stats', "Show the targeted NPC's stats", { aliases = { 'npcstats' } }),
    S('npc_type [NPC ID]', 'View NPC type data', { aliases = { 'viewnpctype' } }),
    S('peqzone_flags', 'Show PEQ zone flags', { aliases = { 'peqzone_flags' } }),
    S('petition', 'View petitions', { aliases = { 'listpetition', 'viewpetition' } }),
    S('petition_info', 'Show petition info', { aliases = { 'petitioninfo' } }),
    S('proximity', 'Show proximity triggers', { aliases = { 'proximity' } }),
    S('quest_errors', 'Show quest script errors', { aliases = { 'questerrors' } }),
    S('quest_globals', 'Show quest globals', { aliases = { 'globalview' } }),
    S('recipe [Recipe ID]', 'View a recipe', { aliases = { 'viewrecipe' } }),
    S('server_info', 'Show server info', { aliases = { 'serverinfo' } }),
    S('skills', "Show target's skills", { aliases = { 'showskills' } }),
    S('spawn_status [all|disabled|enabled|Spawn ID]', 'Show spawn status', { aliases = { 'spawnstatus' } }),
    S('special_abilities', 'Show special abilities', { aliases = { 'showspecialabilities' } }),
    S('spells [disciplines|spells]', 'Show spells or disciplines', { aliases = { 'showspells' } }),
    S('spells_list', 'Show full spell list', { aliases = { 'showspellslist' } }),
    S('stats', 'Show target stats', { aliases = { 'showstats' } }),
    S('timers', 'Show timers', { aliases = { 'timers' } }),
    S('traps', 'Show trap info', { aliases = { 'trapinfo' } }),
    S('uptime [Zone Server ID]', 'Show uptime', { aliases = { 'uptime' } }),
    S('variable [Variable Name]', 'Show a variable value', { aliases = { 'getvariable' } }),
    S('version', 'Show server version', { aliases = { 'version' } }),
    S('waypoints', 'Show waypoints for the targeted NPC', { aliases = { 'wpinfo' } }),
    S('who [Search Criteria]', 'List players online', { aliases = { 'who' } }),
    S('xtargets [Amount]', 'Show extended targets', { aliases = { 'xtargets' } }),
    S('zone_data', 'Show zone statistics', { aliases = { 'zstats' } }),
    S('zone_global_loot', 'Show zone global loot', { aliases = { 'showzonegloballoot' } }),
    S('zone_loot', 'Show zone loot table', { aliases = { 'viewzoneloot' } }),
    S('zone_points', 'Show zone points', { aliases = { 'showzonepoints' } }),
    S('zone_status', 'Show zone status', { aliases = { 'zonestatus' } }),
    S('zone_variables', 'Show zone variables'),
} })

-- Misc ---------------------------------------------------------------------
E('fish', '#fish', 'Forage a fish item.', { cat = 'Misc' })
E('forage', '#forage', 'Forage an item.', { cat = 'Misc' })
E('nudge', '#nudge [x=float] [y=float] [z=float] [h=float]', 'Nudge your target by specific amounts. Use named arguments in any combination. Example: #nudge x=5.0 z=1.0', { cat = 'Misc', target = 'any' })

-- The quick bar: one click, no arguments. (kill / depop act on the target
-- and are not marked dangerous; the confirm step is for zone / account-wide
-- things.)
local QUICK = {
    { 'GM on',     '#gm on' },        { 'GM off',    '#gm off' },
    { 'Hide on',   '#hideme on' },    { 'Hide off',  '#hideme off' },
    { 'Invul',     '#invul' },
    { 'God on',    '#godmode on' },   { 'God off',   '#godmode off' },
    { 'Speed on',  '#gmspeed on' },   { 'Speed off', '#gmspeed off' },
    { 'Heal',      '#heal' },         { 'Mana',      '#mana' },        { 'Endur',   '#endurance' },
    { 'Loc',       '#loc' },          { 'Summon',    '#summon' },      { 'Kill',    '#kill' },
    { 'Depop',     '#depop' },        { 'Repop',     '#repop' },
}

-- ============================================================================
-- Pure logic (exposed as plugin.logic for tests)
-- ============================================================================
local logic = {}

local function trim(s) return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', '')) end
local function lower(s) return string.lower(tostring(s or '')) end

-- Argument specs from a syntax line: every [token] in order.
--   { label, choices = { 'on', 'off' } | nil, kind = 'name'|'zone'|'x'|'y'|'z'|'h'|nil }
function logic.parseArgs(syntax)
    local out = {}
    for tok in tostring(syntax or ''):gmatch('%[(.-)%]') do
        local a = { label = tok }
        if tok:find('|', 1, true) and not tok:find(' ', 1, true) and not tok:find('%.%.%.') then
            a.choices = {}
            for c in tok:gmatch('[^|]+') do a.choices[#a.choices + 1] = c end
        end
        local l = lower(tok)
        if l == 'x' or l == 'y' or l == 'z' or l == 'h' or l == 'heading' then
            a.kind = (l == 'heading') and 'h' or l
        elseif l:find('zone id', 1, true) or l == 'zone' or l == 'short name' then
            a.kind = 'zone'
        elseif l:find('name', 1, true) or l == 'character' or l:find('entity', 1, true) or l:find('search', 1, true) then
            a.kind = 'name'
        end
        out[#out + 1] = a
    end
    return out
end

-- The literal words of a subcommand syntax before its first [token].
function logic.subName(syntax)
    return trim((tostring(syntax or ''):match('^([^%[]*)')))
end

-- Builds the `#...` line: command, subcommand words, then the filled
-- arguments in order. A blank argument is skipped; the line is what is
-- shown in the preview, so a gap is the user's to see.
function logic.buildLine(entry, sub, values)
    if not entry then return nil end
    local parts = { '#' .. entry.name }
    if sub then
        local sn = logic.subName(sub.syntax)
        if sn ~= '' then parts[#parts + 1] = sn end
    end
    for _, v in ipairs(values or {}) do
        local t = trim(v)
        if t ~= '' then parts[#parts + 1] = t end
    end
    return table.concat(parts, ' ')
end

function logic.isDanger(entry, sub)
    if entry and entry.danger then return true end
    if sub and sub.danger then return true end
    return false
end

-- Free-form input: '#zone poknowledge', 'zone poknowledge', '/say #zone ...'
-- all become '#zone poknowledge'; anything else is refused.
function logic.normalizeLine(input)
    local s = trim(input)
    if s == '' then return nil, 'empty line' end
    s = s:gsub('^/say%s+', '')
    if s:sub(1, 1) ~= '#' then
        if s:sub(1, 1) == '/' then return nil, 'not a # command' end
        s = '#' .. s
    end
    if #s < 2 or s:sub(2, 2):match('%s') then return nil, 'empty command' end
    return s
end

-- Resolves a typed / history line to its reference entry and subcommand:
-- returns entry, sub, prefix ('#set password', '#setpass': the command words
-- without the arguments). A legacy alias of a set / show / find subcommand
-- ('#setpass') resolves to that parent and sub. Unknown commands give nil.
function logic.resolveLine(line)
    local s = tostring(line or ''):gsub('^/say%s+', '')
    local name, rest = s:match('^#(%S+)%s*(.*)$')
    if not name then return nil end
    name = lower(name)
    local e = BY_NAME[name]
    if not e then
        for _, parent in ipairs({ 'set', 'show', 'find' }) do
            for _, sub in ipairs(BY_NAME[parent].subs) do
                for _, al in ipairs(sub.aliases or {}) do
                    if al == name then return BY_NAME[parent], sub, '#' .. name end
                end
            end
        end
        return nil
    end
    if e.subs then
        local restLow = lower(rest)
        for _, sub in ipairs(e.subs) do
            local sn = lower(logic.subName(sub.syntax))
            if sn ~= '' and (restLow == sn or restLow:sub(1, #sn + 1) == sn .. ' ') then
                return e, sub, '#' .. name .. ' ' .. sn
            end
        end
    end
    return e, nil, '#' .. name
end

-- Danger lookup of lines typed by hand or re-run from history.
function logic.lineDanger(line)
    local e, sub = logic.resolveLine(line)
    if not e then return false end
    if e.danger then return true end  -- (set / show / find themselves are not)
    return sub ~= nil and sub.danger == true
end

-- True for credential lines (#set password, #setpass, #set loginserver_info,
-- #setlsinfo, ...): marked `secret` in the reference.
function logic.lineSecret(line)
    local _, sub = logic.resolveLine(line)
    return sub ~= nil and sub.secret == true
end

-- The line as it may be shown / logged: credential arguments replaced.
function logic.redactLine(line)
    if not logic.lineSecret(line) then return line end
    local _, _, prefix = logic.resolveLine(line)
    return prefix .. ' <redacted>'
end

local function matchAliases(list, needle)
    for _, al in ipairs(list or {}) do
        if lower(al):find(needle, 1, true) then return true end
    end
    return false
end

-- Search hits for a needle: { { entry, sub | nil }, ... }. A command whose
-- name / description / aliases match is one row; each matching subcommand of
-- any command is its own row.
function logic.search(needle)
    needle = lower(trim(needle)):gsub('^#', '')
    local out = {}
    if needle == '' then return out end
    for _, e in ipairs(COMMANDS) do
        local hit = lower(e.name):find(needle, 1, true) or lower(e.desc):find(needle, 1, true) or matchAliases(e.aliases, needle)
        if hit then out[#out + 1] = { entry = e } end
        for _, sub in ipairs(e.subs or {}) do
            local sn = lower(logic.subName(sub.syntax))
            if sn:find(needle, 1, true) or lower(sub.desc):find(needle, 1, true) or matchAliases(sub.aliases, needle) then
                out[#out + 1] = { entry = e, sub = sub }
            end
        end
    end
    return out
end

function logic.byCategory(cat)
    local out = {}
    for _, e in ipairs(COMMANDS) do
        if e.cat == cat then out[#out + 1] = e end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function logic.targetLabel(kind)
    if kind == 'npc' then return 'your targeted NPC' end
    if kind == 'pc' then return 'your player target' end
    if kind == 'any' then return 'yourself, or your target' end
    if kind == 'self' then return 'yourself' end
    return nil
end

-- ============================================================================
-- State & settings
-- ============================================================================
local state = {
    gm          = nil,      -- Me.GM() at the last poll (nil = unknown)
    lastPollAt  = 0,
    target      = nil,      -- { name, type, level, id }
    zone        = '',
    search      = '',
    category    = CATEGORIES[1],
    selected    = nil,      -- entry
    sub         = nil,      -- sub of the selected entry
    args        = {},       -- arg values for the selection
    custom      = '',       -- free-form line
    confirm     = nil,      -- line waiting for confirmation
    confirmOpened = false,  -- the modal for `confirm` has been opened
    lastSent    = nil,
    lastSentAt  = 0,
    status      = '',
    showLevels  = false,
    debug       = false,
}

local settings = {
    confirmDanger = true,
    historyMax    = HISTORY_MAX_DEFAULT,
    history       = {},     -- newest first: { line, time, danger }
    favorites     = {},     -- { line }
}
-- Danger flag per favourite line (favourites are saved as plain strings).
local favDanger = {}

-- Back to defaults, so a character without saved settings never inherits
-- the previous character's history / favourites (the module stays loaded).
local function resetSettings()
    settings.confirmDanger = true
    settings.historyMax = HISTORY_MAX_DEFAULT
    settings.history = {}
    settings.favorites = {}
    favDanger = {}
end

local function refresh()
    if not core then return end
    ctrl = core.ctrl
    ImGui = core.ImGui
    mq = core.mq
end

local function say(fmt, ...)
    print(string.format('\ag[Triune GM]\ax ' .. fmt, ...))
end

local function nowSec() return os.clock() end

-- ---------------------------------------------------------------------------
-- History & favourites
-- ---------------------------------------------------------------------------
local function pushHistory(line)
    if logic.lineSecret(line) then return end  -- credentials are never kept
    for i, h in ipairs(settings.history) do
        if h.line == line then table.remove(settings.history, i) break end
    end
    table.insert(settings.history, 1, { line = line, time = os.date('%H:%M:%S'), danger = logic.lineDanger(line) })
    local max = tonumber(settings.historyMax) or HISTORY_MAX_DEFAULT
    while #settings.history > max do table.remove(settings.history) end
end

function plugin.isFavorite(line)
    for _, f in ipairs(settings.favorites) do if f == line then return true end end
    return false
end

function plugin.addFavorite(line)
    line = logic.normalizeLine(line)
    if not line or plugin.isFavorite(line) then return false end
    if logic.lineSecret(line) then
        state.status = 'Credential commands are not pinned.'
        return false
    end
    if #settings.favorites >= FAVORITES_MAX then return false end
    settings.favorites[#settings.favorites + 1] = line
    favDanger[line] = logic.lineDanger(line)
    if core then core.saveLoadout(true) end
    return true
end

function plugin.removeFavorite(line)
    for i, f in ipairs(settings.favorites) do
        if f == line then
            table.remove(settings.favorites, i)
            favDanger[line] = nil
            if core then core.saveLoadout(true) end
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Sending
-- ---------------------------------------------------------------------------
-- The game sends a # line as say; the server pulls it out before the zone
-- ever sees it, so nobody nearby reads it. mq.cmd only queues to the
-- client's command handler, so it is safe from the render thread.
local function sendNow(line)
    if not (mq and mq.cmdf) then
        state.status = 'Not in game.'
        return false
    end
    mq.cmdf('/say %s', line)
    local shown = logic.redactLine(line)
    state.lastSent = shown
    state.lastSentAt = nowSec()
    state.status = 'Sent ' .. shown
    if not logic.lineSecret(line) then
        pushHistory(line)
        if core then core.saveLoadout(true) end
    end
    return true
end

-- Runs a line, asking first when it is marked dangerous and Confirm is on.
-- `force` skips the question (the confirm popup's own Send button).
function plugin.run(line, force)
    local norm, why = logic.normalizeLine(line)
    if not norm then
        state.status = 'Nothing sent: ' .. tostring(why)
        return false
    end
    if not force and settings.confirmDanger and logic.lineDanger(norm) then
        state.confirm = norm
        return false
    end
    return sendNow(norm)
end

-- ---------------------------------------------------------------------------
-- Selection
-- ---------------------------------------------------------------------------
function plugin.select(entry, sub)
    if state.selected ~= entry or state.sub ~= sub then
        state.args = {}
    end
    state.selected = entry
    state.sub = sub
    if entry and entry.subs and not sub then
        -- a command that is only its subcommands: nothing to fill until one is picked
        state.args = {}
    end
end

local function currentArgs()
    local e = state.selected
    if not e then return {} end
    if e.subs then
        if state.sub then return logic.parseArgs(state.sub.syntax) end
        return {}
    end
    return logic.parseArgs(e.syntax)
end

local function currentLine()
    if not state.selected then return nil end
    if state.selected.subs and not state.sub then return '#' .. state.selected.name end
    return logic.buildLine(state.selected, state.sub, state.args)
end

-- ---------------------------------------------------------------------------
-- Game state polls
-- ---------------------------------------------------------------------------
local function poll(force)
    if not mq then return end
    local now = nowSec()
    if not force and (now - state.lastPollAt) < POLL_SEC then return end
    state.lastPollAt = now
    pcall(function()
        local g = mq.TLO.Me.GM
        if g then state.gm = (g() == true) end
    end)
    pcall(function()
        local id = mq.TLO.Target.ID() or 0
        if id and id > 0 then
            state.target = {
                id = id,
                name = mq.TLO.Target.CleanName() or '',
                type = mq.TLO.Target.Type() or '',
                level = mq.TLO.Target.Level() or 0,
            }
        else
            state.target = nil
        end
    end)
    pcall(function() state.zone = mq.TLO.Zone.ShortName() or '' end)
end

local function myLoc()
    local x, y, z, h = 0, 0, 0, 0
    pcall(function()
        x = mq.TLO.Me.X() or 0; y = mq.TLO.Me.Y() or 0; z = mq.TLO.Me.Z() or 0; h = mq.TLO.Me.Heading.Degrees() or 0
    end)
    return x, y, z, h
end

-- ============================================================================
-- Plugin hooks
-- ============================================================================
function plugin.onInit(coreApi)
    core = coreApi
    refresh()
    if ctrl and ctrl.show_gm_commands == nil then ctrl.show_gm_commands = false end
    resetSettings()  -- onLoadSettings (after onInit) fills in this character's
    state.selected = nil
    state.sub = nil
    state.confirm = nil
    state.confirmOpened = false
    state.custom = ''
end

function plugin.onDestroy()
    state.confirm = nil
    state.confirmOpened = false
    state.custom = ''
    resetSettings()
end

function plugin.onSaveSettings()
    local hist = {}
    for _, h in ipairs(settings.history) do
        if not logic.lineSecret(h.line) then hist[#hist + 1] = { line = h.line, time = h.time } end
    end
    local favs = {}
    for _, f in ipairs(settings.favorites) do
        if not logic.lineSecret(f) then favs[#favs + 1] = f end
    end
    return {
        confirmDanger = settings.confirmDanger ~= false,
        historyMax    = tonumber(settings.historyMax) or HISTORY_MAX_DEFAULT,
        history       = hist,
        favorites     = favs,
    }
end

function plugin.onLoadSettings(s)
    if type(s) ~= 'table' then return end
    if s.confirmDanger ~= nil then settings.confirmDanger = (s.confirmDanger ~= false) end
    if tonumber(s.historyMax) then settings.historyMax = math.max(5, math.min(HISTORY_MAX_CAP, math.floor(tonumber(s.historyMax)))) end
    if type(s.history) == 'table' then
        settings.history = {}
        for _, h in ipairs(s.history) do
            -- (credential lines saved by an older version are dropped)
            if type(h) == 'table' and type(h.line) == 'string' and #settings.history < HISTORY_MAX_CAP and not logic.lineSecret(h.line) then
                settings.history[#settings.history + 1] = { line = h.line, time = tostring(h.time or ''), danger = logic.lineDanger(h.line) }
            end
        end
    end
    if type(s.favorites) == 'table' then
        settings.favorites = {}
        favDanger = {}
        for _, f in ipairs(s.favorites) do
            if type(f) == 'string' and #settings.favorites < FAVORITES_MAX and not logic.lineSecret(f) then
                settings.favorites[#settings.favorites + 1] = f
                favDanger[f] = logic.lineDanger(f)
            end
        end
    end
end

function plugin.onZoned()
    state.target = nil
    poll(true)
end

function plugin.onTick()
    refresh()
    if not (ctrl and ctrl.show_gm_commands) then return end
    poll(false)
end

function plugin.openWindow(val)
    refresh()
    if not ctrl then return end
    if val == nil then val = not ctrl.show_gm_commands end
    ctrl.show_gm_commands = (val == true)
    core.saveLoadout(true)
end

-- ============================================================================
-- Window
-- ============================================================================
local function colorsOf()
    local c = core.colors or {}
    return {
        GOOD  = c.GOOD or { 0.40, 0.85, 0.50, 1.0 },
        WARN  = c.WARN or { 0.95, 0.75, 0.30, 1.0 },
        ERR   = c.ERR or { 0.95, 0.40, 0.40, 1.0 },
        MUTED = c.MUTED or { 0.55, 0.60, 0.65, 1.0 },
        ARC   = c.ARC or { 0.30, 0.80, 1.00, 1.0 },
        GOLD  = c.GOLD or { 1.0, 0.70, 0.54, 1.0 },
    }
end

local function tc(col, text)
    ImGui.TextColored(col[1], col[2], col[3], col[4], text)
end

local function drawSettingsBody()
    local v
    v = ImGui.Checkbox('Confirm destructive commands##gmConfirm', settings.confirmDanger ~= false)
    if v ~= (settings.confirmDanger ~= false) then settings.confirmDanger = v; core.saveLoadout(true) end
    if ImGui.IsItemHovered() then core.setTooltip('Bans, deletes, wipes, zone- or server-wide changes and shutdowns ask before they are sent. Marked with a red ! in the reference.') end

    ImGui.SetNextItemWidth(core.px(120))
    local hm = ImGui.SliderInt('History lines##gmHistMax', tonumber(settings.historyMax) or HISTORY_MAX_DEFAULT, 5, HISTORY_MAX_CAP)
    if type(hm) == 'number' and hm ~= settings.historyMax then
        settings.historyMax = hm
        while #settings.history > hm do table.remove(settings.history) end
        core.saveLoadout(true)
    end
end

local function drawHeader(colors)
    tc(colors.ARC, 'GM COMMANDS')
    ImGui.SameLine()
    ImGui.TextDisabled('| EQEmu # command reference & runner')
    ImGui.SameLine()
    if state.gm == true then
        tc(colors.GOOD, '[GM flag ON]')
    elseif state.gm == false then
        tc(colors.WARN, '[GM flag off]')
    else
        ImGui.TextDisabled('[GM flag ?]')
    end
    if ImGui.IsItemHovered() then core.setTooltip('${Me.GM}: whether your GM flag is on (#gm on). The account status level itself is not visible to the client.') end

    -- target & zone
    if state.target then
        ImGui.Text('Target:')
        ImGui.SameLine()
        local t = state.target
        local col = (t.type == 'NPC') and colors.WARN or (t.type == 'PC' and colors.GOOD or colors.MUTED)
        tc(col, string.format('%s (%s%s)', t.name, t.type, (t.level or 0) > 0 and (' L' .. t.level) or ''))
    else
        ImGui.TextDisabled('Target: none')
    end
    ImGui.SameLine()
    ImGui.TextDisabled(string.format('  Zone: %s', state.zone ~= '' and state.zone or '?'))
    ImGui.SameLine()
    if ImGui.SmallButton(state.showLevels and 'Hide status levels' or 'Status levels') then state.showLevels = not state.showLevels end
    if state.showLevels then
        if ImGui.BeginTable('##gmLevels', 6, ImGuiTableFlags and bit.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg) or 0) then
            for _, lv in ipairs(STATUS_LEVELS) do
                ImGui.TableNextColumn()
                ImGui.Text(string.format('%d  %s', lv[1], lv[2]))
            end
            ImGui.EndTable()
        end
        ImGui.TextDisabled('Account status levels (#flag <status> <account>). What each command needs is set per server.')
    end
end

-- Right edge of the current window's content region (screen space), or nil.
local function contentRightEdge()
    local ok, wx = pcall(ImGui.GetWindowPos)
    local ok2, cmx = pcall(ImGui.GetWindowContentRegionMax)
    if ok and ok2 and type(wx) == 'number' and type(cmx) == 'number' then return wx + cmx end
    return nil
end

-- Would a SmallButton labelled `label` still fit on this line after the last item?
local function fitsOnLine(label, rightEdge)
    if not rightEdge then return true end
    local okR, lastX = pcall(ImGui.GetItemRectMax)
    local okT, tw = pcall(ImGui.CalcTextSize, label, true)
    if not (okR and okT and type(lastX) == 'number' and type(tw) == 'number') then return true end
    local spacing, padX = 8, 4
    pcall(function()
        local st = ImGui.GetStyle()
        spacing = st.ItemSpacing.x or spacing
        padX = st.FramePadding.x or padX
    end)
    return lastX + spacing + tw + padX * 2 <= rightEdge
end

local function drawQuickBar(colors)
    ImGui.TextDisabled('Quick:')
    local rightEdge = contentRightEdge()
    for i, q in ipairs(QUICK) do
        local label = q[1] .. '##gmq' .. i
        -- wrap the row when the next button would run past the window edge
        if fitsOnLine(label, rightEdge) then ImGui.SameLine() end
        if ImGui.SmallButton(label) then plugin.run(q[2]) end
        if ImGui.IsItemHovered() then core.setTooltip(q[2]) end
    end
end

-- Per-frame caches for the list pane: the reference is static, so a
-- category list (with its labels) never changes and a search only changes
-- when the needle does.
local catCache = {}       -- category -> { { e, label }, ... }
local searchCache = { needle = nil, rows = {} }

local function categoryRows(cat)
    local rows = catCache[cat]
    if not rows then
        rows = {}
        for _, e in ipairs(logic.byCategory(cat)) do
            rows[#rows + 1] = { e = e, label = '#' .. e.name .. (e.subs and ' ...' or '') .. '##gmc_' .. e.name }
        end
        catCache[cat] = rows
    end
    return rows
end

local function searchRows(needle)
    if searchCache.needle ~= needle then
        local rows = {}
        for i, hit in ipairs(logic.search(needle)) do
            local e, sub = hit.entry, hit.sub
            local label = sub and ('#' .. e.name .. ' ' .. logic.subName(sub.syntax)) or ('#' .. e.name .. (e.subs and ' ...' or ''))
            rows[#rows + 1] = { e = e, sub = sub, label = label .. '##gmh' .. i, danger = logic.isDanger(e, sub) }
        end
        searchCache.needle = needle
        searchCache.rows = rows
    end
    return searchCache.rows
end

local function drawListPane(colors, w, h)
    if not ImGui.BeginChild('##gmList', w, h, true) then ImGui.EndChild() return end
    ImGui.SetNextItemWidth(-1)
    local s = ImGui.InputTextWithHint('##gmSearch', 'Search commands...', state.search or '')
    if type(s) == 'string' then state.search = s end

    local needle = trim(state.search)
    if needle == '' then
        ImGui.SetNextItemWidth(-1)
        if ImGui.BeginCombo('##gmCat', state.category) then
            for _, c in ipairs(CATEGORIES) do
                local _, pressed = ImGui.Selectable(c, c == state.category)
                if pressed then state.category = c end
            end
            ImGui.EndCombo()
        end
        ImGui.Separator()
        for _, row in ipairs(categoryRows(state.category)) do
            local e = row.e
            if e.danger then
                tc(colors.ERR, '!')
                ImGui.SameLine()
            end
            local _, pressed = ImGui.Selectable(row.label, state.selected == e)
            if pressed then plugin.select(e, nil) end
            if ImGui.IsItemHovered() then core.setTooltip(e.desc) end
        end
    else
        local rows = searchRows(needle)
        if #rows == 0 then ImGui.TextDisabled('No command matches.') end
        for _, row in ipairs(rows) do
            local e, sub = row.e, row.sub
            if row.danger then
                tc(colors.ERR, '!')
                ImGui.SameLine()
            end
            local _, pressed = ImGui.Selectable(row.label, state.selected == e and state.sub == sub)
            if pressed then plugin.select(e, sub) end
            if ImGui.IsItemHovered() then core.setTooltip(sub and sub.desc or e.desc) end
        end
    end
    ImGui.EndChild()
end

local function drawArgFields(colors, args)
    local hasLoc = false
    for _, a in ipairs(args) do if a.kind == 'x' or a.kind == 'y' then hasLoc = true end end
    for i, a in ipairs(args) do
        ImGui.SetNextItemWidth(core.px(220))
        local v = ImGui.InputTextWithHint('##gmarg' .. i, a.label, state.args[i] or '')
        if type(v) == 'string' then state.args[i] = v end
        if a.choices then
            ImGui.SameLine()
            if ImGui.BeginCombo('##gmargc' .. i, '', ImGuiComboFlags and ImGuiComboFlags.NoPreview or 0) then
                for _, c in ipairs(a.choices) do
                    local _, pressed = ImGui.Selectable(c)
                    if pressed then state.args[i] = c end
                end
                ImGui.EndCombo()
            end
        end
        if a.kind == 'name' and state.target then
            ImGui.SameLine()
            if ImGui.SmallButton('Target##gmargt' .. i) then state.args[i] = state.target.name end
            if ImGui.IsItemHovered() then core.setTooltip('Fill in ' .. state.target.name) end
        elseif a.kind == 'zone' and state.zone ~= '' then
            ImGui.SameLine()
            if ImGui.SmallButton('This zone##gmargz' .. i) then state.args[i] = state.zone end
            if ImGui.IsItemHovered() then core.setTooltip('Fill in ' .. state.zone) end
        end
        ImGui.SameLine()
        ImGui.TextDisabled(a.label)
    end
    if hasLoc then
        if ImGui.SmallButton('Fill my location##gmloc') then
            local x, y, z, h = myLoc()
            for i, a in ipairs(args) do
                if a.kind == 'x' then state.args[i] = string.format('%.2f', x)
                elseif a.kind == 'y' then state.args[i] = string.format('%.2f', y)
                elseif a.kind == 'z' then state.args[i] = string.format('%.2f', z)
                elseif a.kind == 'h' then state.args[i] = string.format('%.1f', h) end
            end
        end
        if ImGui.IsItemHovered() then core.setTooltip('Your X / Y / Z (and heading) into the matching boxes.') end
    end
end

local function drawRunRow(colors, line, danger)
    if not line then return end
    ImGui.Text('Line:')
    ImGui.SameLine()
    tc(danger and colors.ERR or colors.GOLD, line)
    if ImGui.Button('Run##gmRun', core.px(90), core.px(24)) then plugin.run(line) end
    if ImGui.IsItemHovered() then core.setTooltip('/say ' .. line .. (danger and '\nMarked destructive: asks first while Confirm is on.' or '')) end
    ImGui.SameLine()
    if plugin.isFavorite(line) then
        if ImGui.Button('Unpin##gmFav', core.px(70), core.px(24)) then plugin.removeFavorite(line) end
    else
        if ImGui.Button('Pin##gmFav', core.px(70), core.px(24)) then plugin.addFavorite(line) end
    end
    if ImGui.IsItemHovered() then core.setTooltip('Keep this exact line in Favourites.') end
    ImGui.SameLine()
    if ImGui.Button('Copy##gmCopy', core.px(70), core.px(24)) then pcall(ImGui.SetClipboardText, line) end
    if ImGui.IsItemHovered() then core.setTooltip('Copy the line to the clipboard.') end
end

local function drawDetailPane(colors, w, h)
    if not ImGui.BeginChild('##gmDetail', w, h, true) then ImGui.EndChild() return end
    local e = state.selected
    if not e then
        ImGui.TextDisabled('Pick a command on the left, or search.')
        ImGui.Spacing()
        ImGui.TextWrapped('Arguments come from the [brackets] of the syntax line. A blank box is left out of the line; the line shown under the boxes is exactly what is sent (as /say, which the server intercepts for # commands).')
        ImGui.EndChild()
        return
    end

    local danger = logic.isDanger(e, state.sub)
    tc(colors.ARC, e.syntax)
    if danger then
        ImGui.SameLine()
        tc(colors.ERR, '!')
        if ImGui.IsItemHovered() then core.setTooltip('Destructive: asks before sending while Confirm is on.') end
    end
    ImGui.TextWrapped(e.desc)
    if e.note then ImGui.TextDisabled(e.note) end
    local tl = logic.targetLabel(e.target)
    if tl then ImGui.TextDisabled('Acts on: ' .. tl) end
    if e.target == 'npc' and state.target and state.target.type ~= 'NPC' then
        tc(colors.WARN, 'Your target is not an NPC.')
    elseif e.target == 'pc' and state.target and state.target.type ~= 'PC' then
        tc(colors.WARN, 'Your target is not a player.')
    elseif (e.target == 'npc' or e.target == 'pc') and not state.target then
        tc(colors.WARN, 'No target.')
    end
    if e.aliases then ImGui.TextDisabled('Also: #' .. table.concat(e.aliases, ', #')) end
    ImGui.Separator()

    if e.subs then
        ImGui.TextDisabled(string.format('Subcommands (%d)', #e.subs))
        local listH = math.min(core.px(220), core.px(20) * (#e.subs + 1))
        if ImGui.BeginChild('##gmSubs', 0, listH, true) then
            if ImGui.BeginTable('##gmSubTbl', 2, ImGuiTableFlags and bit.bor(ImGuiTableFlags.RowBg, ImGuiTableFlags.BordersInnerV) or 0) then
                ImGui.TableSetupColumn('Subcommand', ImGuiTableColumnFlags and ImGuiTableColumnFlags.WidthFixed or 0, core.px(260))
                ImGui.TableSetupColumn('Description', ImGuiTableColumnFlags and ImGuiTableColumnFlags.WidthStretch or 0)
                for i, sub in ipairs(e.subs) do
                    ImGui.TableNextRow()
                    ImGui.TableNextColumn()
                    if sub.danger then tc(colors.ERR, '!') ImGui.SameLine() end
                    local _, pressed = ImGui.Selectable(sub.syntax .. '##gmsub' .. i, state.sub == sub)
                    if pressed then plugin.select(e, sub) end
                    ImGui.TableNextColumn()
                    ImGui.Text(sub.desc)
                    if sub.aliases then
                        ImGui.SameLine()
                        ImGui.TextDisabled('(#' .. table.concat(sub.aliases, ', #') .. ')')
                    end
                end
                ImGui.EndTable()
            end
        end
        ImGui.EndChild()
        if state.sub then
            tc(colors.GOLD, '#' .. e.name .. ' ' .. state.sub.syntax)
            ImGui.SameLine()
            ImGui.TextDisabled(state.sub.desc)
        else
            ImGui.TextDisabled('Pick a subcommand, or run the bare command.')
        end
        ImGui.Separator()
    end

    local args = currentArgs()
    if #args > 0 then drawArgFields(colors, args) end
    drawRunRow(colors, currentLine(), danger)
    ImGui.EndChild()
end

local function drawBottom(colors, h)
    if not ImGui.BeginChild('##gmBottom', 0, h, true) then ImGui.EndChild() return end
    -- free-form line
    ImGui.Text('Any line:')
    ImGui.SameLine()
    ImGui.SetNextItemWidth(core.px(320))
    local v, changed = ImGui.InputTextWithHint('##gmCustom', '#command args', state.custom or '', ImGuiInputTextFlags and ImGuiInputTextFlags.EnterReturnsTrue or 0)
    if type(v) == 'string' then state.custom = v end
    ImGui.SameLine()
    if ImGui.Button('Run##gmCustomRun', core.px(60), core.px(22)) or changed == true then
        if plugin.run(state.custom) then state.custom = '' end
    end
    ImGui.SameLine()
    if ImGui.Button('Pin##gmCustomPin', core.px(50), core.px(22)) then plugin.addFavorite(state.custom) end
    if state.status ~= '' then
        ImGui.SameLine()
        ImGui.TextDisabled(state.status)
    end
    ImGui.Separator()

    local okW, availW, availH = pcall(ImGui.GetContentRegionAvail)
    if not okW or type(availW) ~= 'number' then availW, availH = core.px(600), core.px(120) end
    local half = (availW - core.px(8)) / 2

    if ImGui.BeginChild('##gmFavs', half, availH, false) then
        tc(colors.GOLD, 'Favourites')
        if #settings.favorites == 0 then ImGui.TextDisabled('Pin a line to keep it here.') end
        local removeIdx = nil
        for i, f in ipairs(settings.favorites) do
            if ImGui.SmallButton('Run##gmfr' .. i) then plugin.run(f) end
            ImGui.SameLine()
            if ImGui.SmallButton('x##gmfx' .. i) then removeIdx = i end
            if ImGui.IsItemHovered() then core.setTooltip('Unpin') end
            ImGui.SameLine()
            if favDanger[f] then tc(colors.ERR, f) else ImGui.Text(f) end
            if ImGui.IsItemHovered() then core.setTooltip('Click Run to send; click the line to load it into the Any line box.') end
            if ImGui.IsItemClicked() then state.custom = f end
        end
        if removeIdx then plugin.removeFavorite(settings.favorites[removeIdx]) end
    end
    ImGui.EndChild()
    ImGui.SameLine()
    if ImGui.BeginChild('##gmHist', half, availH, false) then
        tc(colors.GOLD, 'History')
        ImGui.SameLine()
        if ImGui.SmallButton('Clear##gmHistClear') then settings.history = {}; core.saveLoadout(true) end
        if #settings.history == 0 then ImGui.TextDisabled('Nothing sent yet.') end
        for i, hh in ipairs(settings.history) do
            if ImGui.SmallButton('Run##gmhr' .. i) then plugin.run(hh.line) end
            ImGui.SameLine()
            if ImGui.SmallButton('Pin##gmhp' .. i) then plugin.addFavorite(hh.line) end
            ImGui.SameLine()
            ImGui.TextDisabled(hh.time)
            ImGui.SameLine()
            if hh.danger then tc(colors.ERR, hh.line) else ImGui.Text(hh.line) end
            if ImGui.IsItemClicked() then state.custom = hh.line end
        end
    end
    ImGui.EndChild()
    ImGui.EndChild()
end

local function drawConfirm(colors)
    if not state.confirm then
        state.confirmOpened = false
        return
    end
    local popupId = 'Confirm GM command##gmConfirmPopup'
    -- Opened once, when the line is first held; the modal then stays up until
    -- Send / Cancel (a modal is not dismissed by clicking elsewhere).
    if not state.confirmOpened then
        ImGui.OpenPopup(popupId)
        state.confirmOpened = true
    end
    if ImGui.BeginPopupModal(popupId, nil, ImGuiWindowFlags and ImGuiWindowFlags.AlwaysAutoResize or 0) then
        tc(colors.ERR, 'This command is marked destructive.')
        ImGui.Text('Send:')
        ImGui.SameLine()
        tc(colors.GOLD, logic.redactLine(state.confirm))
        if ImGui.Button('Send##gmConfirmOk', core.px(90), core.px(24)) then
            local line = state.confirm
            state.confirm = nil
            state.confirmOpened = false
            plugin.run(line, true)
            ImGui.CloseCurrentPopup()
        end
        ImGui.SameLine()
        if ImGui.Button('Cancel##gmConfirmNo', core.px(90), core.px(24)) then
            state.confirm = nil
            state.confirmOpened = false
            state.status = 'Cancelled.'
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
    else
        -- closed some other way after it was opened: drop the held line
        state.confirm = nil
        state.confirmOpened = false
    end
end

local function drawWindow()
    if not ctrl or not ctrl.show_gm_commands then return end
    poll(false)
    local colors = colorsOf()

    core.pushTheme()
    ImGui.SetNextWindowCollapsed(false, ImGuiCond.Appearing)
    ImGui.SetNextWindowSize(core.px(860), core.px(620), ImGuiCond.FirstUseEver)
    local windowFlags = 0
    if ImGuiWindowFlags then
        windowFlags = bit.bor(ImGuiWindowFlags.AlwaysUseWindowPadding) ---@diagnostic disable-line: deprecated
    end
    core.preBeginWindow('gm_commands')
    local open, draw = ImGui.Begin('Triune GM Commands###TriuneGMCommands', ctrl.show_gm_commands, core.windowFlags and core.windowFlags('gm_commands', windowFlags) or windowFlags)
    if not open then
        ctrl.show_gm_commands = false
        if core.preEndWindow then core.preEndWindow('gm_commands', false) end
        ImGui.End()
        core.popTheme()
        core.saveLoadout(true)
        return
    end
    if not draw then
        if core.preEndWindow then core.preEndWindow('gm_commands', false) end
        ImGui.End()
        core.popTheme()
        return
    end
    core.postBeginWindow('gm_commands')

    if ImGui.BeginPopupContextWindow('##gmContextMenu') then
        if core.applyWindowScale then core.applyWindowScale('gm_commands') end
        if core.drawWindowMenuItems then
            core.drawWindowMenuItems('gm_commands', { header = false, close = false })
            ImGui.Separator()
        end
        drawSettingsBody()
        ImGui.EndPopup()
    end

    drawHeader(colors)
    ImGui.Separator()
    drawQuickBar(colors)
    ImGui.Separator()

    local okW, availW, availH = pcall(ImGui.GetContentRegionAvail)
    if not okW or type(availW) ~= 'number' then availW, availH = core.px(840), core.px(500) end
    local bottomH = core.px(170)
    local paneH = math.max(core.px(120), availH - bottomH - core.px(8))
    local listW = math.max(core.px(180), math.min(core.px(260), availW * 0.3))
    drawListPane(colors, listW, paneH)
    ImGui.SameLine()
    drawDetailPane(colors, 0, paneH)
    drawBottom(colors, bottomH)
    drawConfirm(colors)

    -- true: this window draws its own right-click menu (BeginPopupContextWindow
    -- above, with core.drawWindowMenuItems), so the core must not open a second one.
    if core.preEndWindow then core.preEndWindow('gm_commands', true) end
    ImGui.End()
    core.popTheme()
end

function plugin.onDrawUI()
    if not core then return end
    refresh()
    drawWindow()
end

function plugin.onDrawSettings()
    if not core then return end
    refresh()
    local GOLD = (core.colors and core.colors.GOLD) or { 1.0, 0.70, 0.54, 1 }
    core.accent(GOLD, 'GM Commands')
    local isWinOpen = (ctrl.show_gm_commands == true)
    if ImGui.Button((isWinOpen and 'Window: Visible (Click to Hide)' or 'Window: Hidden (Click to Show)') .. '##gmToggleWin', core.px(250), core.px(24)) then
        plugin.openWindow(not isWinOpen)
    end
    ImGui.Spacing()
    ImGui.TextDisabled('Needs GM status on the account; a # line from a normal account is just ignored by the server.')
    ImGui.TextDisabled(string.format('%d commands in the reference. /ac gm <line> runs one from a hot button or over the Box Network.', #COMMANDS))
    ImGui.Spacing()
    drawSettingsBody()
end

-- /ac gm                 toggle the window
-- /ac gm help            print the usage
-- /ac gm <line>          run a # line ('/ac gm zone poknowledge', '/ac gm #heal')
function plugin.onCommand(cmd, args)
    if cmd ~= 'gm' and cmd ~= 'gmcmd' then return false end
    refresh()
    local rest = {}
    for i = 2, #(args or {}) do rest[#rest + 1] = tostring(args[i]) end
    local line = trim(table.concat(rest, ' '))
    if line == '' then
        plugin.openWindow()
        say('GM Commands %s.', ctrl.show_gm_commands and 'OPENED' or 'CLOSED')
    elseif lower(line) == 'help' then
        say('usage: /ac gm (toggle window) | /ac gm <#command args> (run it, e.g. /ac gm zone poknowledge)')
    elseif logic.lineSecret(logic.normalizeLine(line) or '') then
        -- /ac lines can arrive over the Box Network (and land in logs), so
        -- credential commands only run from the window itself.
        say('%s refused: credential commands only run from the GM Commands window.', logic.redactLine(logic.normalizeLine(line)))
    else
        if plugin.run(line) then
            say('Sent %s', state.lastSent)
        elseif state.confirm then
            say('%s is marked destructive: confirm it in the GM Commands window (or turn Confirm off).', logic.redactLine(state.confirm))
            plugin.openWindow(true)
        else
            say('%s', state.status)
        end
    end
    return true
end

plugin.help = {
    '  \ag/ac gm\ax - Toggle the GM Commands window (reference & runner for the server\'s # commands)',
    '  \ag/ac gm <#command args>\ax - Run a GM command line (e.g. /ac gm zone poknowledge)',
}

-- Exposed for tests
plugin.logic = logic
plugin.state = state
plugin.settings = settings
plugin.COMMANDS = COMMANDS
plugin.BY_NAME = BY_NAME
plugin.CATEGORIES = CATEGORIES
plugin.STATUS_LEVELS = STATUS_LEVELS
plugin.QUICK = QUICK

return plugin
