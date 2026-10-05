-- Edited By: NeroMorte - Regression tests execute the original Puller paths against live-XTarget filters.
local file = assert(io.open('TAC/lua/triune.lua')); local source = file:read('*a'); file:close()
local xt, candidate, fresh, closer, stopped = true, nil, 0, 0, 0
local ctrl = { camp_loc = { x = 0, y = 0, z = 0 }, camp_radius = 500 }
local runtime = { wpAnchorActive = function() return false end, pullState = 'IDLE', combatHold = function() return false end,
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

-- Edited By: NeroMorte - Execute the merged scanner with pet exclusions and waypoint fresh scans.
do
    local active, node, scans = false, nil, 0
    local config = { mode = 'Puller', submode = 'Camp', camp_loc = { x = 0, y = 0 },
        camp_radius = 100, use_waypoints = true, waypoints = {{ x = 0, y = 0 }} }
    local candidates = {}
    local function spawn(id, x)
        return setmetatable({ ID = function() return id end, CleanName = function() return 'mob' end,
            Dead = function() return false end, Type = function() return 'NPC' end,
            State = function() return 'ACTIVE' end, X = function() return x end,
            Y = function() return 0 end, Z = function() return 0 end,
            Level = function() return 50 end }, { __call = function() return true end })
    end
    local absent = setmetatable({}, { __call = function() return false end })
    local rt = {
        wpNode = function() return node end, petCampActive = function() return active end,
        huntAnchor = function() return nil end, isPlayerOffMesh = function() return false end,
        boxnetClaimedTargets = function() return {} end, isBoxClaimedTarget = function() return false end,
        isPullAllowed = function() return true end, isConAllowed = function() return true end,
        verifyTargetCon = function() return true end, isCoordInActiveHazard = function() return false end,
        noteMeshPathOk = function() end,
    }
    local scannerEnv = setmetatable({ runtime = rt, ctrl = config, os = { clock = function() return 100 end },
        mq = { TLO = { NearestSpawn = function(i) scans = scans + 1; return candidates[i] or absent end,
            Me = { Z = function() return 0 end } } }, navLoaded = function() return false end,
        isUnreachable = function() return false end, isHostileTarget = function() return true end,
    }, { __index = _G })
    local body = assert(source:match('(function runtime%.findRoamTarget.-\nend)\n'))
    assert(load(body, 'mergedRoamScanner', 't', scannerEnv))()
    candidates = { spawn(1, 10), spawn(2, 20) }
    assert(rt.findRoamTarget(500, 75, 1, 100, { [1] = true }) == 2)
    candidates = {}; rt.roamScanEmpty = nil
    local id, complete = rt.findRoamTarget(500, 75, 1, 100)
    assert(id == nil and complete == true)
    local before = scans
    id, complete = rt.findRoamTarget(500, 75, 1, 100)
    assert(id == nil and complete == false and scans == before)
    id, complete = rt.findRoamTarget(500, 75, 1, 100, nil, true)
    assert(id == nil and complete == true and scans > before)
    candidates = { spawn(3, 200) }; rt.roamScanEmpty = nil; active = true
    assert(rt.findRoamTarget(100, 75, 1, 100) == nil) -- pet camp still enforces its boundary
    rt.roamScanEmpty = nil; active = false
    assert(rt.findRoamTarget(100, 75, 1, 100) == 3) -- legacy patrol bypass preserved
    node = { kind = 'Travel' }; before = scans
    id, complete = rt.findRoamTarget(100, 75, 1, 100, nil, true)
    assert(id == nil and complete == true and scans == before)
    print('PASS: merged scanner keeps pet exclusions, uncached waypoint scans, camp bounds and Travel-node policy')
end
