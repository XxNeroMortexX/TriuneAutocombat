-- Created By: NeroMorte - exercise real automatic connection state without MQ.
package.path='TAC/lua/?.lua;'..package.path
local M=require('TAC_support_modules.boxnet_connection')
local function fixture()
 local c=M.new(); local commands,selected,saved={},0,0
 local api={command=function(cmd)commands[#commands+1]=cmd end,select=function()selected=selected+1 end,localMode=function()selected=-1 end,save=function()saved=saved+1 end}
 return c,commands,api,function()return selected,saved end
end
local c,commands,api,state=fixture()
local view={loaded=true,discovery=true,connected=false,control=false,servers={}}
c:tick(0,view,api);assert(commands[1]=='/squelch /eqbcdiscover')
view.scanning=true;c:tick(1,view,api);assert(#commands==1)
view.scanning=false;view.servers={{host='192.168.1.5',port=3113,password=false}}
c:tick(4,view,api);assert(commands[#commands]=='/squelch /bccmd connect 192.168.1.5 3113 NULL');assert(c.host=='192.168.1.5')
c:tick(5,view,api);assert(commands[#commands]=='/squelch /bccmd connect 192.168.1.5 3113 NULL')
view.connected=true;view.host=c.host;view.port=c.port;c:tick(20,view,api);assert(commands[#commands]=='/squelch /bccmd set control on')
assert(state()>0);assert(c:settings().protected==false)
c:request('scan');c:tick(20.1,view,api);assert(commands[#commands]=='/squelch /eqbcdiscover')
c:request('connect',{host='192.168.1.6',port=4113,password=false});c:tick(20.2,view,api);assert(commands[#commands]=='/squelch /bccmd connect 192.168.1.6 4113 NULL')
c:request('disconnect');c:tick(21,view,api);assert(not c.enabled and commands[#commands]=='/squelch /bccmd quit');assert(state()==-1)
local many,mc,ma=fixture();view.connected=false;view.servers={{host='1.2.3.4',port=2113},{host='1.2.3.5',port=2113}};many:tick(0,view,ma);many:tick(4,view,ma);assert(#mc==1 and many.host=='')
local protected,pc,pa=fixture();view.servers={{host='1.2.3.4',port=2113,password=true}};protected:tick(0,view,pa);protected:tick(4,view,pa);assert(#pc==1 and protected.host=='')
protected:request('connect',view.servers[1],'secret');protected:tick(5,view,pa);assert(pc[#pc]:match(' secret$'));assert(protected:settings().password==nil)
local invalid,ic,ia=fixture();invalid:request('connect',{host='evil;echo',port=2113},nil);invalid:tick(0,view,ia);assert(#ic==0)
local old,oc,oa=fixture();view.discovery=false;old:tick(0,view,oa);assert(#oc==0 and old.status:find('Update'))
local reloaded=M.new();reloaded:load(c:settings());assert(not reloaded.enabled and reloaded.host==c.host)
print('BoxNet automatic connection tests passed')
