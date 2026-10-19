-- Created By: NeroMorte - Exercise main's oversized-target arrival and MA retry policy.
local f = assert(io.open('TAC/lua/triune.lua')); local source = f:read('*a'); f:close()
local function compile(code, env)
    local fn = assert(loadstring(code)); setfenv(fn, env); return fn()
end
local function helper(name)
    return assert(source:match('(function runtime%.' .. name .. '.-\nend)'))
end
local ctrl = { mode='Assist', submode='Chase', combat_style='Melee', melee_dist=12,
    ranged_dist=10, xtar_nav_dist=300, nav_hazard_avoidance=false }
local state = { distance=14.2, reach=58.8, los=true, target=80, time=100,
    unreachable=false, feed={id=80,engaged=true}, selects=0, clears=0 }
local spawn = setmetatable({ MaxRangeTo=function() return state.reach end,
    MaxMeleeTo=function() return state.reach end, ID=function() return 80 end,
    CleanName=function() return 'Saryrn' end, Type=function() return 'NPC' end,
    Dead=function() return false end }, {__call=function() return true end})
local target = setmetatable({ID=function() return state.target end, Type=spawn.Type,
    Dead=spawn.Dead, CleanName=spawn.CleanName}, {__call=function() return true end})
local runtime, pursuit = {}, { NAV_CONST={MELEE_RANGE=14,LOS_TRUST_RANGE=8,LOS_FLICKER_GRACE=2.5,PURSUIT_STALL_TIMEOUT=8},
    id=80,bestDist=14.2,improvedAt=90,navStalls=0,lastLoSAt=99 }
local mq={TLO={Spawn=function() return spawn end, Target=target, Me=setmetatable({}, {__call=function() return true end})},
    cmd=function() end}
local env=setmetatable({runtime=runtime,pursuit=pursuit,ctrl=ctrl,mq=mq,
    os={clock=function() return state.time end},
    distToId=function() return state.distance end, hasLoS=function() return state.los end,
    isXTargetId=function() return false end, isClimbingLadder=function() return false end,
    stopMoving=function() runtime.approachActive=false;pursuit.id=0 end,
    clearTarget=function() state.clears=state.clears+1 end,
    isSpawnPetOrPlayer=function() return false end, isHostileTarget=function() return true end,
    isUnreachable=function() return state.unreachable end,
    navLoaded=function() return false end, print=function() end }, {__index=_G})
local a=assert(source:find('local function maxMeleeDistance(id)',1,true))
local b=assert(source:find('\nruntime.styleReach = styleReach',a,true))
local ranges=compile(source:sub(a,b-1)..'\nreturn {desiredRange=desiredRange,styleReach=styleReach}',env)
runtime.styleReach=ranges.styleReach
-- The local range functions stay in their lexical chunk; expose them to the real mover.
env.desiredRange=runtime.desiredRange;env.styleReach=runtime.styleReach
runtime.petCampActive=function() return false end
runtime.checkProactiveDoorAndLev=function() end
runtime.anchorLeashed=function() return false end
runtime.followGeometry=function() return {distance=state.distance,horizontal=8.6,vertical=11.3} end
runtime.navCompletionDriver=function() return {arrived=function() return false end} end
runtime.markUnreachable=function() state.unreachable=true end
runtime.setTarget=function(id) state.target=id;state.selects=state.selects+1 end
compile(helper('huntXtarMaxDist') .. '\n' .. helper('moveToward'),env)
assert(runtime.desiredRange(80)==runtime.styleReach(80),'oversized melee approach disagrees with attack reach')
assert(runtime.moveToward(80,runtime.desiredRange(80)), 'visible oversized target was not accepted at weapon reach')
assert(not state.unreachable and state.clears==0,'already-reachable target was abandoned after 8 seconds')
assert(not runtime.approachActive,'completed approach retained movement ownership')
-- Ordinary mobs still honor the slider; Ranged keeps its own selected distance.
state.reach=14;assert(runtime.desiredRange(80)==12)
ctrl.melee_dist=1;assert(runtime.desiredRange(80)==1)
ctrl.melee_dist=30;assert(runtime.desiredRange(80)==30)
ctrl.combat_style='Ranged';state.reach=58.8;assert(runtime.desiredRange(80)==10 and runtime.styleReach(80)==10)
-- An actual failed approach stays failed; the new range policy must not waive LOS.
ctrl.combat_style='Melee';ctrl.melee_dist=12;state.distance=20;state.los=false
pursuit.id=80;pursuit.bestDist=14;pursuit.improvedAt=90;pursuit.lastLoSAt=90
assert(not runtime.moveToward(80,runtime.desiredRange(80)))
assert(state.unreachable and state.clears==1,'blocked target bypassed the stall timeout')
-- Main Assist must honor the same cooldown in both Box Net and legacy /assist paths.
runtime.maPcId=function() return 71 end
runtime.boxnetMaTarget=function() return state.feed end
runtime.targetIsEngaged=function() return true end
runtime.anyNearbyEngagedNpc=function() return true end
runtime.lastAssistCmdAt=99.5
-- Edited By: NeroMorte - Legacy replies are accepted only after acknowledgement.
mq.cmdf=function() end
mq.TLO.Me.AssistComplete=function() return true end
compile(helper('legacyMaTarget'),env)
compile(helper('maTargetId'),env)
state.los=true;state.unreachable=true;state.feed={id=80,engaged=true}
assert(runtime.maTargetId()==nil,'Box Net immediately reacquired an unreachable MA target')
state.feed=nil
assert(runtime.maTargetId()==nil,'legacy /assist immediately reacquired an unreachable target')
state.unreachable=false
assert(runtime.maTargetId()==80,'expired cooldown did not allow the MA target again')
print('PASS: oversized melee arrival, strict ranged/ordinary ranges, blocked-target stall, MA cooldown/feed/fallback')

-- The deployed Manual gate already honors its toggle; preserve that behavior.
local gate=assert(source:match("(    if not runtime%.petCampActive%(%) and %(%(ctrl%.mode == 'Manual'.-\n        checkAggroSwitch%(%)\n    end)"))
local switches=0;env.checkAggroSwitch=function() switches=switches+1 end
local tickGate=compile('return function() '..gate..' end',env)
ctrl.mode='Manual';ctrl.manual_auto_xtarget=false;tickGate();assert(switches==0)
ctrl.manual_auto_xtarget=true;tickGate();assert(switches==1)
ctrl.mode='Assist';tickGate();assert(switches==1)
print('PASS: deployed Manual auto-XTarget toggle still controls aggro switching')
