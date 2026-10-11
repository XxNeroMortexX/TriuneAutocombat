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
    'npcAdd', 'npcRemove', 'npcNotify', 'npcShareFiles', 'npcWrapText' }) do install(name) end
-- Browser requires no installed Lua module and closes the built-in listing pipe.
local entries = { 'friend-sro.json', 'Friend Raid.JSON', 'triune_npc_lists_guktop.json', 'bad..json', 'notes.txt' }
local closed, command = 0, nil
local originalIo = io
local fakeIo = setmetatable({ popen = function(cmd)
    command = cmd
    return { lines = function()
        local index = 0
        return function() index = index + 1; return entries[index] end
    end, close = function() closed = closed + 1 end }
end }, { __index = originalIo })
env.io, env.package = fakeIo, { config = '\\' }
env.require = function() error('No optional modules installed') end
local choices = assert(runtime.npcShareFiles())
assert(#choices == 3 and choices[1] == 'Friend Raid.JSON' and choices[2] == 'friend-sro.json' and choices[3] == 'triune_npc_lists_guktop.json')
assert(closed == 1 and command:find('dir /b /a-d', 1, true))
local originalDir = mq.configDir
mq.configDir = 'C:\\unsafe%PATH%'
local guarded, guardReason = runtime.npcShareFiles()
assert(#guarded == 0 and guardReason and closed == 1)
mq.configDir = originalDir
fakeIo.popen = function() error('Unavailable') end
local fallback, reason = runtime.npcShareFiles()
assert(#fallback == 0 and reason == 'Cannot browse files. Enter the JSON filename below.')
env.io, env.package = originalIo, package
local longPath = 'E:\\' .. string.rep('very-long-folder\\', 30) .. 'triune_npc_lists_potactics.json'
local lines = runtime.npcWrapText(longPath, 15, function(v) return #v end)
assert(table.concat(lines) == longPath and #lines > 20)
for _, line in ipairs(lines) do assert(#line <= 15) end
local unicodeText = 'A\195\169B'
local unicodeLines = runtime.npcWrapText(unicodeText, 1, function(v)
    local count = 0
    for _ in v:gmatch('[%z\1-\127\194-\244][\128-\191]*') do count = count + 1 end
    return count
end)
assert(#unicodeLines == 3 and unicodeLines[2] == '\195\169' and table.concat(unicodeLines) == unicodeText)
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
local exportPath = mq.configDir .. '/triune_npc_lists_sro.json'
local function readExport()
    local f = assert(io.open(exportPath, 'rb')); local text = f:read('*a'); f:close(); return text
end
local originalExport = readExport()
local oldAttack, oldIgnore = runtime.zonePull.sro, runtime.zoneIgnore.sro
runtime.zonePull.sro, runtime.zoneIgnore.sro = { 'fresh' }, {}
assert(runtime.npcExport('sro', 'merge'))
local mergedExport = assert(runtime.npcJsonRead(readExport()))
assert(#mergedExport.attack == 3 and #mergedExport.ignore == 1)
assert(#runtime.zonePull.sro == 1 and runtime.zonePull.sro[1] == 'fresh' and #runtime.zoneIgnore.sro == 0)
assert(runtime.npcExport('sro', 'replace'))
local replacedExport = assert(runtime.npcJsonRead(readExport()))
assert(#replacedExport.attack == 1 and replacedExport.attack[1] == 'fresh' and #replacedExport.ignore == 0)
local beforeFailure = readExport()
env.os = setmetatable({ rename = function(from, to)
    if from:sub(-4) == '.tmp' then return nil, 'Injected replacement failure' end
    return os.rename(from, to)
end }, { __index = os })
assert(not runtime.npcExport('sro', 'replace'))
assert(readExport() == beforeFailure) -- Original export restored after install failure.
env.os = os
local backup = assert(io.open(exportPath .. '.bak.1', 'rb'))
assert(backup:read('*a') == originalExport); backup:close()
local existingTemp = assert(io.open(exportPath .. '.tmp', 'wb')); existingTemp:write('preserve me'); existingTemp:close()
assert(not runtime.npcExport('sro', 'replace') and readExport() == beforeFailure)
os.remove(exportPath .. '.tmp')
runtime.zonePull.sro, runtime.zoneIgnore.sro = oldAttack, oldIgnore
local restore = assert(io.open(exportPath, 'wb')); restore:write(originalExport); restore:close()

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
local clickExport, chats, drawn, copied = false, {}, {}, nil
env.print = function(message) chats[#chats + 1] = message end
local imgui = setmetatable({
    GetContentRegionAvail = function() return 120, 200 end,
    CalcTextSize = function(value) return #value, 10 end,
    TextUnformatted = function(value) drawn[#drawn + 1] = value end,
    SetClipboardText = function(value) copied = value end,
    BeginCombo = function() return false end,
    BeginChild = function() return false end,
    EndChild = function() ended = ended + 1 end,
    SmallButton = function(label)
        if clickExport and label == 'Export Zone##npcExport' then clickExport = false; return true end
        return false
    end,
    BeginPopup = function() return false end,
    InputText = function(_, value) return value, false end,
}, { __index = function() return function() end end })
env.ImGui, env.UI, env.accent = imgui, { px = function(v) return v end }, function() end
for _, name in ipairs({ 'drawNpcText', 'drawNpcMessage', 'drawNpcLists' }) do
    local ui = assert(loadstring(assert(source:match('(function UI%.' .. name .. '%b().-\nend)\n'))))
    setfenv(ui, env); ui()
end
env.UI.drawNpcLists()
assert(ended == 2 and runtime.npcEditZone == 'guktop')
runtime.npcEditZone = 'sro'; env.UI.drawNpcLists()
assert(runtime.npcEditZone == 'sro' and runtime.isPullAllowed('a frog'))
current = 'sro'; env.UI.drawNpcLists()
assert(runtime.npcEditZone == 'sro' and ended == 6)
clickExport = true; env.UI.drawNpcLists()
assert(#chats == 0 and runtime.npcExportZone == 'sro')
runtime.npcNotify(true, 'Exported to test.json')
assert(#chats == 1 and chats[1]:find('Exported to test.json', 1, true))
drawn = {}; env.UI.drawNpcText(longPath)
assert(table.concat(drawn) == longPath)
for _, line in ipairs(drawn) do assert(#line <= 120) end
runtime.npcListPath = longPath
imgui.SmallButton = function(label) return label == 'Copy Export Path##npcCopyExportPath' end
env.UI.drawNpcMessage()
assert(copied == longPath)
os.remove(runtime.loadoutFilePath()); os.remove(exportPath)
os.remove(exportPath .. '.bak.1'); os.remove(exportPath .. '.bak.2')
assert(os.execute('rmdir "' .. mq.configDir .. '"') == 0)
print('PASS: zone isolation, Global compatibility, include/ignore precedence, safe JSON, merge/replace and save/reload')
