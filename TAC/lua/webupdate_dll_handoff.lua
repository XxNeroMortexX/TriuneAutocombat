-- Independent MacroQuest Lua coordinator for one configured plugin DLL.
-- Runs under MQ2Lua, outside the plugin being unloaded.
local mq = require('mq')

local function fail(message)
    print('[MQ2WebUpdate] DLL handoff: ' .. tostring(message))
    error(tostring(message), 0)
end

local function readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local bytes = f:read('*a')
    f:close()
    return bytes
end

local function loaded(name)
    local ok, result = pcall(function() return mq.TLO.Plugin(name).IsLoaded() end)
    return ok and result == true
end

local function awaitLoaded(name, expected, timeoutMs)
    local elapsed = 0
    repeat
        if loaded(name) == expected then return true end
        mq.delay(100)
        elapsed = elapsed + 100
    until elapsed >= timeoutMs
    return false
end

local plugins = tostring(mq.TLO.MacroQuest.Path('plugins') or ''):gsub('[\\/]+$', '')
if not plugins:match('^[A-Za-z]:[\\/]') or
    plugins:find('["%%!&|<>%^\r\n]') then
    fail('Unsafe or unavailable MacroQuest plugin directory.')
end
local root = plugins:match('^(.*)[\\/][^\\/]+$')
if not root then fail('MacroQuest runtime directory unavailable.') end
local stageRoot = root .. '\\webupdate_stage'
local marker = stageRoot .. '\\dll-handoff.active'
local ticket = stageRoot .. '\\dll-handoff.ini'
local script = root .. '\\lua\\webupdate_dll_replace.ps1'
if not readFile(script) then fail('Independent DLL replacement helper is missing.') end

local recovering = readFile(marker) ~= nil
local ticketData = readFile(recovering and marker or ticket)
if not ticketData then fail('Verified DLL handoff ticket is missing.') end
local fields = {}
for line in ticketData:gmatch('[^\r\n]+') do
    local key, value = line:match('^([A-Za-z0-9]+)=(.*)$')
    if not key or fields[key] then fail('Malformed DLL handoff ticket.') end
    fields[key] = value
end
local function identity(value)
    return type(value) == 'string' and #value <= 64 and
        value:match('^[A-Za-z0-9_-]+$') ~= nil
end
local function sha(value, length)
    return type(value) == 'string' and #value == length and
        value:match('^[a-fA-F0-9]+$') ~= nil
end
if fields.Format ~= 'MQ2WebUpdateDllHandoff' or fields.Version ~= '1' or
    not identity(fields.ProfileID) or not identity(fields.MappingID) or
    not identity(fields.PluginName) or
    fields.DestinationName ~= fields.PluginName .. '.dll' or
    not sha(fields.CommitSHA, 40) or
    not sha(fields.ExpectedSHA256, 64) or
    not sha(fields.OriginalSHA256, 64) or
    not (fields.OldPresent == '0' or fields.OldPresent == '1') or
    (fields.OldPresent == '0' and fields.OriginalSHA256 ~= string.rep('0', 64)) or
    (recovering and fields.WasLoaded ~= '0' and fields.WasLoaded ~= '1') then
    fail('DLL handoff identity or hashes are invalid.')
end
local name = fields.PluginName
local backup = root .. '\\webupdate_backup\\' .. fields.ProfileID ..
    '\\dll\\' .. name .. '\\' .. fields.CommitSHA ..
    '\\' .. fields.DestinationName

local function invoke(action)
    local command = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass ' ..
        '-File "' .. script .. '" -Action ' .. action ..
        ' -RuntimeRoot "' .. root .. '" -ProfileID ' .. fields.ProfileID ..
        ' -PluginName ' .. name .. ' -CommitSHA ' .. fields.CommitSHA ..
        ' -NewSHA256 ' .. fields.ExpectedSHA256 ..
        ' -OldSHA256 ' .. fields.OriginalSHA256 ..
        ' -OldPresent ' .. fields.OldPresent
    local ok, why, code = os.execute(command)
    return ok == true or ok == 0 or (why == 'exit' and code == 0)
end

local function restorePrevious()
    if loaded(name) then
        mq.cmd('/plugin ' .. name .. ' unload noauto')
        if not awaitLoaded(name, false, 10000) then
            fail('Plugin could not be unloaded for rollback. Recovery marker retained.')
        end
    end
    if not invoke('Rollback') or not invoke('InspectOld') then
        fail('Rollback could not restore verified original state. Recovery marker retained.')
    end
    if fields.WasLoaded == '1' then
        mq.cmd('/plugin ' .. name .. ' load noauto')
        if not awaitLoaded(name, true, 15000) then
            fail('Original plugin restored on disk but did not load. Recovery marker retained.')
        end
    end
    if not os.remove(marker) then fail('Could not clear the recovery marker.') end
end

if recovering then
    if invoke('InspectOld') then
        if fields.WasLoaded == '1' and not loaded(name) then
            mq.cmd('/plugin ' .. name .. ' load noauto')
            if not awaitLoaded(name, true, 15000) then
                fail('Original DLL verified, but plugin did not reload. Marker retained.')
            end
        end
        if not os.remove(marker) then fail('Could not clear the recovery marker.') end
        print('[MQ2WebUpdate] Interrupted DLL update recovered; original plugin is intact.')
        return
    end
    if invoke('InspectNew') then
        restorePrevious()
        print('[MQ2WebUpdate] Interrupted DLL update rolled back to the original state.')
        return
    end
    fail('Neither original nor new DLL hash matches. Inspect backup before retrying.')
end

local payload = readFile(stageRoot .. '\\dll-handoff-payload.dll')
if not payload or tonumber(fields.ExpectedSize) ~= #payload then
    fail('Prepared DLL payload is missing or has changed size.')
end
local wasLoaded = loaded(name)
if fields.OldPresent == '0' and wasLoaded then
    fail('A plugin planned as new is already loaded. Restage before applying.')
end
fields.WasLoaded = wasLoaded and '1' or '0'
local markerFile = io.open(marker, 'wb')
if not markerFile then fail('Could not create recovery marker.') end
markerFile:write(ticketData, 'WasLoaded=', fields.WasLoaded, '\n')
markerFile:close()

if wasLoaded then
    print('[MQ2WebUpdate] Unloading ' .. name .. ' before verified DLL replacement.')
    mq.cmd('/plugin ' .. name .. ' unload noauto')
    if not awaitLoaded(name, false, 10000) then
        if not os.remove(marker) then fail('Plugin stayed loaded; recovery marker retained.') end
        fail('Plugin did not unload; original file remains installed.')
    end
end
if not invoke('Install') or not invoke('InspectNew') then
    print('[MQ2WebUpdate] DLL installation failed; restoring previous state.')
    restorePrevious()
    fail('DLL installation failed; verified previous state restored.')
end
if wasLoaded then
    mq.cmd('/plugin ' .. name .. ' load noauto')
    if not awaitLoaded(name, true, 15000) then
        print('[MQ2WebUpdate] New plugin failed to load; rolling back.')
        restorePrevious()
        fail('New plugin failed to load; original plugin restored.')
    end
end
if not os.remove(marker) then fail('DLL installed; recovery marker could not be cleared.') end
print('[MQ2WebUpdate] ' .. name .. ' DLL installed and verified.')
