-- Created By: NeroMorte - [Main] HUD data, missing macro variables and ImGui lifetime.
local hud=assert(loadfile('TAC/lua/zenith_hud.lua'))('test')
local values={['${Me.CleanName}']='Tester',['${Target.ID}']='12',['${Target.CleanName}']='NPC 100% %s',
    ['${Target.Distance}']='25',['${Target.ConColor}']='RED',['${Me.Gem[1].Name}']='Nuke',
    ['${Me.Gem[1].MyRange}']='50',['${Bool[${Target.Slowed}]}']='TRUE',
    ['${SpawnCount[PC]}']='3',['${SpawnCount[NPC]}']='100',['${Me.TargetOfTarget.ID}']='7'}
local mq={parse=function(expr) return values[expr] or 'NULL' end}
local sample=hud.capture(mq)
assert(sample.name=='Tester' and sample.idle=='N/A' and sample.combatID=='N/A')
assert(sample.targetID==12 and sample.distance==25 and sample.status.Slowed and not sample.status.Rooted)
assert(#sample.spells==9 and sample.spells[1].range==50 and sample.players==3 and sample.npcs==100)
assert(hud.read({parse=function() error('unsupported') end},'bad')=='N/A')
local depth,tables,drawn=0,0,{}
ImGuiCond={FirstUseEver=1};ImGuiWindowFlags={NoMove=1,NoResize=2};ImGuiTableFlags={Borders=1}
bit=bit or {bor=function(a,b) return a+b end}
local gui=setmetatable({Begin=function() depth=depth+1;return true,true end,End=function() depth=depth-1 end,
    BeginTable=function() tables=tables+1;return true end,EndTable=function() tables=tables-1 end,
    TextUnformatted=function(s) drawn[#drawn+1]=s end,
    TextColored=function(_,_,_,_,fmt,value) assert(fmt=='%s');drawn[#drawn+1]=value end,
    Checkbox=function(_,value) return value,false end,
}, {__index=function() return function() end end})
local state=hud.defaults();state.cache=sample;hud.draw(gui,state)
assert(depth==0 and tables==0 and table.concat(drawn,'\n'):find('NPC 100% %s',1,true))
gui.Begin=function() depth=depth+1;return false,false end
hud.draw(gui,state);assert(not state.open and depth==0)
values['${Target.ID}']='0';sample=hud.capture(mq);assert(not sample.target and sample.targetID==0)
print('PASS: standalone [Main] HUD, optional macro variables, nine spell ranges, literal text and balanced windows/tables')
