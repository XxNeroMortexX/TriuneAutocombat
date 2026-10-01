-- Test the actual core dispatch/movement gates and ImGui helpers, not copies of their logic.
local f = assert(io.open('TAC/lua/triune.lua', 'r')); local source = f:read('*a'); f:close()
local on, allowed, hostile, range, id = true, false, true, true, 100
local calls = {}
local controller = { enabled = function() return on end, ownerAllowed = function() return allowed end }
local runtime = { petCamp = controller,
    isDetrimentalAction = function(_, _, entry) return entry and entry.kind == 'dd' end,
    isTargetInRange = function() return range end,
}
local mq = { TLO = { Target = { ID = function() return id end }, Me = { ID = function() return 277 end } } }
local env = setmetatable({ runtime = runtime, mq = mq, isHostileTarget = function() return hostile end }, { __index = _G })
local gates = assert(source:match('(function runtime%.petCampActive.-)\nfunction runtime%.isTargetInRange'))
assert(load(gates, 'stationaryActionGates', 't', env))()
assert(not runtime.petCampActionAllowed('Nuke', { kind = 'dd' }, 100))
allowed = true; assert(runtime.petCampActionAllowed('Nuke', { kind = 'dd' }, 100))
range = false; assert(not runtime.petCampActionAllowed('Nuke', { kind = 'dd' }, 100))
assert(not runtime.petCampActionAllowed('Heal Pet', { kind = 'heal' }, 280))
assert(runtime.petCampActionAllowed('Self Buff', { kind = 'buff' }, 277))
controller.probe = {}; assert(not runtime.petCampActionAllowed('Self Buff', { kind = 'buff' }, 277)); controller.probe = nil
on = false; assert(runtime.petCampActionAllowed('Nuke', { kind = 'dd' }, 100)); on = true

-- Every casting dispatcher refuses an unauthorized offensive action before any MQ side effect.
local signatures = { 'function runtime.castGem(i, g, id)', 'function runtime.fireAA(name, a, id)',
    'runtime.fireDisc = function(name, a, id)', 'runtime.fireSkill = function(name, a, id)', 'runtime.useClickie = function(c, id)' }
runtime.petCampActionAllowed = function() return false end
for _, signature in ipairs(signatures) do
    local start = assert(source:find(signature, 1, true))
    local guardEnd = assert(source:find('then return false end', start, true)) + #'then return false end' - 1
    local guard = source:sub(start, guardEnd) .. '\nerror("dispatcher escaped gate")\nend'
    assert(load(guard, 'dispatch', 't', env))()
end
assert(runtime.castGem(1, { spell = 'Nuke' }, 100) == false)
assert(runtime.fireAA('Nuke', {}, 100) == false)
assert(runtime.fireDisc('Nuke', {}, 100) == false)
assert(runtime.fireSkill('Kick', {}, 100) == false)
assert(runtime.useClickie({ name = 'Wand' }, 100) == false)

-- moveToward remains a range/LoS check in stationary mode, with no command after its guard.
runtime.petCampActionAllowed = nil
local start = assert(source:find('function runtime.moveToward(id, dist, followOnly)', 1, true))
local finish = assert(source:find('\n    local NAV_CONST', start, true))
env.distToId = function() return 40 end; env.desiredRange = function() return 15 end; env.hasLoS = function() return true end
assert(load(source:sub(start, finish - 1) .. '\nerror("unexpected chase")\nend', 'moveGate', 't', env))()
assert(runtime.moveToward(100, 15) == false and runtime.moveToward(100, 50) == true)
assert(source:find('if not runtime.petCampActive() then\n    local assistThreshold', 1, true))
assert(source:find('haveNPC, engage = runtime.petCamp:combatTick()', 1, true))

