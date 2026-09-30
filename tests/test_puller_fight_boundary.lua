-- Edited By: NeroMorte - Regression tests execute the original Puller paths against live-XTarget filters.
local file = assert(io.open('TAC/lua/triune.lua')); local source = file:read('*a'); file:close()
local xt, candidate, fresh, closer, stopped = true, nil, 0, 0, 0
local ctrl = { camp_loc = { x = 0, y = 0, z = 0 }, camp_radius = 500 }
local runtime = { pullState = 'IDLE', combatHold = function() return false end,
    anyXtarAlive = function(include) assert(include == true); return xt end,
    checkPullHpRest = function() return false end,
    findRoamTarget = function() fresh = fresh + 1 end, setTarget = function() return true end,
    boxnetYieldTarget = function() end,
    checkCloserTarget = function() closer = closer + 1 end }
local env = setmetatable({ ctrl = ctrl, runtime = runtime,
    mq = { TLO = { Me = { Combat = function() return false end },
        Target = setmetatable({}, { __call = function() return false end }) } },
    firstNPCXtarget = function() return candidate end,
    stopMoving = function() stopped = stopped + 1 end, isCasting = function() return false end,
    distToId = function() return 200 end }, { __index = _G })
local puller = assert(source:match('(function runtime%.pullerTick.-)\nfunction runtime%.playerHasAggro'))
assert(load(puller, 'normalCampPuller', 't', env))()
-- Height/unreachable filter returns nil although a live hostile XTarget remains.
runtime.pullerTick(); assert(fresh == 0 and stopped == 1)
xt = false; runtime.pullerTick(); assert(fresh == 1)
xt, candidate = true, 100; runtime.pullerTick(); assert(runtime.pullState == 'FIGHTING' and runtime.pullTargetId == 100)
-- Current pull already occupies XTargets: do not run the fresh closer-mob scan.
runtime.pullState, runtime.pullTargetId = 'TO_MOB', 100
local start = assert(source:find("    if runtime.pullState == 'TO_MOB' then", source:find('function runtime.pullerTick', 1, true), true))
local finish = assert(source:find('\n    -- IDLE accepts', start, true))
local travel = assert(load('return function() '..source:sub(start, finish - 1)..' end', 'normalCloserGate', 't', env))()
travel(); assert(closer == 0)
xt = false; travel(); assert(closer == 1)
-- Execute Hunt acquisition before its existing navigation/target branches.
start = assert(source:find('                local scanRadius = hasWps and (ctrl.waypoint_scan_radius or 100) or (ctrl.hunter_radius or 1500)', 1, true))
finish = assert(source:find('                if id and setTarget(id) then', start, true))
env.anyXtarAlive = runtime.anyXtarAlive; env.huntNPCXtarget = function() return candidate end
env.findRoamTarget = runtime.findRoamTarget
local hunt = assert(load('return function() '..source:sub(start, finish - 1)..' return id end', 'normalHuntGate', 't', env))()
xt, candidate, fresh = true, nil, 0; hunt(); assert(fresh == 0)
xt = false; hunt(); assert(fresh == 1)
xt, candidate = true, 101; assert(hunt() == 101 and fresh == 1)
-- Deliberate Ignore Distant XTargets retains Gennro's opt-in behavior.
candidate, ctrl.ignore_distant_xtargets = nil, true; hunt(); assert(fresh == 2)
print('PASS: ordinary Camp/Hunt finish XTargets, engaged closer-target lock, explicit Hunt ignore option preserved')
