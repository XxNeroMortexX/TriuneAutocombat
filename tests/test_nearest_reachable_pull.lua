-- Created By: NeroMorte - Execute the shared scanner against hills, floors, paths and close ties.
local f = assert(io.open('TAC/lua/triune.lua')); local source = f:read('*a'); f:close()
local function helper(name) return assert(source:match('(function runtime%.' .. name .. '.-\nend)')) end
local function compile(code, env)
    if _VERSION == 'Lua 5.1' then local fn = assert(loadstring(code)); setfenv(fn, env); return fn() end
    return assert(load(code, 'actualNearestPull', 't', env))()
end
local ctrl = { mode = 'Puller', submode = 'Hunt', hunter_z_plane = 15, hunter_z = 75,
    camp_z_plane = 15, camp_z = 75, camp_loc = { x = 0, y = 0 }, camp_radius = 500,
    nav_max_path_ratio = 2.5, combat_style = 'Melee' }
local mobs, slots, queries = {}, {}, {}
local function distance(m) return math.sqrt(m.x^2 + (m.z or 0)^2) end
local function spawn(id)
    local m = mobs[id]
    return setmetatable({ ID = function() return m and id or 0 end,
        X = function() return m.x end, Y = function() return 0 end, Z = function() return m.z or 0 end,
        Distance3D = function() return distance(m) end, CleanName = function() return 'mob' .. id end,
        Dead = function() return m.dead or false end, Type = function() return 'NPC' end,
        TargetOfTarget = { ID = function() return 0 end }, AggroHolder = { ID = function() return 0 end },
        State = function() return 'STANDING' end, Level = function() return m.level or 65 end,
    }, { __call = function() return m ~= nil end })
end
local function native(value) return function() return value end end
local runtime = { wpNode = function() end, petCampActive = function() return false end,
    targetIsEngaged = function() return false end, playerHasAggro = function() return false end,
    forcedTargetId = function() end, huntAnchor = function() end, isPlayerOffMesh = function() return false end,
    boxnetClaimedTargets = function() return {} end,
    isBoxClaimedTarget = function(id) return mobs[id].claimed or false end,
    isPullAllowed = function(name) return not mobs[tonumber(name:match('%d+'))].ignored end,
    isConAllowed = function() return true end, verifyTargetCon = function() return true end,
    isCoordInActiveHazard = function() return false end, noteMeshPathOk = function() end,
    noteMeshNoPath = function() return false end,
}
local mq = { TLO = { Spawn = spawn, Me = { X = function() return 0 end, Y = function() return 0 end,
    Z = function() return 0 end, Combat = function() return false end },
    NearestSpawn = function(index, query)
        if index == 1 then queries[#queries + 1] = query end
        local radius, height = tonumber(query:match('radius (%d+)')), tonumber(query:match('zradius (%d+)'))
        local candidates = {}
        for _, id in ipairs(slots) do
            local m = mobs[id]
            if math.abs(m.x) <= radius and math.abs(m.z or 0) <= height then candidates[#candidates + 1] = id end
        end
        -- Native enumeration can use planar ordering; ranking must use actual player-to-mob distance.
        table.sort(candidates, function(a, b) return math.abs(mobs[a].x) < math.abs(mobs[b].x) end)
        return spawn(candidates[index])
    end,
    Navigation = { MeshLoaded = function() return true end,
        PathExists = function(query)
            local m = mobs[tonumber(query:match('%d+'))]
            if m.pathError then error('native path failed') end
            return native(m.path ~= false)
        end,
        PathLength = function(query)
            local m = mobs[tonumber(query:match('%d+'))]
            return native(m.pathLength or distance(m))
        end,
    },
} }
local env = setmetatable({ ctrl = ctrl, runtime = runtime, mq = mq, pursuit = { MESH_ISO = { DIRECT_LOS_DIST = 40 } },
    navLoaded = function() return true end, desiredRange = function() return 14 end,
    hasLoS = function() return false end, isUnreachable = function(id) return mobs[id].unreachable end,
    isHostileTarget = function(id) return not mobs[id].dead end,
    distToId = function(id) return distance(mobs[id]) end,
    isCastingOrStarting = function() return false end, getActiveTargetRequiredCastingId = function() end,
    isSpawnMyPet = function() return false end,
}, { __index = _G })
compile(helper('findRoamTarget') .. '\n' .. helper('canReconsiderApproach') .. '\n' .. helper('checkCloserTarget'), env)
local function choose(height, excluded)
    runtime.pathExistsCache = {}; runtime.roamScanEmpty = nil; queries = {}
    return runtime.findRoamTarget(500, height or 75, 1, 100, excluded, true)
end
for _, submode in ipairs({ 'Camp', 'Hunt' }) do
    ctrl.submode = submode
    for _, z in ipairs({ 20, -20 }) do
        mobs = { [1] = { x = 30, z = z }, [2] = { x = 60, z = 0 } }; slots = { 1, 2 }
        assert(choose() == 1, submode .. ': nearby hill lost to far flat mob')
        assert(#queries == 1 and queries[1]:find('zradius 75', 1, true), 'still uses separate floor scan')
        assert(choose(15) == 2, 'height limit ignored')
        mobs[1].pathLength = 300; assert(choose() == 2, 'other-floor detour was accepted')
        mobs[1].pathLength = nil; mobs[1].path = false; assert(choose() == 2, 'no-path target chosen')
        mobs[1].path = nil; mobs[1].pathError = true; assert(choose() == 2, 'unknown path treated as reachable')
        mobs[1].pathError = nil
        mobs[1].ignored = true; assert(choose() == 2); mobs[1].ignored = nil
        mobs[1].claimed = true; assert(choose() == 2); mobs[1].claimed = nil
        mobs[1].level = 110; assert(choose() == 2); mobs[1].level = 65
        assert(choose(75, { [1] = true }) == 2, 'pet gather exclusion ignored')
    end
end
-- Similar elevation is a five-unit tie, never a broad preference over closer hills.
mobs = { [1] = { x = 15, z = 20 }, [2] = { x = 29, z = 0 } }; slots = { 1, 2 }
assert(choose() == 2) -- distance 25 vs 29: same floor breaks close tie
mobs[2].x = 31; assert(choose() == 1) -- more than five units farther: hill wins
-- Avoid planar-nearest picks that are actually much farther in 3D.
mobs = { [1] = { x = 5, z = 60 }, [2] = { x = 30, z = 0 } }; assert(choose() == 2)
-- Even a close mob can require a huge route to another floor.
mobs = { [1] = { x = 12, z = 9, pathLength = 500 }, [2] = { x = 60 } }; assert(choose() == 2)
-- Closer-target travel uses this same selector, without changing its combat/retarget gates.
mobs = { [1] = { x = 30, z = 20 }, [2] = { x = 60 }, [3] = { x = 100 } }; slots = { 1, 2 }
runtime.pathExistsCache = {}; runtime.roamScanEmpty = nil
assert(runtime.canReconsiderApproach(3), 'fixture approach is not eligible')
assert(runtime.checkCloserTarget(3, 500, 75, 1, 100) == 1)
print('PASS: actual shared fresh/closer scanner chooses nearest reachable hills, bounded floor ties, full height range, path safety and existing exclusions')
