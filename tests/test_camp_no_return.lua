-- Created By: NeroMorte - Ordinary Camp fights at the mob; only visible enabled pet return may recall.
local f = assert(io.open('TAC/lua/triune.lua')); local source = f:read('*a'); f:close()
local function compile(code, env)
    if _VERSION == 'Lua 5.1' then
        local fn = assert(loadstring(code)); setfenv(fn, env); return fn()
    end
    return assert(load(code, 'actualCampNoReturn', 't', env))()
end
local ctrl = { mode = 'Puller', submode = 'Camp', camp_loc = { x = 0, y = 0, z = 0 },
    pull_style = 'Melee', combat_style = 'Melee', pet_camp_enabled = false, pet_camp_pull_back = true }
local commands, locationMoves, tags, add = {}, 0, 0, nil
local targetId = 10
local target = setmetatable({ ID = function() return targetId end, CleanName = function() return 'mob' end },
    { __call = function() return true end })
local mq = { cmd = function(cmd) commands[#commands + 1] = cmd end,
    TLO = { Target = target, Me = { Combat = function() return false end,
        Pet = { ID = function() return 0 end } }, Pet = { Target = { ID = function() return 0 end } } } }
local runtime = { pullState = 'TO_MOB', pullTargetId = 10,
    combatHold = function() return false end, boxnetYieldTarget = function() end,
    verifyTargetCon = function() return true end, moveToward = function() return true end,
    moveTowardLoc = function() locationMoves = locationMoves + 1; return true end,
    recordBreadcrumb = function() end, clearBreadcrumbs = function() end,
    anyXtarAlive = function() return true end, playerHasAggro = function() return true end,
    rangedApproachDist = function(d) return d end, pullTagReach = function() return 100 end,
    meleeAttackOn = function() tags = tags + 1 end, finishRangedPullTag = function() end,
    castPullSpell = function() tags = tags + 1 end, engageRangedAttack = function() tags = tags + 1 end,
    setTarget = function(id) targetId = id; return true end,
}
local env = setmetatable({ ctrl = ctrl, runtime = runtime, mq = mq, pursuit = {}, petState = {},
    firstNPCXtarget = function() return add end, distToId = function() return 100 end,
    distToLoc = function() return 100 end, desiredRange = function() return 20 end,
    isHostileTarget = function() return true end, isXTargetId = function() return true end,
    isUnreachable = function() return false end, isCasting = function() return false end,
    hasActivePet = function() return false end, isSpawnAlive = function() return true end,
    stopMoving = function() end, print = function() end,
}, { __index = _G })
local body = assert(source:match('(function runtime%.pullerTick.-)\nfunction runtime%.playerHasAggro'))
compile(body, env)
for _, style in ipairs({ 'Melee', 'Ranged', 'Spell', 'Pet' }) do
    ctrl.pull_style = style
    runtime.pullState, runtime.pullTargetId = 'TO_MOB', 10
    runtime.pullerTick()
    assert(runtime.pullState == 'FIGHTING', style .. ' still enters return state')
    runtime.pullerTick()
    assert(locationMoves == 0, style .. ' navigated back to camp')
end
-- An incoming XTarget while approaching must fight at its location as well.
add = 20; runtime.pullState, runtime.pullTargetId = 'TO_MOB', 10
runtime.pullerTick()
assert(runtime.pullState == 'FIGHTING' and runtime.pullTargetId == 20 and locationMoves == 0)
-- A stale pre-change return state must be stopped without navigating home.
runtime.pullState = 'TO_CAMP'; runtime.pullerTick()
assert(runtime.pullState == 'FIGHTING' and locationMoves == 0)
-- The runtime pet controller must use exactly the same visibility prerequisites as Control.
compile(assert(source:match('(function runtime%.petCampActive.-\nend)')), env)
local pf = assert(io.open('TAC/lua/TAC_support_modules/pet_camp_controller.lua'))
local petSource = pf:read('*a'); pf:close()
env.Controller = {}
compile(assert(petSource:match('(function Controller:enabled%(%).-\nend)')), env)
runtime.petCamp = { enabled = env.Controller.enabled, api = { config = function() return ctrl end } }
ctrl.pull_style = 'Melee'; ctrl.pet_camp_enabled = true
assert(not runtime.petCampActive(), 'hidden checked pet return activated in Melee')
ctrl.pull_style = 'Pet'; ctrl.pet_camp_enabled = false
assert(not runtime.petCampActive(), 'hidden checked pet return activated without stationary pets')
ctrl.pet_camp_enabled = true; assert(runtime.petCampActive())
ctrl.submode = 'Hunt'; assert(not runtime.petCampActive())
assert(source:find("if ctrl.submode == 'Camp' and ctrl.pull_style == 'Pet' then", 1, true))
assert(source:find("if ctrl.pet_camp_enabled then", 1, true))
print('PASS: ordinary Camp never returns with Melee/Ranged/Spell/Pet; add and legacy states; hidden pet-return safety')
