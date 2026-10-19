-- Created By: NeroMorte - Verify upstream Hunt range fixes retain the fork's Camp and sharing policy.
local f = assert(io.open('TAC/lua/triune.lua')); local source = f:read('*a'); f:close()
local ctrl = { mode='Puller', submode='Hunt', xtar_nav_dist=42, hunter_radius=600 }
local runtime = {}
local chunk = assert(source:match('(function runtime%.huntXtarMaxDist.-\nend)'))
local fn = assert(loadstring(chunk)); setfenv(fn, setmetatable({runtime=runtime,ctrl=ctrl},{__index=_G})); fn()
assert(runtime.huntXtarMaxDist()==600, 'Hunt must approach XTargets across its scan radius')
ctrl.ignore_distant_xtargets=true
assert(runtime.huntXtarMaxDist()==42, 'explicit distant-XTarget opt-out must keep the saved chase limit')
ctrl.ignore_distant_xtargets=false; ctrl.waypoints={{x=0,y=0,z=0}}; ctrl.waypoint_scan_radius=250
assert(runtime.huntXtarMaxDist()==250, 'waypoint scan distance must feed Hunt approach distance')
ctrl.use_waypoints=false
assert(runtime.huntXtarMaxDist()==600)
ctrl.submode='Camp'
assert(runtime.huntXtarMaxDist()==42, 'Camp must retain its separate fixed-circle exception')
ctrl.mode='Assist';ctrl.submode='Chase'
assert(runtime.huntXtarMaxDist()==42, 'Assist must retain the configured chase limit')
-- Use the actual scope shortcut rather than the upstream replacement list implementation.
local zone, added = 'potactics', nil
runtime.npcZone=function() return zone end
runtime.npcAdd=function(kind,name,scope) added={kind,name,scope};return true end
chunk=assert(source:match('(function runtime%.addZoneIgnore.-\nend)'))
fn=assert(loadstring(chunk));setfenv(fn,setmetatable({runtime=runtime},{__index=_G}));fn()
assert(runtime.addZoneIgnore('a test NPC'))
assert(added[1]=='ignore' and added[2]=='a test NPC' and added[3]=='potactics')
zone=nil;added=nil
assert(runtime.addZoneIgnore('a test NPC')==false and added==nil, 'no current zone must not alter Global')
print('PASS: upstream Hunt limits, explicit opt-out, fixed Camp policy, Assist range and existing zone-ignore API')

-- Character switching must clear per-character zone lists even without a saved loadout.
runtime.zonePull={oldzone={'old target'}}; runtime.zoneIgnore={oldzone={'old ignore'}}
runtime.loadoutFilePath=function() return '/unused/character-loadout.lua' end
chunk=assert(source:match('(function runtime%.loadAll.-\nend)'))
local loadEnv=setmetatable({runtime=runtime,myName='NewCharacter',mq={configDir='/unused'},
    loadfile=function() return nil end},{__index=_G})
fn=assert(loadstring(chunk));setfenv(fn,loadEnv);fn();runtime.loadAll()
assert(next(runtime.zonePull)==nil and next(runtime.zoneIgnore)==nil, 'new character inherited previous zone lists')
print('PASS: character without a save starts with empty Global and zone lists')
