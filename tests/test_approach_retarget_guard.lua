-- Created By: NeroMorte - Reproduce /attack on during TO_MOB without releasing actual fights.
local f = assert(io.open('TAC/lua/triune.lua')); local source = f:read('*a'); f:close()
local function helper(name) return assert(source:match('(function runtime%.' .. name .. '.-\nend)')) end
local function compile(code, env)
    if _VERSION == 'Lua 5.1' then local fn = assert(loadstring(code)); setfenv(fn, env); return fn() end
    return assert(load(code, 'actualApproachGuard', 't', env))()
end
local state = { attack = true, engaged = false, aggro = false, casting = false, forced = nil,
    petThreat = false, readError = false }
local ctrl = { mode = 'Puller', submode = 'Camp', check_closer_mobs = true, max_closer_retargets = 1,
    camp_radius = 1837, camp_z = 75, pull_min_level = 1, pull_max_level = 100 }
local pursuit = {}
local runtime = { pullTargetId = 285, pullState = 'TO_MOB',
    forcedTargetId = function() return state.forced end,
    targetIsEngaged = function() if state.readError then error('native failed') end; return state.engaged end,
    playerHasAggro = function() return state.aggro end,
    findRoamTarget = function() return 286 end,
    boxnetYieldTarget = function() end, anyXtarAlive = function() return state.engaged end,
    setTarget = function() return true end,
}
local mq = { cmd = function() end, TLO = { Me = { Combat = function() return state.attack end },
    Target = { CleanName = function() return 'synthetic closer mob' end },
    Spawn = function()
        return setmetatable({ TargetOfTarget = { ID = function() return state.petThreat and 555 or 0 end },
            AggroHolder = { ID = function() return 0 end } }, { __call = function() return true end })
    end,
} }
local env = setmetatable({ ctrl = ctrl, runtime = runtime, pursuit = pursuit, mq = mq,
    isHostileTarget = function() return true end, isSpawnMyPet = function(id) return id == 555 end,
    isCastingOrStarting = function() return state.casting end,
    getActiveTargetRequiredCastingId = function() return state.castId end,
    distToId = function(id) return id == 285 and 150 or 50 end,
    hasLoS = function() return true end, stopMoving = function() end, print = function() end,
    firstNPCXtarget = function() end, anyXtarAlive = runtime.anyXtarAlive,
}, { __index = _G })
compile(helper('canReconsiderApproach') .. '\n' .. helper('checkCloserTarget'), env)
assert(runtime.canReconsiderApproach(285), 'attack toggle blocked an untouched far approach')
assert(runtime.checkCloserTarget(285, 1837, 75, 1, 100) == 286)
-- Run the actual Camp approach gate and retarget action from pullerTick.
local start = assert(source:find("    if runtime.pullState == 'TO_MOB' then", source:find('function runtime.pullerTick', 1, true), true))
local finish = assert(source:find('\n    -- IDLE accepts', start, true))
local travel = compile('return function() '..source:sub(start, finish - 1)..' end', env)
pursuit.lastCloserScanAt = 0; travel()
assert(runtime.pullTargetId == 286 and pursuit.retargetCount == 1, 'Camp caller still blocked by attack toggle')
-- Actual Hunt gate uses the same target-aware policy.
local condition = assert(source:match('elseif (not isCurXtar.-runtime%.canReconsiderApproach%(curTid%).-ctrl%.check_closer_mobs.-) then'))
env.isCurXtar = false; env.curTid = 285
ctrl.submode = 'Hunt'
assert(compile('return ' .. condition, env))
for _, flag in ipairs({ 'engaged', 'aggro', 'casting', 'petThreat', 'readError' }) do
    state[flag] = true
    assert(not runtime.canReconsiderApproach(285), flag .. ' must keep the fight/cast protected')
    state[flag] = false
end
state.forced = 285; assert(not runtime.canReconsiderApproach(285)); state.forced = nil
state.castId = 285; assert(not runtime.canReconsiderApproach(285)); state.castId = nil
-- Original retarget quota and cycle protection remain effective.
pursuit.lastCloserScanAt = 0; assert(runtime.checkCloserTarget(285) == nil)
pursuit.retargetCount = 0; pursuit.cycleTargetIds = { [286] = true }
assert(runtime.checkCloserTarget(285) == nil)
print('PASS: attack-on approach can retarget in Camp/Hunt; engaged/aggro/pet/cast/force/read-error guards and quotas remain')
