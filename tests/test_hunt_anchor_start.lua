-- Created By: NeroMorte - Execute Hunt startup and native circle helpers.
local f = assert(io.open('TAC/lua/triune.lua')); local source = f:read('*a'); f:close()
local ctrl = { mode = 'Puller', submode = 'Hunt', hunter_combat_radius = 200 }
local commands, saved, messages = {}, 0, 0
local x, y, z = 10, 20, 30
local pursuit = { wanderLoc = { x = 99 } }
local runtime = { wpNode = function() end, saveZoneAnchor = function() saved = saved + 1 end }
local mq = { cmd = function(c) commands[#commands + 1] = c end, TLO = {
    Plugin = function() return setmetatable({ IsLoaded = function() return true end }, { __call = function() return 'mq2map' end }) end,
    Me = { X = function() return x end, Y = function() return y end,
        Z = function() return z end, CleanName = function() return 'Tester' end },
    Zone = { ShortName = function() return 'testzone' end },
} }
local env = setmetatable({ ctrl = ctrl, runtime = runtime, pursuit = pursuit, mq = mq,
    print = function() messages = messages + 1 end }, { __index = _G })
local function helper(name) return assert(source:match('(function runtime%.' .. name .. '.-\nend)')) end
assert(load(helper('eqCampMapLoaded') .. '\n' .. helper('clearEqCampMap') .. '\n' ..
    helper('updateEqCampMap') .. '\n' .. helper('refreshEqCampMapFromUI') .. '\n' ..
    helper('huntAnchor') .. '\n' .. helper('ensureHuntAnchor'), 'huntStart', 't', env))()
assert(runtime.ensureHuntAnchor())
assert(ctrl.hunter_combat_loc.x == 10 and saved == 1 and messages == 1 and not pursuit.wanderLoc)
assert(commands[#commands]:find('radius 200', 1, true))
x = 100
assert(not runtime.ensureHuntAnchor() and ctrl.hunter_combat_loc.x == 10) -- no moving anchor
ctrl.hunter_combat_loc = nil
assert(runtime.ensureHuntAnchor() and ctrl.hunter_combat_loc.x == 100) -- Clear then resume
ctrl.hunter_combat_radius = 750
runtime.refreshEqCampMapFromUI(true)
assert(commands[#commands]:find('radius 750', 1, true))
ctrl.hunter_combat_radius = 1200
runtime.refreshEqCampMapFromUI(true) -- same instant, next slider drag frame
assert(commands[#commands]:find('radius 1200', 1, true))
ctrl.hunter_combat_loc = nil; ctrl.use_waypoints = true; ctrl.waypoints = { { x = 5 } }
assert(not runtime.ensureHuntAnchor() and not ctrl.hunter_combat_loc)
ctrl.use_waypoints = false; ctrl.submode = 'Camp'
assert(not runtime.ensureHuntAnchor() and not ctrl.hunter_combat_loc)
ctrl.submode = 'Hunt'; x = nil
assert(not runtime.ensureHuntAnchor() and not ctrl.hunter_combat_loc)
x = 0; y = 0; z = 0; ctrl.hunter_combat_radius = 0
assert(runtime.ensureHuntAnchor() and ctrl.hunter_combat_radius == 250)
assert(source:match('function UI.startEngine%(%)%s.-ensureHuntAnchor'))
print('PASS: Hunt missing/cleared anchor, waypoint/Camp exclusions, invalid position and immediate radius redraw')
