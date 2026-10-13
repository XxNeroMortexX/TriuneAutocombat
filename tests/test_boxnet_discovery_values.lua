-- Created By: NeroMorte - Indexed MQ members return callable objects until evaluated.
local file = assert(io.open('TAC/lua/tac/boxnet.lua', 'r'))
local source = file:read('*a'); file:close()
local function indexed(value)
    return setmetatable({}, { __call = function() return value end,
        __concat = function() error('raw MQ object reached label concatenation') end,
        __tostring = function() error('raw MQ object reached string formatting') end })
end
local entries = {
    { host = '192.168.1.5', port = 2113, password = true },
    { port = 2113, password = false }, -- result expired between count and field reads
    { host = '192.168.1.6', port = 0, password = false },
    { host = '192.168.1.7', port = 2113.5, password = false },
}
local labels = {}
local eqbc = {
    Setting = function() return indexed(false) end,
    Connecting = function() return false end, DiscoveryVersion = function() return 1 end,
    DiscoveryScanning = function() return false end, Server = function() return '192.168.1.5' end,
    Port = function() return 2113 end, DiscoveryCount = function() return #entries end,
    DiscoveryHost = function(i) return indexed(entries[i].host) end,
    DiscoveryPort = function(i) return indexed(entries[i].port) end,
    DiscoveryPassword = function(i) return indexed(entries[i].password) end,
    LocalIPs = function() return '192.168.1.4' end, DiscoveryError = function() return '' end,
}
local net = { traceConnection = function() end }
local env = setmetatable({ net = net, mq = { TLO = { EQBC = eqbc } },
    eqbcConnected = function() return true end,
    tlo = function(fn, fallback) local ok, value = pcall(fn); if ok and value ~= nil then return value end; return fallback end,
    core = { saveLoadout = function() error('opening tab must not save') end },
    ImGuiInputTextFlags = { Password = 1024 },
    ImGui = { Checkbox = function(_, value) return value end,
        PushTextWrapPos = function() end, TextUnformatted = function() end, PopTextWrapPos = function() end,
        Button = function() return false end, SameLine = function() end,
        Selectable = function(label) labels[#labels + 1] = label; return false end,
        InputText = function(_, value) assert(type(value) == 'string'); return value end,
    },
}, { __index = _G })
local helpers = source:match('(function net%.connectionServer.-\nend)') or ''
helpers = helpers .. '\n' .. assert(source:match('(function net%.connectionView.-\nend)')) .. '\n' ..
    assert(source:match('(function net%.connectionText.-\nend)')) .. '\n' ..
    assert(source:match('(function net%.drawConnection.-\nend)'))
assert(load(helpers, 'actualDiscoveredValues', 't', env))()
local view = net.connectionView()
for _, server in ipairs(view.servers) do
    assert(type(server.host) == 'string', 'discovered host must be evaluated before rendering')
    assert(type(server.port) == 'number', 'discovered port must be evaluated before rendering')
    assert(type(server.password) == 'boolean')
end
assert(#view.servers == 1 and view.servers[1].password == true)
assert(view.control == false, 'false control setting must not remain a truthy MQ object')
net.connection = { enabled = true, status = 'Ready', servers = view.servers,
    host = '', port = 2113, protected = false, manualPassword = '' }
net.drawConnection()
assert(labels[1] == '192.168.1.5:2113 (password)##bnServer1')
-- Missing or malformed data never crosses the render boundary as MQ objects.
eqbc.DiscoveryHost = function() return indexed(indexed('nested')) end
assert(#net.connectionView().servers == 0)
eqbc.DiscoveryHost = function() error('index disappeared') end
assert(#net.connectionView().servers == 0)
print('PASS: actual discovery getters evaluate MQ objects, retain password/control booleans, skip expired/invalid rows, and render labels')
