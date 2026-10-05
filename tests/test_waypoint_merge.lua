-- Edited By: NeroMorte - Exercise upstream waypoint anchors in the merged fork.
local file = assert(io.open('TAC/lua/triune.lua')); local source = file:read('*a'); file:close()
local reached, stops = false, 0
local ctrl = { running = true, mode = 'Puller', submode = 'Hunt', use_waypoints = true,
    waypoint_anchors = false, waypoint_loop = true, current_waypoint_idx = 1,
    waypoints = { { kind = 'Travel', x = 10, y = 20, z = 0 },
        { kind = 'Hunt', x = 30, y = 40, z = 0, combat_radius = 80, wait_seconds = 5, roam = false } } }
local runtime = { wpNormalize = function(node) return node end,
    moveTowardLoc = function() return reached end, anchorReturnTick = function() return false end,
    anchorRoamTick = function() error('Roam is disabled') end }
local env = setmetatable({ ctrl = ctrl, runtime = runtime, pursuit = {},
    stopMoving = function() stops = stops + 1 end }, { __index = _G })
for _, name in ipairs({ 'wpAnchorActive', 'wpNode', 'wpReset', 'wpState', 'wpAcquired', 'wpAdvance', 'wpAnchorTick', 'huntAnchor' }) do
    local body = assert(source:match('(function runtime%.'..name..'%b().-\nend)\n'))
    assert(load(body, name, 't', env))()
end
assert(not runtime.wpAnchorActive() and runtime.wpNode() == nil)
ctrl.waypoint_anchors = true
assert(runtime.wpNode() == ctrl.waypoints[1] and runtime.huntAnchor() == nil)
assert(runtime.wpAnchorTick(true) and ctrl.current_waypoint_idx == 1)
reached = true
assert(runtime.wpAnchorTick(true) and ctrl.current_waypoint_idx == 2)
local anchor, radius = runtime.huntAnchor()
assert(anchor == ctrl.waypoints[2] and radius == 80)
runtime.wpAnchorTick(false)
assert(runtime.wpState().phase == 'hunt')
runtime.wpAnchorTick(true)
assert(runtime.wpState().empty and runtime.wpState().elapsed == 0)
runtime.wpState().delta = 4; runtime.wpAnchorTick(true)
assert(ctrl.current_waypoint_idx == 2)
runtime.wpAcquired()
assert(not runtime.wpState().empty and runtime.wpState().elapsed == 0)
runtime.wpAnchorTick(true)
runtime.wpState().delta = 5; runtime.wpAnchorTick(true)
assert(ctrl.current_waypoint_idx == 1 and stops > 0)
ctrl.submode = 'Camp'
assert(not runtime.wpAnchorActive() and runtime.wpNode() == nil and runtime.huntAnchor() == nil)
print('PASS: waypoint anchors remain opt-in, Travel and Hunt nodes advance correctly, fights reset waits, Camp mode stays separate')
