-- Created by NeroMorte. Independent MQ2Lua script; never require Triune or
-- MQ2WebUpdate, because both must stop while a plugin DLL is replaced.
local mq = require('mq')

local function fail(message)
    error('[MQ2WebUpdate handoff] ' .. tostring(message), 0)
end

local function readFile(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local bytes = file:read('*a')
    file:close()
    return bytes
end

local function exists(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close()
    return true
end

local function equalFiles(left, right)
    local a, b = io.open(left, 'rb'), io.open(right, 'rb')
    if not a or not b then
        if a then a:close() end
        if b then b:close() end
        return false
    end
    local equal = true
    while true do
        local x, y = a:read(65536), b:read(65536)
        if x ~= y then equal = false; break end
        if not x then break end
    end
    a:close(); b:close()
    return equal
end

local function copyFile(source, destination)
    if exists(destination) then fail('Temporary DLL destination already exists.') end
    local input = io.open(source, 'rb')
    if not input then fail('Verified DLL source is missing.') end
    local output = io.open(destination, 'wb')
    if not output then input:close(); fail('Could not create DLL temporary file.') end
    local ok, err = pcall(function()
        while true do
            local chunk = input:read(65536)
            if not chunk then break end
            assert(output:write(chunk), 'DLL copy write failed.')
        end
        assert(output:flush(), 'DLL copy flush failed.')
    end)
    input:close(); output:close()
    if not ok or not equalFiles(source, destination) then
        os.remove(destination)
        fail(err or 'DLL copy failed byte verification.')
    end
end

local function loaded(name)
    local ok, value = pcall(function() return mq.TLO.Plugin(name).IsLoaded() end)
    return ok and value == true
end

local function awaitLoaded(name, expected, timeoutMs)
    local elapsed = 0
    while elapsed < timeoutMs do
        if loaded(name) == expected then return true end
        mq.delay(100)
        elapsed = elapsed + 100
    end
    return loaded(name) == expected
end

local function triuneRunning()
    local ok, found = pcall(function()
        local pids = tostring(mq.TLO.Lua.PIDs() or '')
        for pid in pids:gmatch('%d+') do
            local script = mq.TLO.Lua.Script(tonumber(pid))
            local name = tostring(script.Name() or ''):lower():gsub('\\', '/')
            name = name:match('([^/]+)$') or name
            name = name:gsub('%.lua$', '')
            local status = tostring(script.Status() or ''):upper()
            if name == 'triune' and (status == 'RUNNING' or status == 'PAUSED') then
                return true
            end
        end
        return false
    end)
    if not ok then return nil end
    return found
end

local function awaitTriune(expected, timeoutMs)
    local elapsed = 0
    while elapsed < timeoutMs do
        if triuneRunning() == expected then return true end
        mq.delay(100)
        elapsed = elapsed + 100
    end
    return triuneRunning() == expected
end

local function ticketFields(raw)
    if not raw or #raw > 4096 then fail('Verified DLL ticket is missing or oversized.') end
    local fields = {}
    for line in raw:gmatch('[^\r\n]+') do
        local key, value = line:match('^([A-Za-z0-9]+)=(.*)$')
        if not key or fields[key] then fail('Malformed DLL ticket.') end
        fields[key] = value
    end
    local function id(value)
        return type(value) == 'string' and #value > 0 and #value <= 64 and
            value:match('^[A-Za-z0-9_-]+$') ~= nil
    end
    local function sha(value, length)
        return type(value) == 'string' and #value == length and
            value:match('^[0-9a-fA-F]+$') ~= nil
    end
    if fields.Format ~= 'MQ2WebUpdateDllHandoff' or fields.Version ~= '1' or
        not id(fields.ProfileID) or not id(fields.MappingID) or
        not id(fields.PluginName) or
        fields.DestinationName ~= fields.PluginName .. '.dll' or
        not sha(fields.CommitSHA, 40) or not sha(fields.ExpectedSHA256, 64) or
        not sha(fields.OriginalSHA256, 64) or
        (fields.OldPresent ~= '0' and fields.OldPresent ~= '1') or
        (fields.OldPresent == '0' and
            fields.OriginalSHA256 ~= string.rep('0', 64)) or
        not tonumber(fields.ExpectedSize) or
        tonumber(fields.ExpectedSize) < 512 or
        tonumber(fields.ExpectedSize) > 64 * 1024 * 1024 then
        fail('Invalid DLL ticket identity or size.')
    end
    return fields
end

local plugins = tostring(mq.TLO.MacroQuest.Path('plugins') or ''):gsub('[\\/]+$', '')
if not plugins:match('^[A-Za-z]:[\\/]') or
    plugins:find('["%%!&|<>%^\r\n]') then
    fail('Unsafe MacroQuest plugins path.')
end
local root = plugins:match('^(.*)[\\/][^\\/]+$')
if not root then fail('MacroQuest runtime root is unavailable.') end
local stage = root .. '\\webupdate_stage'
local ticket = stage .. '\\dll-handoff.ini'
local marker = stage .. '\\dll-handoff.active'
local payload = stage .. '\\dll-handoff-payload.dll'
local original = stage .. '\\dll-handoff-original.dll'
local recovering = exists(marker)
local raw = readFile(recovering and marker or ticket)
local fields = ticketFields(raw)
local name = fields.PluginName
local live = plugins .. '\\' .. fields.DestinationName
local temporary = live .. '.handoff.tmp'
local sidecar = live .. '.handoff-old.tmp'
local backup = root .. '\\webupdate_backup\\' .. fields.ProfileID ..
    '\\dll\\' .. name .. '\\' .. fields.CommitSHA .. '\\' .. fields.DestinationName
local hadOld = fields.OldPresent == '1'
if triuneRunning() == nil then
    fail('MacroQuest Lua process status is unavailable; refusing DLL handoff.')
end
if not exists(payload) then fail('Prepared DLL payload is missing.') end
if hadOld and (not exists(original) or not equalFiles(original, backup)) then
    fail('Verified original DLL backup is unavailable.')
end

local function cleanupStaged()
    for _, path in ipairs({ ticket, payload, original }) do
        if exists(path) and not os.remove(path) then
            print('[MQ2WebUpdate] Warning: verified handoff completed, but a staged file remains: ' .. path)
        end
    end
end

local function restartTriuneIfNeeded()
    if fields.TriuneWasRunning == '1' and not triuneRunning() then
        mq.cmd('/lua run triune')
        if not awaitTriune(true, 15000) then
            fail('Triune did not restart; recovery marker retained.')
        end
    end
end

local function rollback()
    if loaded(name) then
        mq.cmd('/plugin ' .. name .. ' unload noauto')
        if not awaitLoaded(name, false, 10000) then
            fail('DLL stayed loaded during rollback; recovery marker retained.')
        end
    end
    if exists(live) and not ((hadOld and equalFiles(live, original)) or
        equalFiles(live, payload)) then
        fail('Installed DLL differs from both verified versions; manual recovery required.')
    end
    if exists(live) and not (hadOld and equalFiles(live, original)) then
        if not os.remove(live) then fail('Could not remove new DLL for rollback.') end
    end
    if hadOld and not exists(live) then
        if exists(sidecar) then
            if not equalFiles(sidecar, original) then fail('Rollback sidecar changed.') end
            if not os.rename(sidecar, live) then fail('Could not restore old DLL.') end
        else
            copyFile(backup, live)
        end
    end
    if hadOld and not equalFiles(live, original) then
        fail('Restored DLL does not match the verified original.')
    end
    if exists(sidecar) then
        if not equalFiles(sidecar, original) then fail('Unexpected old DLL sidecar.') end
        if not os.remove(sidecar) then fail('Could not clear old DLL sidecar.') end
    end
    if fields.WasLoaded == '1' and hadOld then
        mq.cmd('/plugin ' .. name .. ' load noauto')
        if not awaitLoaded(name, true, 15000) then
            fail('Original DLL restored but did not reload; marker retained.')
        end
    end
    if exists(temporary) then
        if not equalFiles(temporary, payload) then fail('Unexpected DLL temporary file.') end
        if not os.remove(temporary) then fail('Could not clear DLL temporary file.') end
    end
    restartTriuneIfNeeded()
    if not os.remove(marker) then fail('Could not clear DLL recovery marker.') end
    cleanupStaged()
    print('[MQ2WebUpdate] DLL handoff rolled back to the verified previous state.')
end

if recovering then
    if (fields.WasLoaded ~= '0' and fields.WasLoaded ~= '1') or
        (fields.TriuneWasRunning ~= '0' and fields.TriuneWasRunning ~= '1') then
        fail('Recovery marker lacks the original runtime state.')
    end
    rollback()
    return
end

if exists(temporary) or exists(sidecar) then
    fail('DLL handoff has unresolved temporary files.')
end
local prepared = readFile(payload)
if not prepared or #prepared ~= tonumber(fields.ExpectedSize) then
    fail('Verified DLL payload size changed after staging.')
end
prepared = nil
if hadOld and not equalFiles(live, original) then
    fail('Installed DLL changed after backend verification.')
end
if not hadOld and exists(live) then fail('New DLL destination is occupied.') end
fields.WasLoaded = loaded(name) and '1' or '0'
if not hadOld and fields.WasLoaded == '1' then fail('New plugin is already loaded.') end
fields.TriuneWasRunning = triuneRunning() and '1' or '0'
copyFile(payload, temporary)
local markerFile = io.open(marker, 'wb')
if not markerFile then fail('Could not create durable DLL recovery marker.') end
if not markerFile:write(raw, 'WasLoaded=', fields.WasLoaded, '\n',
        'TriuneWasRunning=', fields.TriuneWasRunning, '\n') or
    not markerFile:close() then
    fail('Could not write durable DLL recovery marker.')
end

if fields.TriuneWasRunning == '1' then
    mq.cmd('/lua stop triune')
    if not awaitTriune(false, 15000) then
        rollback()
        fail('Triune did not stop; previous state restored.')
    end
end
if fields.WasLoaded == '1' then
    mq.cmd('/plugin ' .. name .. ' unload noauto')
    if not awaitLoaded(name, false, 10000) then
        rollback()
        fail('Plugin did not unload; previous state restored.')
    end
end

if hadOld then
    local elapsed = 0
    while not os.rename(live, sidecar) do
        if elapsed >= 10000 then
            rollback()
            fail('Old DLL remained locked; previous state restored.')
        end
        mq.delay(100)
        elapsed = elapsed + 100
    end
    if not equalFiles(sidecar, original) then
        rollback()
        fail('Old DLL changed while unloading.')
    end
end
if not os.rename(temporary, live) or not equalFiles(live, payload) then
    rollback()
    fail('DLL replacement failed; previous state restored.')
end
if fields.WasLoaded == '1' then
    mq.cmd('/plugin ' .. name .. ' load noauto')
    if not awaitLoaded(name, true, 15000) then
        rollback()
        fail('New DLL did not reload; previous state restored.')
    end
end
if hadOld then
    if not equalFiles(sidecar, original) or not os.remove(sidecar) then
        fail('Old DLL sidecar could not be cleared; recovery marker retained.')
    end
end
restartTriuneIfNeeded()
if not os.remove(marker) then fail('Could not clear DLL recovery marker.') end
cleanupStaged()
print('[MQ2WebUpdate] ' .. name .. ' DLL installed and verified' ..
    (fields.WasLoaded == '1' and ', then reloaded.' or ' (was not previously loaded).'))
