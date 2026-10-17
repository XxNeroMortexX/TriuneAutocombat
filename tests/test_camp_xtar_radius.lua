-- Created By: NeroMorte - Camp uses one fixed circle for XTargets, movement and fresh scans.
local f = assert(io.open('TAC/lua/triune.lua')); local source = f:read('*a'); f:close()
local function helper(name)
    return assert(source:match('(function runtime%.' .. name .. '.-\nend)'), name)
end
local function compile(code, env)
    if _VERSION == 'Lua 5.1' then local fn = assert(loadstring(code)); setfenv(fn, env); return fn() end
    return assert(load(code, 'actualCampCircle', 't', env))()
end
local ctrl = { mode = 'Puller', submode = 'Camp', camp_loc = { x = 0, y = 0 }, camp_radius = 100,
    xtar_nav_dist = 42, ignore_distant_xtargets = false, use_waypoints = false }
local mx, my, stopped, queryRadius = 100, 0, 0, nil
local mobs = { [1] = { x = -100, hp = 40 }, [2] = { x = 99, hp = 60 },
    [3] = { x = 101, hp = 1 }, [4] = { x = 0, z = 100, hp = 10 } }
local slots = { 1, 2, 3, 4 }
local function spawn(id)
    local m = mobs[id]
    return setmetatable({ ID = function() return m and id or 0 end,
        X = function() return m and m.x end, Y = function() return 0 end, Z = function() return m and (m.z or 0) end,
        CleanName = function() return 'mob' .. tostring(id) end,
        Type = function() return 'NPC' end, Dead = function() return false end, State = function() return 'STANDING' end,
        Level = function() return 65 end, PctHPs = function() return m.hp end,
        Distance3D = function() return m and math.sqrt((m.x - mx)^2 + my^2 + (m.z or 0)^2) end,
        Distance = function() return m and math.abs(m.x - mx) end,
    }, { __call = function() return m ~= nil end })
end
local runtime = { pullState = 'IDLE', wpNode = function() end, huntAnchor = function() end,
    petCampActive = function() return false end, isPlayerOffMesh = function() return false end,
    boxnetClaimedTargets = function() return {} end, isBoxClaimedTarget = function() return false end,
    isPullAllowed = function() return true end, isConAllowed = function() return true end,
    verifyTargetCon = function() return true end, isCoordInActiveHazard = function() return false end,
    noteMeshPathOk = function() end,
}
local mq = { TLO = { Spawn = spawn, Me = {
    X = function() return mx end, Y = function() return my end, Z = function() return 0 end,
    XTargetSlots = function() return #slots end, XTarget = function(i) return spawn(slots[i]) end,
}, NearestSpawn = function(index, query)
    queryRadius = tonumber(query:match('radius (%d+)'))
    local list = {}
    for _, id in ipairs(slots) do
        if math.abs(mobs[id].x - mx) <= queryRadius then list[#list + 1] = id end
    end
    return spawn(list[index])
end } }
local env = setmetatable({ runtime = runtime, ctrl = ctrl, mq = mq, pursuit = {},
    isHostileTarget = function(id) return mobs[id] ~= nil end, isUnreachable = function() return false end,
    isIgnored = function() return false end, xtSlotFightingMe = function() return false end,
    navLoaded = function() return false end, stopMoving = function() stopped = stopped + 1 end,
    distToId = function(id) return spawn(id).Distance3D() end,
}, { __index = _G })
compile(helper('huntXtarMaxDist') .. '\n' .. helper('campXtargetInRadius') .. '\n' .. helper('ownsPullXtarget'), env)
env.xtSlotCounts = compile(assert(source:match('(local function xtSlotCounts.-\nend)')) .. '\nreturn xtSlotCounts', env)
compile(helper('findFirstNPCXtarget') .. '\n' .. helper('xtSnapshot') .. '\n' .. helper('findRoamTarget'), env)
assert(runtime.campXtargetInRadius(1) == true and runtime.campXtargetInRadius(3) == false)
assert(env.xtSlotCounts(spawn(1), 1), 'inside opposite edge blocked by saved 42-unit chase setting')
assert(not env.xtSlotCounts(spawn(3), 3), 'outside camp mob counted despite being one unit from toon')
assert(runtime.findFirstNPCXtarget(false, env.isIgnored, env.isUnreachable, 42, 75) == 1,
    'picker must choose lowest eligible HP anywhere inside circle')
runtime.tickSerial = 1
local rows = runtime.xtSnapshot().byId
assert(rows[1].hostile and rows[2].hostile and not rows[3].hostile)
-- Query must cover the entire circle from the player position, not an intersecting player-centered radius.
slots = { 1, 3 }; assert(runtime.findRoamTarget(100, 75, 1, 100, nil, true) == 1)
assert(queryRadius == 200, 'fresh scanner missed opposite side of Camp circle')
-- Execute the actual movement chase guard, stopping before unrelated Nav logic.
local start = assert(source:find('function runtime.moveToward(id, dist, followOnly)', 1, true))
local finish = assert(source:find('    runtime.checkProactiveDoorAndLev()', start, true))
local prefix = source:sub(start, finish - 1)
compile(prefix .. "    return 'continue'\nend", env)
env.isXTargetId = function() return true end
assert(runtime.moveToward(1, 15) == 'continue' and stopped == 0)
mx = -100
assert(runtime.moveToward(3, 15) == false and stopped == 1, 'outside circle bypassed movement guard')
-- Live radius changes affect selectors/guards without copying them into Hunt's saved limit.
ctrl.camp_radius = 99
assert(runtime.findFirstNPCXtarget(false, nil, nil, 42, 75) == nil)
ctrl.camp_radius = 10000; mobs[1].x = -10000; mx = 10000; slots = { 1 }
assert(runtime.findFirstNPCXtarget(false, nil, nil, 42, 75) == 1)
assert(runtime.moveToward(1, 15) == 'continue')
assert(ctrl.xtar_nav_dist == 42, 'Camp overwrote Hunt/Manual chase preference')
ctrl.submode = 'Hunt'
assert(runtime.findFirstNPCXtarget(false, nil, nil, 42, 75) == nil, 'Hunt lost separate chase limit')
-- Execute the actual contextual UI prefix with widget counters.
local beginUI = assert(source:find("        if ctrl.submode == 'Camp' then\n            -- Edited By: NeroMorte - Explain the shared Camp boundary", 1, true))
local endUI = assert(source:find("            accent(ARC, 'Puller (Hunt)')", beginUI, true))
local widgets = 0
env.UI = { px = function(v) return v end }
env.ImGui = { TextDisabled = function() end, SetNextItemWidth = function() end,
    SliderInt = function(_, v) widgets = widgets + 1; return v end,
    Checkbox = function(_, v) return v end, IsItemHovered = function() return false end }
local draw = compile('return function()\n' .. source:sub(beginUI, endUI - 1) .. '\nend\nend', env)
ctrl.submode = 'Camp'; draw(); assert(widgets == 0)
ctrl.submode = 'Hunt'; draw(); assert(widgets == 1)
-- Edited By: NeroMorte - Catch the separate legacy Camp slider, not only the shared prefix.
assert(not source:find('Max XTarget Chase Range##pullerCampXtar', 1, true))
for _, id in ipairs({ 'manualXtarDist', 'pullerHuntXtar', 'assistXtarDist' }) do
    assert(source:find('Max XTarget Chase Range##' .. id, 1, true), id .. ' slider removed')
end
print('PASS: fixed Camp circle, opposite edge, outside-but-close exclusion, whole-circle scan, movement, large/live radii and Hunt-only slider')
