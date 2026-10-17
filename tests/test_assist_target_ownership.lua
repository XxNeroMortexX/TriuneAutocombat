-- Created By: NeroMorte - Execute the shipped target selectors and movement failure paths.
local f = assert(io.open((arg and arg[1]) or 'TAC/lua/triune.lua'))
local source = f:read('*a'); f:close()
local function compile(code, env)
    local fn = assert(loadstring(code)); setfenv(fn, env); return fn()
end
local function helper(name)
    return assert(source:match('(function runtime%.' .. name .. '.-\nend)'), name)
end
local S = { time=100, target=77, distance=40, los=true, feed=false, complete=false,
    blocked={}, commands={}, stops=0, clears=0, selected=0, reach=15, xt={99}, near={}, engaged=true }
local mobs = { [71]={type='PC'}, [77]={target=2,holder=2,aggro=1},
    [99]={target=2,holder=2,aggro=1}, [131]={target=71,holder=71,aggro=1} }
local function spawn(id)
    local data = mobs[id] or {}
    return setmetatable({ID=function() return id end, CleanName=function() return 'mob' .. id end,
        Type=function() return data.type or 'NPC' end, Dead=function() return data.dead or false end,
        State=function() return 'STANDING' end, TargetType=function() return 'Auto Hater' end,
        MaxRangeTo=function() return S.reach end, MaxMeleeTo=function() return S.reach end,
        TargetOfTarget={ID=function() if data.badTarget then error('unsupported') end return data.target or 0 end},
        AggroHolder={ID=function() return data.holder or 0 end}, PctAggro=function() return data.aggro or 0 end,
        Target={ID=function() return S.direct or 0 end},
    }, {__call=function() return mobs[id] and true or nil end})
end
local target = setmetatable({}, {__call=function() return S.target > 0 and true or nil end,
    __index=function(_, key) return spawn(S.target)[key] end})
local me = setmetatable({ID=function() return 1 end, Combat=function() return false end,
    CombatState=function() return 'RESTING' end, XTHaterCount=function() return 1 end,
    XTargetSlots=function() return #S.xt end, XTarget=function(i) return spawn(S.xt[i] or 0) end,
    AssistComplete=function() if S.unsupported then error('unsupported') end return S.complete end,
}, {__call=function() return true end})
local ctrl={mode='Assist',submode='Chase',assist_self_defense=true,xtar_nav_dist=300,
    combat_style='Melee',melee_dist=15,nav_hazard_avoidance=false,manual_auto_xtarget=true,manual_stick=true}
local runtime = {maPcId=function() return 71 end,boxnetMaTarget=function() return S.feed end,
    targetIsEngaged=function() return S.engaged end,petCampActive=function() return false end,
    checkProactiveDoorAndLev=function() end,anchorLeashed=function() return false end,
    followGeometry=function() return {distance=S.distance,horizontal=10,vertical=75} end,
    navCompletionDriver=function() return {arrived=function() return false end} end,
    markUnreachable=function(id) S.blocked[id]=true end,
    setTarget=function(id) S.target=id;S.selected=S.selected+1 end}
