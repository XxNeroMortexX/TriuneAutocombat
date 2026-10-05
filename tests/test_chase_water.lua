-- Created By: NeroMorte - Execute real player-follow routing against vertical Chase regressions.
local file = assert(io.open('TAC/lua/triune.lua', 'r'))
local source = file:read('*a'); file:close()
local start = assert(source:find('function runtime.followGeometry(id)', 1, true))
local finish = assert(source:find('\nfunction runtime.moveToward(', start, true))
local runtime, pursuit, ctrl = {}, { NAV_CONST = { LOS_TRUST_RANGE = 5 } }, { nav_fallback_stick = true }
local leader = { x = 0, y = 0, z = -80 }
local me = { x = 0, y = 0, z = 0, wet = false, lev = false }
local nav, stick = { active = false, path = true, loaded = true }, { active = false }
local los, haveStick, commands = true, true, {}
local function spawn(data)
    return setmetatable({ X = function() return data.x end, Y = function() return data.y end,
        Z = function() return data.z end,
        Distance3D = function()
            return math.sqrt((data.x - me.x)^2 + (data.y - me.y)^2 + (data.z - me.z)^2)
        end, Underwater = function() return data.wet end,
        Levitating = function() return data.lev end, Moving = function() return false end },
        { __call = function() return true end })
end
local mq = { TLO = { Me = spawn(me), Spawn = function() return spawn(leader) end,
    Navigation = { Active = function() return nav.active end, MeshLoaded = function() return nav.loaded end,
        PathExists = function() return function() return nav.path end end },
    Stick = { Active = function() return stick.active end, Status = function() return stick.active and 'ON' or 'OFF' end } } }
