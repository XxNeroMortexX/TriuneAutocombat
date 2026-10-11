-- Created By: NeroMorte - Exercise actual list/share methods without MQ or EQ.
local file = assert(io.open('TAC/lua/triune.lua')); local source = file:read('*a'); file:close()
local current, saves = 'sro', 0
local runtime = { pullList = {}, ignoreList = {}, zonePull = {}, zoneIgnore = {},
    saveLoadout = function() saves = saves + 1; return true end }
local mq = { configDir = os.tmpname(), TLO = { Zone = {
    ShortName = function() return current end, Name = function() return 'South Ro' end } } }
os.remove(mq.configDir)
assert(os.execute('mkdir -p "' .. mq.configDir .. '"') == 0)
local env = setmetatable({ runtime = runtime, mq = mq }, { __index = _G })
local function install(name)
    local body = assert(source:match('(function runtime%.' .. name .. '%b().-\nend)\n'), name)
    local fn = assert(loadstring(body, name)); setfenv(fn, env); fn()
end
for _, name in ipairs({ 'npcZone', 'npcList', 'npcHas', 'npcNames', 'npcZoneStores', 'npcZoneOptions',
    'npcJsonQuote', 'npcJsonExport', 'npcJsonRead', 'npcSharePath', 'npcExport', 'npcPreview', 'npcImport',
    'npcAdd', 'npcRemove' }) do install(name) end
