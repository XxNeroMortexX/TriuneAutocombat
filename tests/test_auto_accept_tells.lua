-- Isolated tell event checks; no MacroQuest connection or live commands.
local pluginPath = 'TAC/lua/tac/auto_accept.lua'
assert(loadfile(pluginPath))
local plugin = dofile(pluginPath)
local events, commands, removed = {}, {}, {}
local now, groupCount, groupLeader, dzName, dzLeader = 10000, 0, 'Bot', 'Test expedition', 'Bot'
local memberNames, spawnGuild, spawnName = {}, 'Friends', 'Alice'
local saves = 0
local c = { auto_accept_names = { { name = 'Alice', id = 12 } }, auto_accept_anyone = true }
local function field(v) return function() return v end end
local sp = setmetatable({ ID = field(12), Type = field('PC'),
    CleanName = function() return spawnName end, Guild = function() return spawnGuild end },
    { __call = function() return 'Alice' end })
local mq = { gettime = function() return now end,
    event = function(name, pattern, handler) events[name] = { pattern = pattern, handler = handler } end,
    unevent = function(name) removed[name] = true; events[name] = nil end,
    cmd = function(cmd) commands[#commands + 1] = cmd end,
    TLO = { Me = { CleanName = field('Bot'), Guild = field('Friends') },
        Spawn = function() return sp end,
        Group = { Members = function() return groupCount end,
            Leader = { Name = function() return groupLeader end },
            Member = function(i) return { Name = field(memberNames[i]) } end },
        DynamicZone = { Name = function() return dzName end,
            Leader = { Name = function() return dzLeader end } } } }
local ui = { PushID = function() end, PopID = function() end, Separator = function() end,
    Text = function() end, TextDisabled = function() end, TextWrapped = function() end,
    SetNextItemWidth = function() end, IsItemHovered = function() return false end,
    Button = function() return false end,
    Checkbox = function(label, value)
        if label == 'Allow group invite commands' then return not value end
        return value
    end,
    Combo = function() return 3 end }
local core = { ctrl = c, mq = mq, ImGui = ui, px = function(v) return v end,
    accent = function() end, saveLoadout = function() saves = saves + 1 end }
plugin.onInit(core)
local event = assert(events.TacSocialTellCommand)
assert(event.pattern == "#1# tells you, '#2#'")
assert(c.tell_group_invite == false and c.tell_dzadd == false and c.tell_social_permission == 'listed')
local function receive(handler, line, expected)
    now = now + 2500
    local before = #commands
    handler(line)
    assert(#commands == before + (expected and 1 or 0), 'Unexpected dispatch: ' .. line)
    if expected then assert(commands[#commands] == expected, commands[#commands]) end
end
local function tell(line, expected) receive(event.handler, line, expected) end
local guildEvent = assert(events.TacSocialGuildCommand)
assert(guildEvent.pattern == "#1# tells the guild, '#2#'")
local function guild(line, expected) receive(guildEvent.handler, line, expected) end
-- Default-off behavior and independent action switches.
tell("Alice tells you, 'invite me'")
c.tell_group_invite = true
tell("ALICE tells you, ' InViTe Me '", '/invite ALICE')
tell("Alice tells you, 'invite Mortefreddo'", '/invite Mortefreddo')
tell("Alice tells you, 'dzadd me'")
c.tell_dzadd = true
tell("Alice tells you, 'DZADD ME'", '/dzadd Alice')
tell("Alice tells you, 'dzadd Mortefreddo'", '/dzadd Mortefreddo')
-- Sender authorization must not use auto-accept anyone or stale player IDs.
tell("Stranger tells you, 'invite me'")
c.auto_accept_names = { { name = 'Somebodyelse', id = 12 } }
tell("Alice tells you, 'invite me'")
c.auto_accept_names = { 'Alice' }
-- Ordinary chat, quoted tells, outgoing tells, and command injection are inert.
for _, line in ipairs({ "Alice tells you, 'please invite me'", "Alice tells you, 'invite me now'",
    "Alice says, 'Alice tells you, 'invite me''", "You told Alice, 'invite me'",
    "Alice tells you, 'invite Bob; /quit'", "Alice tells you, 'invite ${Me.Name}'",
    "Alice tells you, 'invite /quit'", "Alice tells you, 'dzadd Bob 2'",
    "Alice tells you, 'invite Bob' trailing", "Alice tells you, 'dzadd me now'" }) do tell(line) end
-- One bounded global cooldown suppresses duplicate and alternating commands.
tell("Alice tells you, 'invite me'", '/invite Alice')
local before = #commands
event.handler("Alice tells you, 'dzadd me'")
assert(#commands == before)
-- Separate anyone policy and self-echo protection.
c.tell_social_permission = 'anyone'
tell("Stranger tells you, 'invite me'", '/invite Stranger')
tell("Bot tells you, 'invite Alice'")
tell("Alice tells you, 'invite Bot'")
-- Verify exact player/guild identity; unresolved or mismatched guilds cannot command.
c.tell_social_permission = 'guild'
tell("Alice tells you, 'invite me'", '/invite Alice')
spawnGuild = 'Other guild'; tell("Alice tells you, 'invite me'")
spawnGuild = 'Friends'; spawnName = 'Alicebob'; tell("Alice tells you, 'invite me'")
spawnName = 'Alice'; mq.TLO.Spawn = function() return nil end; tell("Alice tells you, 'invite me'")
mq.TLO.Spawn = function() return sp end
c.tell_social_permission = 'unknown'; tell("Alice tells you, 'invite me'")
c.tell_social_permission = 'listed'
-- Known leadership, full-group, membership, and expedition restrictions.
groupCount, groupLeader = 1, 'Other'; tell("Alice tells you, 'invite me'")
groupLeader, groupCount = 'Bot', 5; tell("Alice tells you, 'invite me'")
groupCount, memberNames = 1, { 'Alice' }; tell("Alice tells you, 'invite me'")
memberNames = { 'Buddy' }; tell("Alice tells you, 'invite me'", '/invite Alice')
dzLeader = 'Other'; tell("Alice tells you, 'dzadd me'")
dzLeader, dzName = 'Bot', ''; tell("Alice tells you, 'dzadd me'", "/tell Alice I'm not in a DZ to invite you.")
dzName = 'Test expedition'; tell("Alice tells you, 'dzadd me'", '/dzadd Alice')
-- Unsupported optional fields defer the final permissions check to the game.
mq.TLO.Group = nil; tell("Alice tells you, 'invite me'", '/invite Alice')
-- No-argument tells default to the sender, including whitespace-only suffixes.
tell("Alice tells you, 'invite'", '/invite Alice')
tell("Alice tells you, ' invite  '", '/invite Alice')
tell("Alice tells you, 'dzadd'", '/dzadd Alice')
-- Guild commands must address this exact bot first, ignoring case.
guild("Alice tells the guild, 'bOt invite'", '/invite Alice')
guild("Alice tells the guild, 'Bot dzadd me'", '/dzadd Alice')
guild("Alice tells the guild, 'Bot invite Mortefreddo'", '/invite Mortefreddo')
guild("Alice tells the guild, 'Bot dzadd Mortefreddo'", '/dzadd Mortefreddo')
for _, line in ipairs({ "Alice tells the guild, 'Otherbot invite'",
    "Alice tells the guild, 'Botty invite'", "Alice tells the guild, 'invite Bot'",
    "Alice tells the guild, 'please Bot dzadd me'", "You say to your guild, 'Bot invite me'",
    "Alice says, 'Alice tells the guild, 'Bot invite me''",
    "Alice tells the guild, 'Bot invite Bob; /quit'",
    "Alice tells the guild, 'Bot dzadd ${Me.Name}'" }) do guild(line) end
guild("Stranger tells the guild, 'Bot invite'")
c.tell_dzadd = false; guild("Alice tells the guild, 'Bot dzadd'")
c.tell_dzadd = true
-- Server-delivered guild messages authorize same-guild policy across zones.
c.tell_social_permission = 'guild'
mq.TLO.Spawn = function() return nil end
guild("Remoteplayer tells the guild, 'Bot dzadd'", '/dzadd Remoteplayer')
tell("Remoteplayer tells you, 'dzadd'")
-- Shared cooldown suppresses a second channel's request/reply.
guild("Remoteplayer tells the guild, 'Bot invite'", '/invite Remoteplayer')
before = #commands
event.handler("Alice tells you, 'invite'")
assert(#commands == before)
c.tell_social_permission = 'listed'
dzName = nil
guild("Alice tells the guild, 'Bot dzadd'", "/tell Alice I'm not in a DZ to invite you.")
before = #commands
guildEvent.handler("Alice tells the guild, 'Bot dzadd'")
assert(#commands == before)
tell("Stranger tells you, 'dzadd'")
dzName = 'NULL'; tell("Alice tells you, 'dzadd'", "/tell Alice I'm not in a DZ to invite you.")
-- Unreadable DZ state cannot trigger a dzadd or a false no-DZ assertion.
mq.TLO.DynamicZone = nil; tell("Alice tells you, 'dzadd'")
-- Plugin Configure exposes the toggles and saves each edited setting.
local priorToggle = c.tell_group_invite
plugin.onDrawSettings()
assert(c.tell_group_invite ~= priorToggle and c.tell_social_permission == 'anyone' and saves == 2)
plugin.onDestroy()
assert(removed.TacSocialTellCommand and removed.TacSocialGuildCommand and next(events) == nil)
-- Re-initialization preserves saved values instead of forcing them off.
plugin.onInit(core)
assert(c.tell_dzadd and c.tell_social_permission == 'anyone')
plugin.onDestroy()
print('PASS: tell/guild parsing, sender defaults, no-DZ replies, authorization, shared cooldown, leadership, settings, and cleanup')
