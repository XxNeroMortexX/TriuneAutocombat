-- Created By: NeroMorte - Actual casting and assist policies must preserve player-selected targets.
local f=assert(io.open('TAC/lua/triune.lua'));local source=f:read('*a');f:close()
local function helper(name) return assert(source:match('(function runtime%.'..name..'.-\nend)'),name) end
local function compile(code,env) local fn=assert(loadstring(code));setfenv(fn,env);return fn() end
local state={target=20,attack=true,xt=true,stops=0,commands={},pets=0}
local ctrl={mode='Manual',manual_allow_target_switch=true,assist_require_ma_attack=false,xtar_nav_dist=150}
local tracker={activeSpell='Nuke',activeTargetId=10,targetRequired=true}
local runtime={maPcId=function() return 7 end,boxnetMaTarget=function() return state.feed end,
    targetIsEngaged=function() return true end,findSelfDefenseTarget=function() return 99 end}
local pursuit,petState={id=10},{lastCmdTargetId=10}
local function spawn(id)
 return setmetatable({ID=function() return id end,Type=function() return id==7 and 'PC' or 'NPC' end,
 Dead=function() return false end,CleanName=function() return 'Mob'..id end}, {__call=function() return id~=0 end})
end
local mq={TLO={Target={ID=function() return state.target end},Spawn=spawn,
 Me={Combat=function() return state.attack end,AutoFire=function() return false end}},
 cmd=function(line)state.commands[#state.commands+1]=line end,
 cmdf=function(fmt,id) state.target=id;state.commands[#state.commands+1]=string.format(fmt,id) end}
local env=setmetatable({ctrl=ctrl,runtime=runtime,castTracker=tracker,mq=mq,pursuit=pursuit,petState=petState,
 isHostileTarget=function(id)return id and id>=10 end,isSpawnAlive=function(id)return id>0 and id~=666 end,
 isSpawnPetOrPlayer=function(id)return id==7 end,isUnreachable=function()return false end,
 distToId=function()return 50 end,stopMoving=function()state.stops=state.stops+1;pursuit.id=0 end,
 sendPetCmd=function()state.pets=state.pets+1 end},{__index=_G})
runtime.setTarget=function(id)state.target=id end;runtime.clearTarget=function()state.target=0 end
compile(helper('observeManualCastTarget')..'\n'..helper('finishTargetRestore'),env)
local a=assert(source:find('    if isCastingNow then\n',source:find('local function combatTick()',1,true),true))
local b=assert(source:find('        local isBrd = false',a,true))
env.isCastingOrStarting=function()return true end
env.isTargetRequiredSpell=function()return true end
mq.TLO.Me.Casting=setmetatable({ID=function()return 123 end},{__call=function()return true end})
env.getActiveTargetRequiredCastingId=compile(assert(source:match('(local function getActiveTargetRequiredCastingId.-\nend)'))..'\nreturn getActiveTargetRequiredCastingId',env)
local castPrefix=compile('return function() local isCastingNow=true\n'..source:sub(a,b-1)..'\nend\nend',env)
castPrefix()
assert(state.target==20 and not tracker.targetRequired,'Manual offensive cast snapped back to old NPC')
-- Another click during the same cast wins over an earlier queued request.
state.target=30;runtime.finishTargetRestore();assert(state.target==30)
-- Friendly target lock stays intact while remembering the requested NPC.
tracker.activeSpell='Cure';tracker.activeTargetId=1;tracker.targetRequired=true
runtime.restoreTargetId=10;runtime.restoreFromTargetId=1;state.target=20
castPrefix();assert(state.target==1 and tracker.targetRequired and runtime.manualCastTarget==20)
runtime.finishTargetRestore();assert(state.target==20,'cure restored old mob instead of requested new one')
-- A later target selection after the cure completes overrides the queued target.
runtime.restoreTargetId=10;runtime.restoreFromTargetId=1;runtime.manualCastTarget=20;state.target=30
runtime.finishTargetRestore();assert(state.target==30)
-- Clearing target is intentional too; do not re-acquire the old NPC.
tracker.activeTargetId=10;tracker.targetRequired=true;state.target=0
castPrefix();runtime.finishTargetRestore();assert(state.target==0)
-- Disabled option retains original casting lock and post-support restoration.
ctrl.manual_allow_target_switch=false;state.target=20;tracker.activeTargetId=10;tracker.targetRequired=true
castPrefix();assert(state.target==10)
runtime.restoreTargetId=10;runtime.restoreFromTargetId=1;state.target=20
runtime.finishTargetRestore();assert(state.target==10)
ctrl.manual_allow_target_switch=true;ctrl.mode='Assist';state.target=20;tracker.targetRequired=true
castPrefix();assert(state.target==10,'Manual preference changed Assist cast targeting')
-- Strict assist: fresh exact target + Attack ON + the MA own XTarget membership are all required.
compile(helper('maTargetId')..'\n'..helper('assistTargetId')..'\n'..helper('waitForMaAttack'),env)
ctrl.assist_require_ma_attack=true
for _,feed in ipairs({false,{id=20,engaged=true},{id=20,engaged=true,attackOn=false,onXtarget=true},
 {id=20,engaged=true,attackOn=true,onXtarget=false}}) do
 state.feed=feed;runtime.maTargetCache=nil
 assert(runtime.assistTargetId()==nil,'strict assist bypassed Attack/XTarget permission or self-defense')
end
state.feed={id=20,engaged=true,attackOn=true,onXtarget=true};runtime.maTargetCache=nil
assert(runtime.assistTargetId()==20)
state.feed.id=30;runtime.maTargetCache=nil;assert(runtime.assistTargetId()==30,'MA target change retained previous mob')
state.feed=nil;runtime.legacyMaTarget=function()error('strict mode must not issue legacy /assist without a report')end
runtime.maTargetCache=nil;assert(runtime.assistTargetId()==nil)
ctrl.assist_require_ma_attack=false;state.feed={id=20,engaged=true};runtime.maTargetCache=nil
assert(runtime.assistTargetId()==20,'disabled strict option changed existing assist behavior')
state.feed=false;runtime.maTargetCache=nil;assert(runtime.assistTargetId()==99,'legacy self-defense was removed')
-- Revoke an old NPC approach/pet dispatch once; do not stop normal MA follow every tick.
ctrl.assist_require_ma_attack=true;state.attack=true
runtime.waitForMaAttack();assert(state.stops==1 and state.pets==1 and petState.lastCmdTargetId==0)
pursuit.id=7;runtime.waitForMaAttack();assert(state.stops==1 and state.pets==1)
print('PASS: selectable Manual casting/restoration, newer/empty selections, strict MA permission, target changes and follow/pet cleanup')

-- Execute the actual Force selection expression: strict permission cannot be bypassed by an F marker.
runtime.petCampActive=function()return false end;runtime.forcedTargetId=function()return 99 end
local fa=assert(source:find('    local forceId = not runtime.petCampActive()',1,true))
local fb=assert(source:find('    if forceId and',fa,true))
local forced=compile('return function()\n'..source:sub(fa,fb-1)..'return forceId end',env)
ctrl.mode='Manual';assert(forced()==99)
ctrl.mode='Assist';ctrl.assist_require_ma_attack=false;assert(forced()==99)
ctrl.assist_require_ma_attack=true;assert(forced()==nil)
-- The actual instant AA and clickie restore paths must also preserve a newer selection during their yield.
for _,name in ipairs({'fireAA','useClickie'}) do
 local start=assert(source:find(name=='fireAA' and 'function runtime.fireAA' or 'runtime.useClickie = function',1,true))
 local first=assert(source:find('    if orig ~= id and not keepHostile then',start,true))
 local last=assert(source:find('    if ',first+5,true)) -- use structural marker after the whole restore block below
 last=assert(source:find(name=='fireAA' and '    if not isFD and wasAttacking' or '    if castMs == 0 and wasAttacking',first,true))
 local restore=compile('return function() local orig,id,keepHostile,castMs=10,1,false,0\n'..source:sub(first,last-1)..'end',env)
 ctrl.mode='Manual';ctrl.manual_allow_target_switch=true;state.target=1
 mq.delay=function()state.target=30 end
 restore();assert(state.target==30,name..' restored an old mob after the player selected another')
 ctrl.manual_allow_target_switch=false;state.target=1;restore();assert(state.target==10)
end
print('PASS: strict Force exclusion, legacy Force behavior and conditional instant AA/clickie restoration')

-- Actual action recipient gate: no offensive current-target bypass; self support remains available.
env.baseTok=function(t)return t end;env.isIgnored=function()return false end
mq.TLO.Me.ID=function()return 1 end
compile(helper('resolveTargetId'),env)
ctrl.mode='Assist';ctrl.assist_require_ma_attack=true;state.target=20
state.feed={id=20,engaged=true,attackOn=false,onXtarget=true};runtime.maTargetCache=nil
assert(runtime.resolveTargetId('Current Target')==nil)
assert(runtime.resolveTargetId('Myself')==1)
state.feed.attackOn=true;runtime.maTargetCache=nil
assert(runtime.resolveTargetId('Current Target')==20)
state.target=30;assert(runtime.resolveTargetId('Current Target')==nil)
-- Execute the real Assist movement branch: wait/follow MA versus approach the authorized NPC.
local cs=assert(source:find('local function combatTick()',1,true))
local aa=assert(source:find("    elseif ctrl.mode == 'Assist' then",cs,true))
local ab=assert(source:find('    -- Target pursuit / approach timeout check:',aa,true))
local approach=compile('return function() local forceId=nil; local haveNPC,engage=false,false; if false then\n'..source:sub(aa,ab-1)..'return haveNPC,engage end',env)
local follow,moves=0,0
env.setTarget=runtime.setTarget;env.pctHP=function()return 50 end;env.targetIsEngaged=runtime.targetIsEngaged
env.distToId=function()return 50 end;env.desiredRange=function()return 15 end
env.moveToward=function(id)assert(id==20);moves=moves+1;return false end
env.chaseMA=function()follow=follow+1 end;runtime.combatHold=function()return false end
ctrl.submode='Chase';state.feed.attackOn=false;runtime.maTargetCache=nil;state.target=30
local have=approach();assert(not have and moves==0 and follow==1,'blocked assist approached an NPC')
state.feed.attackOn=true;runtime.maTargetCache=nil;have=approach()
assert(have and moves==1 and follow==1,'authorized assist kept following MA instead of the NPC')
-- Actual slash command branch saves independent per-character control values.
local ca=assert(source:find("    elseif cmd == 'maattack' or cmd == 'targetswitch' then",1,true))
local cb=assert(source:find("    elseif cmd == 'status' then",ca,true))
local command=compile("return function(cmd,value) local args={cmd,value}; if false then\n"..source:sub(ca,cb-1)..'end end',env)
local saves=0;runtime.saveLoadout=function()saves=saves+1 end
command('maattack','on');assert(ctrl.assist_require_ma_attack)
command('targetswitch','off');assert(not ctrl.manual_allow_target_switch and ctrl.assist_require_ma_attack)
command('maattack','off');assert(not ctrl.assist_require_ma_attack and not ctrl.manual_allow_target_switch)
command('targetswitch','on');assert(ctrl.manual_allow_target_switch and saves==4)
print('PASS: offensive recipient gates, preserved self support, actual Assist movement and saved independent controls')
