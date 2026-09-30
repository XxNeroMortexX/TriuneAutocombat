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
        if label == 'Allow group invite tells' then return not value end
        return value
    end,
    Combo = function() return 3 end }
local core = { ctrl = c, mq = mq, ImGui = ui, px = function(v) return v end,
    accent = function() end, saveLoadout = function() saves = saves + 1 end }
plugin.onInit(core)
local event = assert(events.TacSocialTellCommand)
assert(event.pattern == "#1# tells you, '#2#'")
assert(c.tell_group_invite == false and c.tell_dzadd == false and c.tell_social_permission == 'listed')
local function tell(line, expected)
    now = now + 2500
    local before = #commands
    event.handler(line)
    assert(#commands == before + (expected and 1 or 0), 'Unexpected dispatch: ' .. line)
    if expected then assert(commands[#commands] == expected, commands[#commands]) end
end
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
    "Alice tells you, 'invite Bob' trailing", "Alice tells you, 'invite '" }) do tell(line) end
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
dzLeader, dzName = 'Bot', ''; tell("Alice tells you, 'dzadd me'")
dzName = 'Test expedition'; tell("Alice tells you, 'dzadd me'", '/dzadd Alice')
-- Unsupported optional fields defer the final permissions check to the game.
mq.TLO.Group = nil; tell("Alice tells you, 'invite me'", '/invite Alice')
-- Plugin Configure exposes the toggles and saves each edited setting.
local priorToggle = c.tell_group_invite
plugin.onDrawSettings()
assert(c.tell_group_invite ~= priorToggle and c.tell_social_permission == 'anyone' and saves == 2)
plugin.onDestroy()
assert(removed.TacSocialTellCommand and next(events) == nil)
-- Re-initialization preserves saved values instead of forcing them off.
plugin.onInit(core)
assert(c.tell_dzadd and c.tell_social_permission == 'anyone')
plugin.onDestroy()
print('PASS: tell parsing, authorization, cooldown, leadership, settings, event cleanup, and saved values')