function mq.cmd(command)
    commands[#commands + 1] = command
    if command == '/nav stop' then nav.active = false end
    if command == '/stick off' then stick.active = false end
    if command:find('^/nav id') then nav.active = true end
    if command:find('^/stick id') then stick.active = true end
end
function mq.cmdf(fmt, ...) mq.cmd(string.format(fmt, ...)) end
runtime.checkProactiveDoorAndLev = function() end
runtime.tryOffMeshRecovery = function() commands[#commands + 1] = 'recovery' end
local stops = 0
local function stopMoving()
    stops = stops + 1; nav.active = false; stick.active = false; pursuit.lastNavTargetId = 0
end
local env = setmetatable({ runtime = runtime, pursuit = pursuit, ctrl = ctrl, mq = mq,
    stopMoving = stopMoving, hasLoS = function() return los end,
    navLoaded = function() return true end, stickLoaded = function() return haveStick end }, { __index = _G })
local chunk = assert(loadstring(source:sub(start, finish - 1)))
setfenv(chunk, env); chunk()
local function last() return commands[#commands] end
-- Directly above leader on land: XY=0 must not report arrival or stop the route.
assert(runtime.followPlayer(99, 15) == false and last() == '/nav id 99 distance=15')
assert(stops == 0)
-- Follower enters water: hand Nav to UW without changing the selected target.
me.wet = true
local reached, pitch = runtime.followPlayer(99, 1)
assert(not reached and pitch and last() == '/stick id 99 1 uw' and not nav.active)
local count = #commands; runtime.followPlayer(99, 1); assert(#commands == count)
-- Near-Z gap at 1.5 units still needs UW at a one-unit setting.
leader.z = -1.5; assert(runtime.followPlayer(99, 1) == false and stick.active)
leader.z = -0.5; assert(runtime.followPlayer(99, 1) == true and not stick.active)
-- Reverse direction and levitation both retain vertical steering.
leader.z = 80; assert(runtime.followPlayer(99, 0) == false and last() == '/stick id 99 1 uw')
me.wet = false; me.lev = true; assert(select(2, runtime.followPlayer(99, 0)) == true)
-- Blocked LoS and distant horizontal separation return to mesh routing, never direct UW.
los = false; assert(runtime.followPlayer(99, 0) == false and last() == '/nav id 99 distance=0')
assert(not stick.active)
los = true; leader.x = 100; runtime.followPlayer(99, 1); assert(last() == '/nav id 99 distance=1')
-- A changed distance must refresh even an active Nav command.
runtime.followPlayer(99, 7); assert(last() == '/nav id 99 distance=7')
-- No MoveUtils: keep Nav available; do not claim vertical arrival.
haveStick = false; leader.x = 0; runtime.followPlayer(99, 1); assert(last() == '/nav id 99 distance=1')
-- Missing XYZ fails closed instead of treating missing Z as matching the leader.
me.z = nil; local before = stops; assert(runtime.followPlayer(99, 1) == false and stops == before + 1)
-- Chase must not issue NPC-facing commands while a vertical driver owns pitch.
local chaseStart = assert(source:find('function runtime.chaseMA()', 1, true))
local chaseEnd = assert(source:find('\n-- Assist/Tank', chaseStart, true))
local faced = false
runtime.maPcId = function() return 99 end
runtime.moveToward = function() return false, true end
ctrl.chase = true
mq.TLO.Target = setmetatable({ Type = function() return 'NPC' end }, { __call = function() return true end })
local oldcmd = mq.cmd; mq.cmd = function() faced = true end
chunk = assert(loadstring(source:sub(chaseStart, chaseEnd - 1))); setfenv(chunk, env); chunk()
runtime.chaseMA(); assert(not faced)
runtime.moveToward = function() return false, false end
runtime.chaseMA(); assert(faced); mq.cmd = oldcmd
assert(source:find("ctrl.chase_dist or 15, 0, 100", 1, true))
assert(source:find('ctrl.chase_dist = math.max(0, math.min(100, math.floor(val)))', 1, true))
-- Execute the actual mob movement function and shared XYZ range helper too.
local dStart = assert(source:find('local function distToId(id)', 1, true))
local dEnd = assert(source:find('\nlocal function distToLoc', dStart, true))
chunk = assert(loadstring(source:sub(dStart, dEnd - 1) .. '\nreturn distToId'))
setfenv(chunk, env); env.distToId = chunk()
local mStart = assert(source:find('function runtime.moveToward(id, dist, followOnly)', 1, true))
local mEnd = assert(source:find('\n-- ============================================================================', mStart, true))
chunk = assert(loadstring(source:sub(mStart, mEnd - 1))); setfenv(chunk, env); chunk()
runtime.petCampActive = function() return false end
local leashed = false
runtime.anchorLeashed = function() return leashed end
runtime.setTarget = function() error('unexpected target switch') end
runtime.markUnreachable = function() error('unexpected unreachable mark') end
env.isXTargetId = function() return false end
env.isClimbingLadder = function() return false end
env.desiredRange = function() return 15 end
env.clearTarget = function() error('unexpected clear target') end
pursuit.NAV_CONST.PURSUIT_STALL_TIMEOUT = 20
pursuit.NAV_CONST.LOS_FLICKER_GRACE = 0.5
mq.TLO.Target.ID = function() return 99 end
me.z, me.wet, me.lev = 0, true, false
leader.x, leader.z = 0, -80
haveStick, los = true, true
pursuit.lastNavTargetId, pursuit.id = 0, 0
assert(env.distToId(99) == 80)
assert(runtime.moveToward(99, 1, false) == false and last() == '/stick id 99 1 uw')
-- Existing anchor permission must be respected before any UW approach.
leashed = true; leader.z = -60; pursuit.lastNavTargetId = 0
count = #commands; assert(runtime.moveToward(99, 1, false) == false)
for i = count + 1, #commands do assert(not commands[i]:find('^/stick id')) end
leashed = false
-- XYZ arrival honors the configured distance, with no extra three-unit allowance.
leader.z = 0; leader.x = 6; me.wet = false; nav.active = false
assert(runtime.moveToward(99, 5, false) == false and last() == '/nav id 99 distance=5')
leader.x = 4; assert(runtime.moveToward(99, 5, false) == true)
-- Combat Nav must refresh if the GUI range changes while already navigating.
leader.x = 50
runtime.moveToward(99, 5, false); assert(last() == '/nav id 99 distance=5')
runtime.moveToward(99, 9, false); assert(last() == '/nav id 99 distance=9')
local rangeStart = assert(source:find('local function meleeDesiredRange(_)', 1, true))
local rangeEnd = assert(source:find('\nruntime.meleeDesiredRange', rangeStart, true))
chunk = assert(loadstring(source:sub(rangeStart, rangeEnd - 1) .. '\nreturn meleeDesiredRange'))
setfenv(chunk, env); local meleeRange = chunk()
ctrl.melee_dist = 1; assert(meleeRange(99) == 1)
ctrl.melee_dist = 30; assert(meleeRange(99) == 30)
-- Actual stuck detector: purely vertical motion must not invoke ground recovery.
local stuckStart = assert(source:find('function runtime.checkStuck()', 1, true))
local stuckEnd = assert(source:find('\n-- ============================================================================', stuckStart, true))
chunk = assert(loadstring(source:sub(stuckStart, stuckEnd - 1))); setfenv(chunk, env); chunk()
local stuck = { checkAt = -100, counter = 0, lastX = 0, lastY = 0, lastZ = 0 }
env.stuckState = stuck
pursuit.meshIso = { active = false }
env.isMoveActive = function() return true end
env.isCasting = function() return false end
for _, key in ipairs({ 'Sitting', 'Ducking', 'Stunned', 'Rooted' }) do mq.TLO.Me[key] = function() return false end end
mq.TLO.Target.Dead = function() return false end
local recovered = 0
runtime.performUnstuck = function() recovered = recovered + 1 end
runtime.tryOpenNearbyDoor = function() return false end
leader.x, leader.z = 0, -200
me.x, me.y, me.z = 0, 0, 0
for _ = 1, 5 do
    me.z = me.z - 3; stuck.checkAt = -100
    runtime.checkStuck(); assert(stuck.counter == 0)
end
assert(recovered == 0)
for _ = 1, 4 do stuck.checkAt = -100; runtime.checkStuck() end
assert(recovered > 0) -- A stationary failed approach must still trigger recovery.
print('PASS: XYZ Chase arrival, zero range, UW down/up/levitation, steering ownership, LoS/distance handoff missing-coordinate safety, mob UW, anchor permission and exact configured arrival')