local pursuit={NAV_CONST={MELEE_RANGE=14,LOS_TRUST_RANGE=8,LOS_FLICKER_GRACE=2.5,PURSUIT_STALL_TIMEOUT=8}}
local mq={TLO={Me=me,Target=target,Spawn=spawn,SpawnCount=function() return function() return #S.near end end,
    NearestSpawn=function(i) return spawn(S.near[i]) end},
    cmd=function(c) S.commands[#S.commands+1]=c end,
    cmdf=function(fmt,...) S.commands[#S.commands+1]=string.format(fmt,...) end}
local env=setmetatable({runtime=runtime,ctrl=ctrl,pursuit=pursuit,mq=mq,os={clock=function() return S.time end},
    isUnreachable=function(id) return S.blocked[id] end,
    isGroupOrRaidMember=function(id) return id==71 end,isSpawnPetOrPlayer=function(id) return id==71 end,
    isHostileTarget=function(id) return mobs[id] and id~=71 and not mobs[id].dead end,
    isIgnored=function() return false end,distToId=function() return S.distance end,
    hasLoS=function() return S.los end,baseTok=function(token) return token end,
    isXTargetId=function() return true end,isClimbingLadder=function() return false end,
    stopMoving=function() S.stops=S.stops+1;runtime.approachActive=false;pursuit.id=0 end,
    clearTarget=function() S.clears=S.clears+1;S.target=0 end,navLoaded=function() return false end,
    print=function() end}, {__index=_G})
if source:find('function runtime.isDirectAttacker',1,true) then compile(helper('isDirectAttacker'),env) end
compile(helper('findSelfDefenseTarget'),env)
-- Auto Hater and partial aggro must not authorize attacking another player's mob.
assert(runtime.findSelfDefenseTarget()==nil,'Auto Hater attacking another player was treated as self-defense')
mobs[99].aggro=100
assert(runtime.findSelfDefenseTarget()==nil,'100% aggro overrode a known different target/holder')
mobs[99].holder=1
assert(runtime.findSelfDefenseTarget()==99,'direct aggro holder was not defended')
mobs[99].badTarget=true
assert(runtime.findSelfDefenseTarget()==99,'unsupported target-of-target hid direct aggro-holder evidence')
mobs[99].badTarget=false;mobs[99].target=0;mobs[99].holder=0
assert(runtime.findSelfDefenseTarget()==99,'100% aggro fallback unavailable when direct members have no data')
S.blocked[99]=true;assert(runtime.findSelfDefenseTarget()==nil,'unreachable self-defense target was selected')
S.blocked[99]=nil;S.distance=301;assert(runtime.findSelfDefenseTarget()==nil,'XYZ max chase range was bypassed')
S.distance=40;mobs[99].holder=1
compile(helper('legacyMaTarget'),env);compile(helper('maTargetId'),env);compile(helper('assistTargetId'),env)
-- Active but filtered MA targets block self-defense in both range and cooldown cases.
S.feed={id=131,engaged=true};S.blocked[131]=true
assert(runtime.assistTargetId()==nil and runtime.maTargetBlocksDefense,'unreachable active MA switched to an add')
S.blocked[131]=nil;S.distance=301
assert(runtime.assistTargetId()==nil and runtime.maTargetBlocksDefense,'distant active MA switched to an add')
S.distance=40
local id,def=runtime.assistTargetId();assert(id==131 and not def,'MA did not outrank direct attacker')
S.feed=false
id,def=runtime.assistTargetId();assert(id==99 and def,'idle MA prevented direct self-defense')
ctrl.assist_self_defense=false;assert(runtime.assistTargetId()==nil,'disabled self-defense still selected an add')
ctrl.assist_self_defense=true
-- Every action's Assist Target recipient shares the exact selection rule.
compile(helper('resolveTargetId'),env)
assert(runtime.resolveTargetId('Assist Target')==99,'ability did not use direct attacker')
S.xt={};mobs[99].holder=2;mobs[99].target=2;mobs[99].aggro=1
assert(runtime.resolveTargetId('Assist Target')==nil,'ability fell back to an arbitrary current hostile')
S.feed={id=131,engaged=true};S.blocked[131]=true
assert(runtime.resolveTargetId('Assist Target')==nil,'ability bypassed active MA cooldown')
-- Asynchronous /assist cannot read the old selected mob as a new response.
S.blocked={};S.feed=nil;S.target=77;S.complete=false
assert(runtime.maTargetId()==nil and runtime.maTargetBlocksDefense,'unacknowledged /assist accepted old mob')
assert(S.commands[#S.commands]=='/assist mob71')
S.target=131;S.time=100.1
assert(runtime.maTargetId()==nil,'target change without completed response was accepted')
S.complete=true;assert(runtime.maTargetId()==131,'completed response was not accepted')
S.time=101.2;S.complete=false
assert(runtime.maTargetId()==131,'refresh dropped the previously verified unchanged target')
S.target=77;assert(runtime.maTargetId()==nil,'refresh accepted an unrelated changed target')
S.time=103.3;assert(runtime.maTargetId()==nil,'timeout retained the stale verified result')
S.unsupported=true;S.direct=131;S.target=131
assert(runtime.maTargetId()==131,'positive direct MA target fallback did not verify unsupported build')
S.unsupported=false;S.feed=false;runtime.legacyAssist=nil
-- No polling delay is permitted in this selector (it can be called by UI status).
assert(not helper('legacyMaTarget'):find('mq.delay',1,true))
print('PASS: direct self-defense, MA priority, action recipients, asynchronous assist and timeout')

-- Execute the actual Manual branch with a player-selected unreachable target.
local combatStart=assert(source:find('local function combatTick()',1,true))
local a=assert(source:find("    elseif ctrl.mode == 'Manual' then",combatStart,true))
local b=assert(source:find("    elseif ctrl.mode == 'Puller' then",a,true))
env.firstNPCXtarget=function() error('Manual replaced the player-selected blocked target') end
env.styleReach=function() return 15 end;env.desiredRange=env.styleReach
env.setTarget=runtime.setTarget;env.moveToward=function() return true end
env.manualMovePolicy=compile(assert(source:match('(local function manualMovePolicy.-\nend)'))..'\nreturn manualMovePolicy',env)
local manual=compile('return function() local haveNPC,engage,manualHold=true,false,false\nif false then\n'..
    source:sub(a,b-1)..'\nend return haveNPC,engage end',env)
ctrl.mode='Manual';S.target=131;S.blocked[131]=true;S.distance=77;S.los=true
pursuit.unreachableIds=S.blocked
local clears=S.clears;local selected=S.selected
local have,engage=manual()
assert(not have and not engage and S.target==131 and S.clears==clears and S.selected==selected,
    'Manual cooldown cleared/replaced player selection')
S.distance=10;have,engage=manual()
assert(have and engage and not S.blocked[131] and S.target==131,'player reposition could not retry immediately')
-- Run the real moveToward stall path: stop chasing, retain Manual selection;
-- automated Assist still abandons the unreachable mob.
compile(helper('huntXtarMaxDist') .. '\n' .. helper('moveToward'),env)
S.distance=77;S.los=false;S.time=200
local function stall(mode)
    ctrl.mode=mode;S.target=131;S.blocked={};pursuit.unreachableIds=S.blocked
    pursuit.id=131;pursuit.bestDist=77;pursuit.improvedAt=190;pursuit.navStalls=0;pursuit.lastLoSAt=0
    local before=S.clears
    assert(not runtime.moveToward(131,15) and S.blocked[131])
    return S.clears-before
end
assert(stall('Manual')==0 and S.target==131,'Manual stalled approach cleared player target')
assert(stall('Assist')==1 and S.target==0,'Assist failed approach did not release target')
-- The 15-second watchdog must honor the same Manual ownership.
local wa=assert(source:find('    local inCombatNow =',combatStart,true))
local watchdog=source:sub(wa,assert(source:find('    if ctrl.debug_mode and',wa,true))-1)
env.markUnreachable=runtime.markUnreachable;mq.TLO.Me.AutoFire=function() return false end
local watch=compile('return function() local haveNPC,engage,manualHold=true,false,false\n'..watchdog..'\nreturn haveNPC,engage end',env)
for _,mode in ipairs({'Manual','Assist'}) do
    ctrl.mode=mode;S.target=131;S.time=300;S.blocked={};pursuit.unreachableIds=S.blocked
    pursuit.approachTargetId=131;pursuit.approachStartedAt=280
    local before=S.clears
    have,engage=watch()
    assert(not have and not engage and S.blocked[131])
    assert(S.clears-before==(mode=='Manual' and 0 or 1),'watchdog violated target ownership')
end
-- Actual chat handlers must not restart movement during the blocked-target cooldown.
S.target=131;S.blocked[131]=true;ctrl.mode='Manual';ctrl.running=true
local function localHelper(name)
    return assert(source:match('(local function '..name..'.-\nend)'))
end
env.isCombat=function() return true end
local before=#S.commands
compile(localHelper('repositionCloser')..'\nreturn repositionCloser',env)()
compile(localHelper('handleCantHitFromHere')..'\nreturn handleCantHitFromHere',env)()
local handler=assert(source:match('(runtime%.handleCannotSeeTarget = function%(%).-\nend)'))
compile(handler,env);runtime.handleCannotSeeTarget()
assert(#S.commands==before and S.target==131,'chat reposition handler restarted a blocked approach')
print('PASS: Manual selection/cooldown/reposition retry, movement/watchdog failure ownership and chat handlers')
-- Final unstuck recovery and cannot-hit failure share Manual target ownership.
env.stickLoaded=function() return false end
me.X=function() return 1 end;me.Y=function() return 1 end
compile(helper('performUnstuck'),env)
for _,mode in ipairs({'Manual','Assist'}) do
    ctrl.mode=mode;S.target=131;S.blocked={};S.time=400
    env.stuckState={attempts=3,lastStuckRecoveryAt=399}
    local before=S.clears
    runtime.performUnstuck()
    assert(S.blocked[131] and S.clears-before==(mode=='Manual' and 0 or 1),'unstuck failure violated ownership')
    S.target=131;S.blocked={};pursuit.cantHitCount=3;pursuit.lastCantHitAt=398.5
    before=S.clears
    compile(localHelper('handleCantHitFromHere')..'\nreturn handleCantHitFromHere',env)()
    assert(S.blocked[131] and S.clears-before==(mode=='Manual' and 0 or 1),'cannot-hit failure violated ownership')
end
-- Execute the actual Assist + Chase branch rather than duplicating its decision tree.
local aa=assert(source:find("    elseif ctrl.mode == 'Assist' then",combatStart,true))
local ab=assert(source:find('\n    -- Target pursuit / approach timeout',aa,true))
env.pctHP=function() return S.hp or 94 end;env.targetIsEngaged=runtime.targetIsEngaged
local moves=0;env.moveToward=function() moves=moves+1;return true end
env.chaseMA=function() end;env.idleReturn=function() end
runtime.combatHold=function() return false end
local assist=compile('return function(forceId) local haveNPC,engage=false,false\nif false then\n'..
    source:sub(aa,ab-1)..'\nreturn haveNPC,engage end',env)
ctrl.mode='Assist';ctrl.submode='Chase';ctrl.assist_at=95
S.feed={id=131,engaged=true};S.blocked={[131]=true};S.target=99;mobs[99].holder=1
local before=S.selected;have,engage=assist(nil)
assert(not have and not engage and S.selected==before,'Assist Chase selected a defender after rejecting active MA')
S.blocked={};S.target=77;have,engage=assist(nil)
assert(have and engage and S.target==131 and moves==1,'Assist Chase did not select and approach active MA')
S.hp=100;have,engage=assist(nil)
assert(have and not engage and moves==1,'Assist At HP threshold was bypassed')
print('PASS: final unstuck/cannot-hit ownership and actual Assist Chase priority/HP gate')
