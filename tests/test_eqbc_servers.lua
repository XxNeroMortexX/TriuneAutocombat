-- Created By: NeroMorte - registration gates and preservation of user settings.
package.path = './TAC/lua/?.lua;' .. package.path
local policy = require('TAC_support_modules.eqbc_server_update_policy')
local release = require('TAC_support_modules.eqbc_server_release')
local defaults = require('TAC_support_modules.eqbc_server_defaults')
assert(not policy.versionOK('4.1.6'))
assert(policy.versionOK('4.1.7') and policy.versionOK('4.2.0'))
local calls, logs = {}, {}
local function log(s) logs[#logs+1]=s end
local function command(s) calls[#calls+1]=s end
local p = policy.new(release)
assert(not p:step({available=true,busy=true,version='4.1.7'}, {}, command, tostring, function() end, log))
assert(#calls == 0)
assert(p:step({available=true,version='4.1.6'}, {}, command, tostring, function() end, log))
assert(#calls == 0)
local prefs = {}
p = policy.new(release)
local mappings = {}
for _,item in ipairs(release.payloads) do mappings[#mappings+1]={id=item.id,enabled=false} end
assert(p:step({available=true,version='4.1.7',managedProfiles={{id='morte',enabled=true,role='main',owner='XxNeroMortexX',repository='TriuneAutocombat',mappings=mappings}}}, prefs, command,tostring,function() end,log))
assert(#calls == 0 and mappings[1].enabled == false)
-- Exercise the full migration, including restart in the middle of registration.
local profile={id='morte',enabled=true,role='main',owner='XxNeroMortexX',repository='TriuneAutocombat',mappings={}}
local engine={available=true,version='4.1.7',managedProfiles={profile}}
prefs={}; p=policy.new(release)
local fieldKeys={remote='remotePath',root='destinationRoot',destination='destinationPath',restart='restartRequired'}
local steps=0
local function migrate(cmd)
    local id=cmd:match('mappings create morte (%S+)')
    if id then profile.mappings[#profile.mappings+1]={id=id,enabled=true,recursive=true,required=true,destinationRoot='lua',destinationPath=''}; return end
    local mapId,field,value=cmd:match('mappings set morte (%S+) (%S+) (.*)$')
    assert(mapId and field)
    if value=='""' then value='' elseif value=='on' then value=true elseif value=='off' then value=false end
    for _,m in ipairs(profile.mappings) do if m.id==mapId then m[fieldKeys[field] or field]=value; return end end
    error('unknown mapping')
end
repeat
    steps=steps+1; assert(steps<100)
    p:step(engine,prefs,migrate,function(v) return v=='' and '""' or v end,function() end,log)
    if steps==7 then p=policy.new(release) end
until p.done
assert(#profile.mappings==2)
for _,m in ipairs(profile.mappings) do assert(m.enabled and not m.recursive and m.destinationRoot=='mq' and m.destinationPath=='') end
local callsBefore=#calls
assert(policy.new(release):step(engine,prefs,command,tostring,function() end,log));assert(#calls==callsBefore)
local folder = os.tmpname(); os.remove(folder); assert(os.execute('mkdir "'..folder..'"')==0)
local function write(name,data) local f=assert(io.open(folder..'/'..name,'wb')); f:write(data); f:close() end
local function read(name) local f=io.open(folder..'/'..name,'rb'); if not f then return nil end local s=f:read('*a'); f:close(); return s end
assert(defaults.ensure(folder,log)); assert(read('EQBCS.ini')==nil)
write('EQBCS.exe','test'); write('EQBCS-Go.exe','test')
assert(defaults.ensure(folder,log)); assert(read('EQBCS.ini'):find('Port=2112',1,true)); assert(read('EQBCS-Go.ini'):find('Port=2113',1,true))
write('EQBCS.ini','[Settings]\nPort=7777\nPassword=private\n'); os.remove(folder..'/EQBCS-Go.ini')
assert(defaults.ensure(folder,log)); assert(read('EQBCS-Go.ini')==read('EQBCS.ini'))
write('EQBCS-Go.ini','custom-go'); assert(defaults.ensure(folder,log)); assert(read('EQBCS-Go.ini')=='custom-go')
for _,s in ipairs(logs) do assert(not s:find('private',1,true)) end
for _,name in ipairs({'EQBCS.ini','EQBCS-Go.ini','EQBCS.exe','EQBCS-Go.exe'}) do os.remove(folder..'/'..name) end
os.remove(folder)
print('EQBC server policy/default tests passed')