-- False is a known OFF; unknown is never highlighted. Test two-result button bindings.
local value, colors, vars, draws, tooltip = nil, 0, 0, 0, nil
local uiEnv = setmetatable({ UI = {}, runtime = { petCamp = {
    value = function() return value end, allValue = function() return value end } },
    ImGuiStyleVar = { FrameBorderSize = 1 },
    pushButtonColors = function() colors = colors + 4; return 4 end,
    ImGui = { PushStyleVar = function() vars = vars + 1 end, PopStyleVar = function() vars = vars - 1 end,
        PopStyleColor = function(n) colors = colors - n end,
        Button = function() draws = draws + 1; return false, true end,
        SmallButton = function() draws = draws + 1; return true, true end,
        IsItemHovered = function() return false end,
        SetTooltip = function(t) tooltip = t end,
    },
}, { __index = _G })
local button = assert(source:match('(function UI%.petStateButton.-\nend)\n\nfunction UI%.drawPetControlTab'))
assert(load(button, 'petButton', 't', uiEnv))()
assert(uiEnv.UI.petStateButton('OFF', 280, 'taunt', false) == true)
assert(colors == 0 and vars == 0 and draws == 1)
value = false; assert(uiEnv.UI.petStateButton('OFF', 280, 'taunt', false) == true)
assert(colors == 0 and vars == 0)
value = true; assert(uiEnv.UI.petStateButton('ON', 'all', 'taunt', true, true) == false)
assert(colors == 0 and vars == 0 and draws == 3)
-- Execute the real far-pet dispatch lease: no chase, no ranged trigger, stop near melee reach.
local now, dist, targetId, ranged, casting = 0, 300, 100, false, false
local commandLog = {}
local dispatchRuntime = { petCamp = { phase = 'GATHER' }, serverAttackMode = 'Melee',
    petCampActive = function() return true end,
    revertAttackModeToMelee = function() ranged = false end }
local dispatchEnv = setmetatable({ runtime = dispatchRuntime, ctrl = { running = true },
    os = { clock = function() return now end },
    isSpawnAlive = function() return true end, distToId = function() return dist end,
    maxMeleeDistance = function() return 15 end, isCastingOrStarting = function() return casting end,
    mq = { cmd = function(command) commandLog[#commandLog + 1] = command end,
        TLO = { Target = { ID = function() return targetId end }, Me = { AutoFire = function() return false end } } },
}, { __index = _G })
local dispatchCode = assert(source:match('(function runtime%.endPetCampDispatch.-)\nfunction runtime%.initPetCamp'))
assert(load(dispatchCode, 'farPetDispatch', 't', dispatchEnv))()
dispatchRuntime.beginPetCampDispatch(100); assert(#commandLog == 0)
now = 0.2; dispatchRuntime.checkPetCampDispatch(); assert(#commandLog == 0)
now = 0.4; dispatchRuntime.checkPetCampDispatch(); assert(commandLog[2] == '/attack on')
assert(dispatchRuntime.petCampDispatchActive())
dist = 17; dispatchRuntime.checkPetCampDispatch(); assert(not dispatchRuntime.petCampPulse and commandLog[3] == '/attack off')
dist = 300; dispatchRuntime.serverAttackMode = 'Ranged'; dispatchRuntime.petCampMeleeConfirmed = false
now = 1; dispatchRuntime.beginPetCampDispatch(100); now = 1.5; dispatchRuntime.checkPetCampDispatch()
assert(not dispatchRuntime.petCampDispatchActive() and #commandLog == 3)
dispatchRuntime.serverAttackMode = 'Melee'; dispatchRuntime.petCampMeleeConfirmed = true
dispatchRuntime.checkPetCampDispatch(); assert(dispatchRuntime.petCampDispatchActive() and commandLog[#commandLog] == '/attack on')
targetId = 101; dispatchRuntime.checkPetCampDispatch(); assert(not dispatchRuntime.petCampPulse and commandLog[#commandLog] == '/attack off')
dispatchRuntime.endPetCampDispatch(true); assert(commandLog[#commandLog] == '/attack off') -- Even without a tracked pulse.
print('PASS: actual action gates, all five dispatchers, no-chase movement guard, original command isolation and balanced pet-button styles')

-- Execute the actual host snapshot predicate with the real TLO placement.
local safe = assert(source:match('safeProbe = function%(%)%s*(.-)\n        end,'))
local idle = true
local probeRuntime = { petCamp = { phase = 'IDLE' }, anyXtarAlive = function() return not idle end }
local probeEnv = setmetatable({ runtime = probeRuntime,
    mq = { TLO = { MacroQuest = {}, EverQuest = { GameState = function() return 'INGAME' end },
        Me = { Dead = function() return false end, Feigning = function() return false end,
            Moving = function() return false end, Combat = function() return false end } } },
    isCastingOrStarting = function() return false end }, { __index = _G })
local safeProbe = assert(load('return function() '..safe..' end', 'safeSnapshot', 't', probeEnv))()
assert(safeProbe()); idle = false; assert(not safeProbe()); idle = true
probeRuntime.petCamp.phase = 'GATHER'; assert(not safeProbe())
print('PASS: safe automatic snapshots use EverQuest.GameState and defer during fights/pulls')
