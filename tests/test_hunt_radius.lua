-- Created By: NeroMorte - Execute actual Hunt boundary scans and idle movement after radius edits.
local f = assert(io.open('TAC/lua/triune.lua', 'r'))
local source = f:read('*a'); f:close()
local function helper(name)
    return assert(source:match('(function runtime%.' .. name .. '.-\nend)'))
end
local ctrl = { mode = 'Puller', submode = 'Hunt', hunter_combat_loc = { x = 0, y = 0, z = 0 },
    hunter_combat_radius = 100, hunter_anchor_roam = true }
local runtime = { wpNode = function() end, wpAnchorActive = function() return false end,
    ANCHOR_ROAM = { ARRIVE_DIST = 10, LEG_MAX_SECS = 40, PAUSE_SECS = 5 },
    petCampActive = function() return false end, isPlayerOffMesh = function() return false end,
    boxnetClaimedTargets = function() return {} end, isBoxClaimedTarget = function() return false end,
    isPullAllowed = function() return true end, isConAllowed = function() return true end,
    verifyTargetCon = function() return true end, isCoordInActiveHazard = function() return false end,
    noteMeshPathOk = function() end,
}
local pursuit, stopped, moved = {}, 0, 0
local mx, my, now = 90, 0, 1
local candidates = { { id = 1, x = 150 }, { id = 2, x = 10 } }
local mq = { TLO = { Me = { X = function() return mx end, Y = function() return my end,
    Z = function() return 0 end }, Navigation = { Active = function() return true end },
    NearestSpawn = function(index, query)
        local radius = tonumber(query:match('radius (%d+)'))
        local matches = {}
        for _, item in ipairs(candidates) do
            if math.abs(item.x - mx) <= radius then matches[#matches + 1] = item end
        end
        local item = matches[index]
        return setmetatable({ ID = function() return item.id end,
            CleanName = function() return 'NPC ' .. item.id end,
            X = function() return item.x end, Y = function() return 0 end, Z = function() return 0 end,
            Level = function() return 65 end, Dead = function() return false end,
            Type = function() return 'NPC' end, State = function() return 'STANDING' end,
        }, { __call = function() return item ~= nil end })
    end,
} }
local env = setmetatable({ ctrl = ctrl, runtime = runtime, pursuit = pursuit, mq = mq,
    os = { clock = function() return now end },
    navLoaded = function() return false end, isUnreachable = function() return false end,
    isHostileTarget = function() return true end,
    stopMoving = function() stopped = stopped + 1 end,
}, { __index = _G })
runtime.moveTowardLoc = function() moved = moved + 1 end
assert(load(helper('huntAnchor') .. '\n' .. helper('anchorDist') .. '\n' ..
    helper('anchorRoamTick') .. '\n' .. helper('findRoamTarget'), 'actualHuntRadius', 't', env))()
-- Nearest eligible spawn is outside the fixed anchor but inside the player-centered scan.
assert(runtime.findRoamTarget(1000, 75, 1, 100, nil, true) == 2)
ctrl.hunter_combat_radius = 9
assert(runtime.findRoamTarget(1000, 75, 1, 100, nil, true) == nil)
ctrl.hunter_combat_radius = 10
assert(runtime.findRoamTarget(1000, 75, 1, 100, nil, true) == 2) -- exact boundary accepted
-- A radius shrink must cancel a leg chosen inside the old 100-unit circle.
mx = 0; ctrl.hunter_combat_radius = 40
pursuit.wanderLoc = { x = 80, y = 0, z = 0, at = now }
assert(runtime.anchorRoamTick() == false)
assert(stopped == 1 and moved == 0 and pursuit.wanderLoc == nil)
-- An unchanged in-bounds leg continues normally.
pursuit.wanderLoc = { x = 30, y = 0, z = 0, at = now }
assert(runtime.anchorRoamTick() == true and moved == 1 and stopped == 1)
-- Changing anchor location invalidates the previous leg as well.
ctrl.hunter_combat_loc = { x = 200, y = 0, z = 0 }
assert(runtime.anchorRoamTick() == false and stopped == 2 and pursuit.wanderLoc == nil)
print('PASS: actual Hunt scan enforces fixed radius, accepts its boundary, and cancels old roam legs after shrink/anchor edits')
