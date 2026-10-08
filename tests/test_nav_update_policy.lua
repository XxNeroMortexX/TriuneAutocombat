-- Created By: NeroMorte - Add-only automatic Nav mapping registration and interruption recovery.
package.path = './TAC/lua/?.lua;' .. package.path
local module=require('TAC_support_modules.nav_update_policy')
local release={enabled=true,remote='MQ2Nav/MQ2Nav.dll',sha256=string.rep('a',64),client='RoF2',architecture='Win32'}
local engine={available=true,busy=false,stageReady=false,profileStoreError='',managedProfiles={
    {id='morte',owner='XxNeroMortexX',repository='TriuneAutocombat',enabled=true,mappings={}},
    {id='gennro',owner='gennro',repository='TriuneAutocombat',enabled=true,mappings={}}}}
local prefs,commands,saves={},0,0
local keys={enabled='enabled',name='name',remote='remotePath',root='destinationRoot',recursive='recursive',required='required',restart='restartRequired'}
local function command(text)
    commands=commands+1
    if text:find('mappings create',1,true) then
        engine.managedProfiles[1].mappings={{id='plugin-mq2nav',name='plugin-mq2nav',remotePath='files',destinationRoot='lua',destinationPath='',enabled=true,recursive=true,required=false,restartRequired=false}}
    else
        local field,value=text:match('mappings set morte plugin%-mq2nav (%w+) (.*)$')
        assert(field and value)
        if value=='on' then value=true elseif value=='off' then value=false end
        engine.managedProfiles[1].mappings[1][keys[field]]=value
    end
    return true
end
local function save() saves=saves+1 end
local function encode(v) return v end
local function log() end
local policy=module.new(release)
engine.busy=true;assert(not policy:step(engine,prefs,command,encode,save,log) and commands==0);engine.busy=false
engine.stageReady=true;assert(not policy:step(engine,prefs,command,encode,save,log) and commands==0);engine.stageReady=false
for _=1,40 do if policy:step(engine,prefs,command,encode,save,log) then break end end
assert(policy.done and commands>0 and saves>0)
local mapping=engine.managedProfiles[1].mappings[1]
assert(mapping.remotePath==release.remote and mapping.destinationRoot=='plugins' and mapping.enabled and not mapping.required)
assert(#engine.managedProfiles[2].mappings==0)
local before=commands;module.new(release):step(engine,prefs,command,encode,save,log);assert(commands==before)
-- Existing customized or disabled mappings are never rewritten, even on the first run.
mapping.remotePath='custom/Nav.dll';mapping.enabled=false
module.new(release):step(engine,{},command,encode,save,log);assert(commands==before and not mapping.enabled and mapping.remotePath=='custom/Nav.dll')
assert(module.new({enabled=false}).done)
assert(module.new({enabled=true,sha256='placeholder'}).done)
-- A created mapping and persisted pending marker are completed after a restart.
engine.managedProfiles[1].mappings={};prefs={nav_plugin_update_policy={morte='creating'}}
policy=module.new(release)
for _=1,40 do if policy:step(engine,prefs,command,encode,save,log) then break end end
assert(policy.done and prefs.nav_plugin_update_policy.morte=='done')
print('PASS: automatic verified-release mapping, no download/apply, busy/staged locks, preserved user mappings, unrelated repositories, restart recovery and no placeholder distribution')
