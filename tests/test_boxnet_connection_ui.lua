-- Created By: NeroMorte - Render the actual Connection tab with formatter-free ImGui doubles.
local f = assert(io.open('TAC/lua/tac/boxnet.lua', 'r'))
local source = f:read('*a'); f:close()
local draw = assert(source:match('(function net%.connectionText.-\nend)')) .. '\n' ..
    assert(source:match('(function net%.drawConnection.-\nend)'))
local rendered, wrapDepth, requests, clicked = {}, 0, {}, nil
local ips, discoveryError = '192.168.1.4, fe80::1%12', 'Discovery 100%: literal %s %n'
local connection = { enabled = true, status = 'Connection 100%: %s %n', servers = {},
    host = '192.168.1.5', port = 2113, protected = false, manualPassword = 'not-for-display' }
function connection:request(action, server, password)
    requests[#requests + 1] = { action = action, server = server, password = password }
end
local trace = {}
local net = { connection = connection, traceConnection = function(step) trace[#trace + 1] = step end }
local function formatted() error('Connection tab must not enter a native text formatter') end
local env = setmetatable({ net = net,
    core = { saveLoadout = function() error('Opening the tab must not change settings') end },
    mq = { TLO = { EQBC = { LocalIPs = function() return ips end,
        DiscoveryError = function() return discoveryError end } },
        cmd = function() error('Rendering must not execute a network command') end },
    tlo = function(fn, fallback) local ok, value = pcall(fn); return ok and value ~= nil and value or fallback end,
    ImGuiInputTextFlags = { Password = 1024 },
    ImGui = {
        PushTextWrapPos = function(pos) assert(pos == 0); wrapDepth = wrapDepth + 1 end,
        TextUnformatted = function(text) assert(wrapDepth == 1); rendered[#rendered + 1] = text end,
        PopTextWrapPos = function() wrapDepth = wrapDepth - 1; assert(wrapDepth == 0) end,
        TextWrapped = formatted, Text = formatted, TextDisabled = formatted,
        Checkbox = function(_, value) return value end,
        Button = function(label) return label == clicked end, SameLine = function() end,
        Selectable = function() return false end,
        InputText = function(label, value, flags)
            if label == 'Password##bnPassword' then assert(flags == 1024) end
            return value
        end,
    },
}, { __index = _G })
assert(load(draw, 'actualConnectionTab', 't', env))()
net.drawConnection()
assert(wrapDepth == 0 and #requests == 0)
assert(rendered[1] == connection.status)
assert(rendered[2] == 'This machine: ' .. ips)
local sawError = false
for _, text in ipairs(rendered) do if text == discoveryError then sawError = true end end
assert(sawError, 'Discovery errors must render literally, including percent sequences')
-- Protected servers and long/empty text also avoid printf formatting and preserve wrapping.
connection.protected = true; net.connectionProtected = nil
connection.servers = { { host = '192.168.1.5', port = 2113, password = true } }
connection.status = string.rep('100% %s %n ', 400)
net.drawConnection(); assert(wrapDepth == 0)
for _, text in ipairs(rendered) do assert(not text:find(connection.manualPassword, 1, true)) end
net.connectionText(nil); assert(rendered[#rendered] == '' and wrapDepth == 0)
ips, discoveryError = '', ''; net.drawConnection(); assert(wrapDepth == 0)
-- Buttons keep queuing work for the main tick rather than executing it while drawing.
clicked = 'Find LAN servers##bnDiscover'; net.drawConnection()
assert(requests[#requests].action == 'scan')
clicked = 'Disconnect / use local Actors##bnDisconnect'; net.drawConnection()
assert(requests[#requests].action == 'disconnect')
clicked = 'Connect##bnConnect'; net.drawConnection()
assert(requests[#requests].action == 'connect')
assert(requests[#requests].server.host == connection.host)
print('PASS: actual Connection tab uses literal wrapped text, handles percent/long/blank content, and queues network actions')

-- Edited By: NeroMorte - A breadcrumb is closed on disk before its associated native call.
local writes, flushes, closes = {}, 0, 0
local traceEnv = setmetatable({ net = { connectionTraceEnabled = true, connectionTracePath = 'trace.log' },
    io = { open = function(path, mode)
        assert(path == 'trace.log' and mode == 'a')
        return { write = function(_, step) writes[#writes + 1] = step end,
            flush = function() flushes = flushes + 1 end, close = function() closes = closes + 1 end }
    end },
}, { __index = _G })
assert(load(assert(source:match('(function net%.traceConnection.-\nend)')), 'actualTraceWriter', 't', traceEnv))()
traceEnv.net.traceConnection('before native widget')
assert(writes[1] == 'before native widget' and flushes == 1 and closes == 1)
traceEnv.net.connectionTraceEnabled = false; traceEnv.net.traceConnection('ignored')
assert(#writes == 1)
print('PASS: one-shot Connection trace flushes/closes each breadcrumb and stops when disabled')