local ignored = assert(loadstring(assert(source:match('(local function isIgnored%b().-\nend)\n')) .. '\nreturn isIgnored'))
setfenv(ignored, env); env.isIgnored = ignored()
install('isPullAllowed')
assert(runtime.isPullAllowed('a rat'))
assert(runtime.npcAdd('attack', 'a rat', 'sro'))
assert(runtime.isPullAllowed('a rat king') and not runtime.isPullAllowed('a ratman'))
assert(not runtime.isPullAllowed('a snake'))
assert(runtime.npcAdd('ignore', 'a rat king', 'sro'))
assert(not runtime.isPullAllowed('a rat king'))
current = 'guktop'
assert(runtime.isPullAllowed('a snake') and not env.isIgnored('a rat king'))
assert(runtime.npcAdd('attack', 'a frog', 'guktop'))
assert(runtime.npcAdd('attack', 'a snake', 'global'))
assert(runtime.isPullAllowed('a frog') and runtime.isPullAllowed('a snake'))
assert(runtime.npcAdd('ignore', 'a snake', 'global'))
assert(not runtime.isPullAllowed('a snake'))
-- Browsing another zone has no influence on targeting.
runtime.npcEditZone = 'sro'
assert(runtime.isPullAllowed('a frog') and not runtime.isPullAllowed('a rat'))
assert(not runtime.npcAdd('attack', 'a frog', 'guktop'))
assert(runtime.npcAdd('attack', 'a "quoted" \\ creature', 'sro'))
local data = assert(runtime.npcJsonRead(runtime.npcJsonExport('sro')))
assert(data.zone == 'sro' and #data.attack == 2 and #data.ignore == 1)
assert(data.attack[1] == 'a "quoted" \\ creature')
assert(runtime.npcJsonRead('\239\187\191' .. runtime.npcJsonExport('sro')))
local unicode = runtime.npcJsonExport('sro'):gsub('a rat"', 'a \\u0072at"')
assert(runtime.npcJsonRead(unicode))
for _, text in ipairs({ 'return { zone="sro" }', '{}', '[1]', runtime.npcJsonExport('sro') .. 'junk',
    runtime.npcJsonExport('sro'):gsub('"attack": %b[]', '"attack": {}'),
    runtime.npcJsonExport('sro'):gsub('"version": 1', '"version": 2'),
    runtime.npcJsonExport('sro'):gsub('"zone": "sro"', '"zone": "../sro"'),
    runtime.npcJsonExport('sro'):gsub('"version": 1', '"version": 1, "version": 1'),
    runtime.npcJsonExport('sro'):gsub('a rat"', 'a \\u000arat"'),
    string.rep(' ', 1048577) }) do assert(not runtime.npcJsonRead(text), text:sub(1, 80)) end
assert(not runtime.npcSharePath('../evil.json') and not runtime.npcSharePath('C:\\evil.json'))
assert(not runtime.npcSharePath('bad.lua'))
assert(runtime.npcExport('sro'))
assert(not runtime.npcExport('sro')) -- Never silently overwrite an earlier export.
runtime.zonePull.sro = { 'existing' }
assert(runtime.npcPreview('triune_npc_lists_sro.json'))
assert(runtime.npcImport(false))
assert(#runtime.zonePull.sro == 3 and runtime.npcHas(runtime.zonePull.sro, 'existing'))
assert(runtime.npcPreview('triune_npc_lists_sro.json'))
assert(runtime.npcImport(false) and #runtime.zonePull.sro == 3) -- idempotent merge
assert(runtime.npcPreview('triune_npc_lists_sro.json'))
assert(runtime.npcImport(true) and #runtime.zonePull.sro == 2)
assert(#runtime.zonePull.guktop == 1 and #runtime.pullList == 1 and #runtime.ignoreList == 1)
assert(not runtime.npcPreview('missing.json') and not runtime.npcImport(true))
runtime.npcImportPreview = { zone = 'sro', attack = {}, ignore = {} }
assert(runtime.npcImport(true) and #runtime.zonePull.sro == 0 and #runtime.zoneIgnore.sro == 0)
local cleaned = runtime.npcZoneStores({ SRO = { 'b', 'a', 'a' }, bad = { true } })
assert(#cleaned.sro == 2 and cleaned.bad == nil)
-- Persist through the actual save/load path, not a duplicated serializer.
env.ALLDATA, env.myName, env.ctrl = {}, 'TestChar', { zone_hazards = {}, zone_waypoints = {} }
mq.TLO.EverQuest = { ServerName = function() return 'TestServer' end }
runtime.collectEntry = function() return {} end
runtime.syncCurrentZoneWaypoints = function() end
local serializeBody = assert(source:match('(local function serialize%b().-\nend)\n'))
local ser = assert(loadstring(serializeBody .. '\nreturn serialize')); setfenv(ser, env); env.serialize = ser()
install('loadoutFilePath'); install('loadAll')
local saveBody = assert(source:match('(runtime.saveLoadout = function%b().-\nend)\n'))
local save = assert(loadstring(saveBody)); setfenv(save, env); save()
runtime.saveLoadout(true, true)
runtime.zonePull, runtime.zoneIgnore, runtime.pullList, runtime.ignoreList = {}, {}, {}, {}
runtime.loadAll()
assert(#runtime.zonePull.guktop == 1 and #runtime.pullList == 1 and #runtime.ignoreList == 1)
assert(runtime.zonePull.sro and #runtime.zonePull.sro == 0)
-- Clipped ImGui children still receive EndChild, and zone transitions select the
-- actual zone without changing the targeting policy when another scope is viewed.
local ended = 0
local imgui = setmetatable({
    BeginCombo = function() return false end,
    BeginChild = function() return false end,
    EndChild = function() ended = ended + 1 end,
    SmallButton = function() return false end,
    BeginPopup = function() return false end,
    InputText = function(_, value) return value, false end,
}, { __index = function() return function() end end })
env.ImGui, env.UI, env.accent = imgui, { px = function(v) return v end }, function() end
local ui = assert(loadstring(assert(source:match('(function UI%.drawNpcLists%b().-\nend)\n'))))
setfenv(ui, env); ui()
env.UI.drawNpcLists()
assert(ended == 2 and runtime.npcEditZone == 'guktop')
runtime.npcEditZone = 'sro'; env.UI.drawNpcLists()
assert(runtime.npcEditZone == 'sro' and runtime.isPullAllowed('a frog'))
current = 'sro'; env.UI.drawNpcLists()
assert(runtime.npcEditZone == 'sro' and ended == 6)
os.remove(runtime.loadoutFilePath()); os.remove(mq.configDir .. '/triune_npc_lists_sro.json')
assert(os.execute('rmdir "' .. mq.configDir .. '"') == 0)
print('PASS: zone isolation, Global compatibility, include/ignore precedence, safe JSON, merge/replace and save/reload')
