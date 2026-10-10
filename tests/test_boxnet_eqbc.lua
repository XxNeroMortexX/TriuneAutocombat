-- Created By: NeroMorte — execute the EQBC adapter and real Boxnet plugin across a fake network.
package.path = './TAC/lua/?.lua;' .. package.path
local adapter = require('TAC_support_modules.boxnet_eqbc')
local now, packets, boxes = 100, {}, {}
local function box(name, zone)
    local b = { name = name, zone = zone or 'shadowhaven', connected = true, commands = {}, group = {} }
    local mq = { TLO = {
        EQBC = { Connected = function() return b.connected end, Setting = function() return true end },
        EverQuest = { PID = function() return 1234 end, Server = function() return 'NMS' end },
        Me = { CleanName = function() return name end },
        Zone = { ShortName = function() return b.zone end },
        Group = { Member = function(n)
            if not b.group[n:lower()] then return nil end
            return setmetatable({ ID = function() return 42 end }, { __call = function() return true end })
        end },
    } }
    function mq.cmd(command)
        local recipient, frame = command:match('^/bct (%w+) //ac net _eqbc (.+)$')
        if not recipient then frame = command:match('^/bca //ac net _eqbc (.+)$') end
        if frame then
            assert(#command < 1800)
            packets[#packets + 1] = { from = name, to = recipient, frame = frame }
        else b.commands[#b.commands + 1] = command end
    end
    function mq.cmdf(fmt, ...) mq.cmd(string.format(fmt, ...)) end
    local ctrl = { mode = 'Manual', submode = 'Hunt', running = false, ma_name = '', plugins = {} }
    local core = { mq = mq, ctrl = ctrl, ImGui = {}, runtime = { pullState = 'IDLE' }, myClasses = {'WAR'}, VERSION = '3.1', saveLoadout = function() end }
    local plugin = assert(loadfile('TAC/lua/tac/boxnet.lua'))()
    b.clockOffset = name == 'Bob' and 100000 or 0
    plugin.clock = function() return now + b.clockOffset end
    plugin.registry = {}
    plugin.actorsModule = false -- cross-PC transport must not require local Actors.
    plugin.onLoadSettings({ transport = 'eqbc', announce = false })
    plugin.onInit(core)
    b.plugin, b.core = plugin, core
    boxes[name:lower()] = b
    return b
end
local function flush()
    local guard = 0
    while #packets > 0 do
        guard = guard + 1; assert(guard < 10000)
        local batch = packets; packets = {}
        for _, item in ipairs(batch) do
            for key, b in pairs(boxes) do
                if b.connected and ((item.to and key == item.to:lower()) or (not item.to and key ~= item.from:lower())) then
                    b.plugin.onCommand('net', {'net', '_eqbc', item.frame})
                end
            end
        end
        for _, b in pairs(boxes) do b.plugin.onTick() end
    end
    for _, b in pairs(boxes) do b.plugin.onTick() end
end
local function last(b) return b.commands[#b.commands] end
local A, B, C = box('Alice'), box('Bob'), box('Carol','poknowledge')
A.group.bob, B.group.alice = true, true
flush()
assert(A.core.boxnet.available())
assert(A.core.boxnet.peer('Bob').hb.zone == 'shadowhaven')
assert(A.core.boxnet.peer('Carol').hb.zone == 'poknowledge')
assert(A.plugin.net.probe.state == 'ok')
assert(A.plugin.onSaveSettings().transport == 'eqbc')
-- A target acquired five seconds ago on a PC with a different uptime stays five seconds old here.
B.plugin.net.eqbc:send({ v=1, kind='heartbeat', from='Bob', data={name='Bob',zone='shadowhaven',target={id=77,since=now+B.clockOffset-5}} })
flush()
assert(A.core.boxnet.peer('Bob').hb.target.since == now - 5)
assert(A.plugin.sendCommand('all','pause')); flush()
assert(last(B) == '/ac pause' and last(C) == '/ac pause' and #A.commands == 0)
local n = #C.commands
assert(A.plugin.sendCommand('zone','burn on')); flush()
assert(last(B) == '/ac burn on' and #C.commands == n)
assert(A.plugin.sendCommand('group','run')); flush()
assert(last(B) == '/ac run' and #C.commands == n)
assert(A.plugin.sendCommand('Bob','/echo encoded; ${Me.CleanName}')); flush()
assert(last(B) == '/echo encoded; ${Me.CleanName}')
-- Do not evaluate macro strings inside network frames; the command runs on receiver.
B.plugin.cfg.acceptSlash = false
n = #B.commands
assert(A.plugin.sendCommand('Bob','/sit')); flush()
assert(#B.commands == n)
B.plugin.cfg.acceptSlash = true
B.plugin.cfg.trust, B.plugin.cfg.allowlist = 'allow', {'Carol'}
assert(A.plugin.sendCommand('Bob','run')); flush(); assert(#B.commands == n)
B.plugin.cfg.trust = 'all'
assert(A.plugin.sendPing('Bob')); flush()
assert(A.core.boxnet.peer('Bob').pingMs ~= nil)
local received
B.core.boxnet.subscribe('test:data', function(data) received = data end)
assert(A.core.boxnet.send('Bob','test:data',{ text = string.rep('x',5000), values={true,false,3.5} })); flush()
assert(#received.text == 5000 and received.values[2] == false)
-- Replayed frames must not execute a command twice.
assert(A.plugin.sendCommand('Bob','burn off'))
local copies = {}; for _, f in ipairs(packets) do copies[#copies + 1] = f end
flush(); n = #B.commands
for _, f in ipairs(copies) do B.plugin.onCommand('net',{'net','_eqbc',f.frame}) end
flush(); assert(#B.commands == n)
B.connected = false; B.plugin.onTick(); assert(not B.core.boxnet.available())
assert(B.plugin.sendCommand('all','run') == false)
assert(A.plugin.sendCommand('Bob','run')); flush()
now = now + 6; A.plugin.onTick(); flush()
assert(A.plugin.net.lastSendStatus == -3)
B.connected = true; B.plugin.onTick(); flush()
assert(A.core.boxnet.peer('Bob') and B.core.boxnet.available())
-- Malformed frames and non-finite values are rejected without executing code.
n = #B.commands
B.plugin.onCommand('net',{'net','_eqbc','bad.1.999.ff'})
assert(#B.commands == n and B.plugin.net.lastDrop ~= nil)
assert(not pcall(adapter.decode,'s9:short'))
assert(not pcall(adapter.encode,{n=math.huge}))
local value = adapter.decode(adapter.encode({s='a\0b\n', n=-42, b=false, nested={1,2}}))
assert(value.s == 'a\0b\n' and value.n == -42 and value.b == false)
-- Stopping EQBC selection disables wire handling; explicit Actors preserves old behavior.
B.plugin.onCommand('net',{'net','transport','actors'}); B.plugin.onTick()
assert(B.plugin.cfg.transport == 'actors' and not B.plugin.net.eqbc)
for _, b in pairs(boxes) do b.plugin.onDestroy() end
print('EQBC Boxnet integration tests passed (peer discovery, scopes, RPC, permissions, reconnect, fragmentation and replay).')
