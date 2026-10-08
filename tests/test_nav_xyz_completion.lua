-- Created By: NeroMorte - Nav completion ownership, bounded arrival latch and failure fallback regressions.
package.path = './TAC/lua/?.lua;' .. package.path
local module = require('TAC_support_modules.nav_xyz_completion')
local data = {serial=0, result='None', target=99, tag='', accepted=false, active=false, zone=1, wet=true,
    enabled='1', limit='5', mx=0, my=0, mz=0}
local mq = {TLO={Navigation={LastResultSerial=function() return data.serial end,
    LastResult=function() return data.result end, LastTargetID=function() return data.target end,
    LastTag=function() return data.tag end, LastXYZStallArrival=function() return data.accepted end,
    Active=function() return data.active end,
    Setting=function(key) return key=='XYZStallArrival' and data.enabled or data.limit end},
    Zone={ID=function() return data.zone end}, Me={Underwater=function() return data.wet end,
    Levitating=function() return false end, X=function() return data.mx end,
    Y=function() return data.my end, Z=function() return data.mz end}}}
local geometry = {horizontal=.36, distance=4.07, x=0, y=0, z=4.05}
local driver = module.new(mq)
local function complete(tag, result, accepted)
    data.serial=data.serial+1;data.active=false;data.tag=tag;data.result=result;data.accepted=accepted
end
local tag=driver:start(99,2,'chase')
complete(tag,'Cancelled',false)
assert(not driver:arrived(99,2,'chase',geometry,true))
assert(not driver:canUseNav(99,2,'chase',geometry), 'cancelled route must use fallback without immediate Nav churn')
geometry.x=2;assert(driver:canUseNav(99,2,'chase',geometry));geometry.x=0
tag=driver:start(99,2,'chase');complete('someone_else','Reached',true)
assert(not driver:arrived(99,2,'chase',geometry,true))
tag=driver:start(99,2,'chase');complete(tag,'Reached',false)
assert(not driver:arrived(99,2,'chase',geometry,true), 'ordinary completion cannot invent tolerance')
tag=driver:start(99,2,'chase');complete(tag,'Reached',true)
assert(driver:arrived(99,2,'chase',geometry,true))
assert(driver:arrived(99,2,'chase',geometry,true), 'stationary accepted arrival must not reissue Nav')
geometry.x=1.1;assert(not driver:arrived(99,2,'chase',geometry,true));geometry.x=0
assert(not driver:arrived(99,2,'chase',geometry,true), 'leader movement invalidates the old arrival')
tag=driver:start(99,2,'chase');complete(tag,'Reached',true)
assert(not driver:arrived(99,1,'chase',geometry,true))
assert(not driver:arrived(99,2,'combat',geometry,true))
data.target=100;assert(not driver:arrived(99,2,'chase',geometry,true));data.target=99
data.zone=2;assert(not driver:arrived(99,2,'chase',geometry,true));data.zone=1
data.enabled='0';assert(not driver:arrived(99,2,'chase',geometry,true));data.enabled='1'
data.limit='3';assert(not driver:arrived(99,2,'chase',geometry,true));data.limit='5'
assert(not driver:arrived(99,2,'chase',geometry,false))
data.wet=false;assert(not driver:arrived(99,2,'chase',geometry,true));data.wet=true
assert(driver:arrived(99,2,'chase',geometry,true))
data.active=true;assert(not driver:arrived(99,2,'chase',geometry,true));data.active=false
assert(not driver:arrived(99,2,'chase',geometry,true), 'another active route invalidates a cached arrival')
tag=driver:start(99,2,'combat');data.active=true
assert(driver:waitingNear(geometry,true))
geometry.horizontal=3;assert(not driver:waitingNear(geometry,true));geometry.horizontal=.36
assert(not driver:waitingNear(geometry,false))
driver:clear();assert(not driver:arrived(99,2,'combat',geometry,true))
data.serial=nil;tag=driver:start(99,2,'chase');data.serial=100
assert(not driver:arrived(99,2,'chase',geometry,true), 'old Nav without completion data must fail closed')
print('PASS: owned result, cancellation fallback, stale/unrelated results, stationary latch, movement/range/zone/settings invalidation, old Nav and final-approach delegation')
