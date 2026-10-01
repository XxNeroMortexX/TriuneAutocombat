package.path = 'TAC/lua/?.lua;' .. package.path
-- Execute the actual UI helper and loadout sanitizer without launching MacroQuest.
local f = assert(io.open('TAC/lua/triune.lua', 'r'))
local source = f:read('*a'); f:close()
assert(loadfile('TAC/lua/triune.lua'))
assert(loadfile('TAC/lua/tac/auto_aa.lua'))
local edited, received
local env = { UI = {}, math = math, tonumber = tonumber,
    ImGui = { SliderInt = function(label, current, minimum, maximum, format, flags)
        received = { current = current, minimum = minimum, maximum = maximum, flags = flags }
        return edited or current, true
    end } }
local helper = assert(source:match('(function UI%.distanceSlider.-\nend)\n\nfunction UI%.drawControlTab'))
assert(load(helper, 'distanceSlider', 't', env))()
for _, setting in ipairs({ { 10, 500 }, { 15, 250 }, { 50, 2000 } }) do
    local minimum, scale = setting[1], setting[2]
    edited = nil
    env.UI.distanceSlider('test', scale, minimum, scale)
    assert(received.maximum == 10000 and received.minimum == minimum)
    edited = 60000
    local result, changed = env.UI.distanceSlider('test', scale, minimum, scale)
    assert(result == 60000 and changed and received.flags == 0)
    edited = nil
    result, changed = env.UI.distanceSlider('test', 60000, minimum, scale)
    assert(result == 60000 and not changed and received.maximum == 60000)
    edited = -5
    result = env.UI.distanceSlider('test', 60000, minimum, scale)
    assert(result == minimum)
end
-- Keep native slider drag bounds representable without clamping typed values.
edited = 1500000000
assert(env.UI.distanceSlider('large', 1500000000, 10, 500) == 1500000000)
assert(received.maximum == 1073741823)
local sanitize = assert(source:match('(local function sanitizeModeConfig.-\nend)\n\n%-%- Single source'))
local sanitizeEnv = setmetatable({ MODES = { PULL_CON_LIST = {} } }, { __index = _G })
local cleanup = assert(load(sanitize .. '\nreturn sanitizeModeConfig', 'sanitize', 't', sanitizeEnv))()
local saved = { mode = 'Puller', submode = 'Camp', auto_spend_aa_threshold = 1,
    camp_radius = 60000, hunter_radius = 80000, pull_engage_dist = 40000 }
cleanup(saved)
assert(saved.auto_spend_aa_threshold == 1)
assert(saved.camp_radius == 60000 and saved.hunter_radius == 80000 and saved.pull_engage_dist == 40000)
saved.auto_spend_aa_threshold = 0; cleanup(saved)
assert(saved.auto_spend_aa_threshold == 1)
local plugin = dofile('TAC/lua/tac/auto_aa.lua')
local saves = 0
plugin.onInit({ ctrl = saved, runtime = {}, mq = {},
    saveLoadout = function() saves = saves + 1 end })
assert(plugin.AA.threshold() == 1)
saved.auto_spend_aa_threshold = 5
assert(plugin.AA.onCommand('aathreshold', { 'aathreshold', '1' }))
assert(saved.auto_spend_aa_threshold == 1 and plugin.AA.threshold() == 1 and saves == 1)
-- Execute the actual bank slider block with a two-result binding, including saved edits.
local bankBlock = assert(assert(io.open('TAC/lua/tac/auto_aa.lua')):read('*a'):match(
    '(    local curThresh = AA%.threshold%(%)\n.-)\n    if ImGui%.IsItemHovered%(%) then'))
local bankEnv = { AA = plugin.AA, ctrl = saved, math = math,
    core = { saveLoadout = function() saves = saves + 1 end },
    ImGui = { SliderInt = function(_, _, minimum) assert(minimum == 1); return 1, true end,
        IsItemDeactivatedAfterEdit = function() return true end } }
saved.auto_spend_aa_threshold = 5
assert(load(bankBlock, 'bankSlider', 't', bankEnv))()
assert(saved.auto_spend_aa_threshold == 1 and saves == 2)
print('PASS: large distance input, dynamic drag scales, positive minimums, saved ranges, bank 1 load/UI/purchase helper/command')
