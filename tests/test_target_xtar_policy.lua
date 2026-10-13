-- Created By: NeroMorte - Exercise shipped slot gates, combat counters and target switches.
local f = assert(io.open('TAC/lua/triune.lua', 'r'))
local source = f:read('*a'); f:close()
local function helper(name, prefix)
    return assert(source:match('(' .. (prefix or 'function runtime%.') .. name .. '.-\nend)'), name)
end
local function compile(code, env)
    if _VERSION == 'Lua 5.1' then
        local fn = assert(loadstring(code)); setfenv(fn, env); return fn()
    end
    return assert(load(code, 'actualTargetPolicy', 't', env))()
end
local ctrl = { mode = 'Puller', submode = 'Hunt', ignore_distant_xtargets = true,
    xtar_nav_dist = 150, manual_auto_xtarget = true }
local runtime = { pullState = 'IDLE', pullTargetId = 0 }
local state = { meCombat = false, combatState = 'RESTING', current = 0, changed = 0 }
local mobs = {
    [1] = { distance = 50, hp = 80 },
    [2] = { distance = 900, hp = 20 },
    [3] = { distance = 15, hp = 100 },
}
local function spawn(id)
    local m = mobs[id]
    return setmetatable({
        ID = function() return m and id or 0 end, Type = function() return 'NPC' end,
        Dead = function() return m and m.dead or false end,
        CleanName = function() return 'mob' .. tostring(id) end,
        Distance3D = function() if m and m.distanceError then error('native distance failed') end; return m and m.distance end,
        Distance = function() return m and m.distance end,
        PctHPs = function() return m and m.hp end, Z = function() return 0 end,
        TargetOfTarget = { ID = function() return m and m.owner or 0 end },
        AggroHolder = { ID = function() return m and m.owner or 0 end },
        PctAggro = function() return m and m.aggro or 0 end,
    }, { __call = function() return m ~= nil end })
end
local slots = { 2 }
local target = setmetatable({}, {
    __call = function() return state.current > 0 and mobs[state.current] ~= nil end,
    __index = function(_, key) return spawn(state.current)[key] end,
})
local mq = { cmd = function() end, TLO = {
    Spawn = spawn, Target = target, Me = {
        ID = function() return 100 end, Z = function() return 0 end,
        Combat = function() return state.meCombat end, AutoFire = function() return false end,
        CombatState = function() return state.combatState end,
        XTHaterCount = function() return #slots end, XTAggroCount = function() return #slots end,
        XTargetSlots = function() return #slots end,
        XTarget = function(i) return spawn(slots[i]) end,
    },
} }
local function hostile(id) return mobs[id] ~= nil and not mobs[id].dead and not mobs[id].friendly end
local function ignored(name) return name == 'mob' .. tostring(state.ignored) end
local env = setmetatable({ ctrl = ctrl, runtime = runtime, mq = mq, pursuit = {},
    isHostileTarget = hostile, isUnreachable = function(id) return mobs[id] and mobs[id].unreachable end,
    isIgnored = ignored, isSpawnAlive = hostile, isGroupOrRaidMember = function() return false end,
    isSpawnPetOrPlayer = function() return false end, isSpawnMyPet = function(id) return id == 101 end,
    xtSlotFightingMe = function(xt) return xt.TargetOfTarget.ID() == 100 or xt.TargetOfTarget.ID() == 101 or xt.PctAggro() > 0 end,
    xtSlotEngaged = function() return true end,
    isCastingOrStarting = function() return false end, getActiveTargetRequiredCastingId = function() end,
    stopMoving = function() end, print = function() end,
    os = { clock = function() return 10 end },
}, { __index = _G })
runtime.forcedTargetId = function() return state.force end
runtime.setTarget = function(id) state.current = id; state.changed = state.changed + 1; return true end
runtime.playerIsEngagingTarget = function() return state.meCombat end
runtime.targetIsEngaged = function(id) return mobs[id] and mobs[id].engaged or false end
compile(helper('ownsPullXtarget') .. '\n' .. helper('xtSlotCounts', 'local function ') ..
    '\nreturn xtSlotCounts', env)
-- Export the actual local so independently extracted callers use the shipped gate.
env.xtSlotCounts = compile(helper('xtSlotCounts', 'local function ') .. '\nreturn xtSlotCounts', env)
env.isXTargetId = function(id)
    for _, xid in ipairs(slots) do if xid == id then return hostile(id) and env.xtSlotCounts(spawn(id), id) end end
    return false
end
compile(helper('xtSnapshot') .. '\n' .. helper('countNPCXtarget') .. '\n' .. helper('anyXtarAlive') ..
    '\n' .. helper('findFirstNPCXtarget') .. '\n' .. helper('keepCurrentCombatTarget') ..
    '\n' .. helper('checkAggroSwitch') .. '\n' .. helper('hasDowntimeAggroThreat'), env)
