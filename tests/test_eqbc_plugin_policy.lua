-- Created By: NeroMorte - verified DLL registration must never override existing mappings.
package.path='TAC/lua/?.lua;'..package.path
local policy=require('TAC_support_modules.eqbc_plugin_update_policy')
local release={enabled=true,remote='MQ2EQBC/MQ2EQBC.dll',sha256=string.rep('a',64),client='RoF2',architecture='Win32'}
local p=policy.new(release)
local prefs,commands={},{}
local profile={id='morte',owner='XxNeroMortexX',repository='TriuneAutocombat',enabled=true,mappings={}}
local engine={available=true,busy=false,stageReady=false,managedProfiles={profile}}
local function cmd(s)commands[#commands+1]=s end
local function save()end
p:step(engine,prefs,cmd,function(s)return s end,save,save)
assert(commands[1]:find('mappings create morte plugin%-mq2eqbc'))
local preserved=policy.new(release);profile.mappings={{id='custom',remotePath='MQ2EQBC/MQ2EQBC.dll',destinationRoot='plugins',enabled=false}}
local count=#commands
preserved:step(engine,{},cmd,function(s)return s end,save,save)
assert(#commands==count and preserved.done)
assert(policy.new({enabled=false}).done)
print('EQBC client add-only policy tests passed')