env.isCombat = compile(helper('isCombat', 'local function ') .. '\nreturn isCombat', env)
-- The same far group XTarget must not count as combat or block Camp/Hunt/Pet idle work.
for _, mode in ipairs({ 'Hunt', 'Camp' }) do
    ctrl.submode = mode
    for _, cached in ipairs({ false, true }) do
        runtime.tickSerial = cached and (runtime.tickSerial or 0) + 1 or nil
        assert(not runtime.anyXtarAlive(true), mode .. ': distant shared XT blocked pull')
        assert(not env.isCombat(), mode .. ': shared native counters bypassed filter')
        assert(not runtime.hasDowntimeAggroThreat())
        assert(runtime.findFirstNPCXtarget(false, ignored, env.isUnreachable) == nil)
    end
end
-- Execute the actual pet adapter, rather than a copy of its eligibility condition.
local adapter = assert(source:match('hostileXT = (function%(%)\n.-\n        end),'))
local petXT = compile('return ' .. adapter, env)
assert(#petXT() == 0)
runtime.petCamp = { batch = { [2] = true } }
runtime.tickSerial = nil
assert(runtime.anyXtarAlive(true) and #petXT() == 1, 'own pet batch lost after aggro handoff')
runtime.petCamp = { tag = { id = 2 } }
assert(#petXT() == 1, 'tagged pet pull cannot confirm XTarget')
runtime.petCamp = nil; runtime.pullTargetId = 2; runtime.pullState = 'TO_CAMP'
assert(runtime.anyXtarAlive(true), 'own returning pull lost')
runtime.pullTargetId = 0; runtime.pullState = 'IDLE'
for _, owner in ipairs({ 100, 101 }) do
    mobs[2].owner = owner
    assert(runtime.anyXtarAlive(true) and #petXT() == 1, 'direct player/pet threat hidden')
end
mobs[2].owner = nil; mobs[2].distance = 150; mobs[2].unreachable = true
assert(runtime.anyXtarAlive(true), 'unreachable nearby threat must block fresh pulls')
assert(not runtime.anyXtarAlive(false))
mobs[2].unreachable = nil; mobs[2].distance = 151
assert(not runtime.anyXtarAlive(true))
mobs[2].distanceError = true
assert(runtime.anyXtarAlive(true), 'failed native read must retain threat')
mobs[2].distanceError = nil; mobs[2].distance = 900
ctrl.ignore_distant_xtargets = false
assert(runtime.anyXtarAlive(true) and env.isCombat() and #petXT() == 1, 'disabled option changed behavior')
ctrl.ignore_distant_xtargets = true; ctrl.mode = 'Assist'
assert(runtime.anyXtarAlive(true) and env.isCombat(), 'Assist policy changed')
ctrl.mode = 'Manual'
assert(not runtime.anyXtarAlive(true) and not env.isCombat(), 'Manual range policy changed')
ctrl.mode = 'Puller'; ctrl.submode = 'Hunt'; slots = { 1, 3 }; state.current = 1; mobs[3].owner = 100
assert(not runtime.checkAggroSwitch() and state.current == 1 and state.changed == 0, 'new attacker stole valid current fight')
slots = { 3 }; mobs[1].engaged = true
assert(not runtime.checkAggroSwitch(), 'engaged non-XTarget fight was stolen')
mobs[1].dead = true
assert(runtime.checkAggroSwitch() and state.current == 3, 'dead target did not release')
mobs[1].dead = nil; state.current = 1; mobs[1].engaged = nil
runtime.lastAggroSwitchAt = -100
assert(runtime.checkAggroSwitch(), 'unengaged travel no longer uses aggro/closer rule')
state.current = 1; slots = { 1, 3 }; mobs[1].unreachable = true
runtime.lastAggroSwitchAt = -100
assert(runtime.checkAggroSwitch(), 'unreachable target did not release')
mobs[1].unreachable = nil; state.current = 1; state.ignored = 1
runtime.lastAggroSwitchAt = -100
assert(runtime.checkAggroSwitch(), 'ignored target did not release')
state.ignored = nil; state.current = 1; state.force = 1
runtime.lastAggroSwitchAt = -100
assert(not runtime.checkAggroSwitch(), 'forced target was overridden')
assert(source:find('if curId ~= xtarId and not runtime.keepCurrentCombatTarget(curId) then', 1, true))
assert(not source:find('not anyXtarAlive(true) or ctrl.ignore_distant_xtargets == true', 1, true))
print('PASS: current fight retention; shared distant XTargets across Hunt/Camp/pet; native counter consistency; own/local threat safety')
