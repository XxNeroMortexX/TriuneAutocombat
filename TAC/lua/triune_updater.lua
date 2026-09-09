local mq = require('mq')

-- ============================================================================
-- TriuneAutocombat Update & Restart Controller
--
-- Runs separately from triune.lua so Triune can safely stop while staged
-- files are applied.
-- ============================================================================

local updaterName = 'triune_updater'

local function log(message)
    print('\at[Triune Updater]\ax ' .. tostring(message))
end

local function logGood(message)
    print('\ag[Triune Updater]\ax ' .. tostring(message))
end

local function logWarn(message)
    print('\ay[Triune Updater]\ax ' .. tostring(message))
end

local function logError(message)
    print('\ar[Triune Updater]\ax ' .. tostring(message))
end

local function webValue(fn, fallback)
    local ok, value = pcall(fn)

    if not ok or value == nil then
        return fallback
    end

    return value
end

local function pluginLoaded()
    local ok, loaded = pcall(function()
        return mq.TLO.Plugin('MQ2WebUpdate').IsLoaded()
    end)

    return ok and loaded == true
end

local function getWebStatus()
    return tostring(webValue(function()
        return mq.TLO.WebUpdate.Status()
    end, 'Unknown'))
end

local function getWebError()
    return tostring(webValue(function()
        return mq.TLO.WebUpdate.LastError()
    end, ''))
end

local function getRemoteSHA()
    return tostring(webValue(function()
        return mq.TLO.WebUpdate.RemoteSHA()
    end, ''))
end

local function splitCSV(value)
    local result = {}

    value = tostring(value or '')

    for part in value:gmatch('[^,]+') do
        part = part:match('^%s*(.-)%s*$')

        if part ~= '' then
            result[#result + 1] = part
        end
    end

    return result
end

local function quoteArgument(value)
    value = tostring(value or '')

    if value == '' then
        return ''
    end

    -- Preserve an already-complete argument string exactly as MQ reported it.
    return value
end

local function isTriuneScript(name, path)
    name = tostring(name or ''):lower()
    path = tostring(path or ''):lower():gsub('\\', '/')

    if name == updaterName then
        return false
    end

    -- All scripts belonging to this updater-managed package are named
    -- triune or triune_* and/or live as triune*.lua.
    if name == 'triune' or name:match('^triune_') then
        return true
    end

    local fileName = path:match('([^/]+)$') or ''

    if fileName == 'triune.lua' or fileName:match('^triune_.*%.lua$') then
        return fileName ~= 'triune_updater.lua'
    end

    return false
end

local function captureRunningTriuneScripts()
    local captured = {}

    local pidText = webValue(function()
        return mq.TLO.Lua.PIDs()
    end, '')

    for _, pidTextValue in ipairs(splitCSV(pidText)) do
        local pid = tonumber(pidTextValue)

        if pid then
            local name = tostring(webValue(function()
                return mq.TLO.Lua.Script(pid).Name()
            end, ''))

            local path = tostring(webValue(function()
                return mq.TLO.Lua.Script(pid).Path()
            end, ''))

            local arguments = tostring(webValue(function()
                return mq.TLO.Lua.Script(pid).Arguments()
            end, ''))

            local status = tostring(webValue(function()
                return mq.TLO.Lua.Script(pid).Status()
            end, ''))

            if status:upper() == 'RUNNING' and isTriuneScript(name, path) then
                captured[#captured + 1] = {
                    pid = pid,
                    name = name,
                    path = path,
                    arguments = arguments
                }
            end
        end
    end

    return captured
end

local function scriptStillRunning(pid)
    local status = tostring(webValue(function()
        return mq.TLO.Lua.Script(pid).Status()
    end, ''))

    return status:upper() == 'RUNNING'
end

local function stopScripts(scripts)
    log(string.format(
        'Stopping %d running Triune Lua module(s)...',
        #scripts
    ))

    for _, script in ipairs(scripts) do
        log(string.format(
            'Stopping %s (PID %d)',
            script.name,
            script.pid
        ))

        mq.cmdf('/lua stop %d', script.pid)
        mq.delay(100)
    end

    local timeoutAt = os.clock() + 10.0

    while os.clock() < timeoutAt do
        local anyRunning = false

        for _, script in ipairs(scripts) do
            if scriptStillRunning(script.pid) then
                anyRunning = true
                break
            end
        end

        if not anyRunning then
            logGood('Triune Lua modules stopped.')
            return true
        end

        mq.delay(100)
    end

    for _, script in ipairs(scripts) do
        if scriptStillRunning(script.pid) then
            logError(string.format(
                'Could not stop %s (PID %d).',
                script.name,
                script.pid
            ))

            return false
        end
    end

    return true
end

local function restartScripts(scripts)
    if #scripts == 0 then
        logWarn('No Triune Lua modules were captured for restart.')
        return
    end

    log(string.format(
        'Restarting %d Triune Lua module(s)...',
        #scripts
    ))

    -- Reverse stop order is unnecessary here. Preserve original PID-list
    -- ordering so startup behavior is deterministic.
    for _, script in ipairs(scripts) do
        local command =
            '/lua run ' .. script.name

        local args =
            quoteArgument(script.arguments)

        if args ~= '' then
            command =
                command .. ' ' .. args
        end

        log('Starting ' .. script.name)

        mq.cmd(command)
        mq.delay(250)
    end

    logGood('Restart commands complete.')
end

local function waitForApplyResult()
    local timeoutAt =
        os.clock() + 30.0

    while os.clock() < timeoutAt do
        local status =
            getWebStatus()

        if status == 'Applied' or
           status == 'Up To Date' then
            return true, status
        end

        if status == 'Apply Error' or
           status == 'Error' then
            return false, status
        end

        mq.delay(100)
    end

    return false, 'Timed Out'
end

-- ============================================================================
-- Main
-- ============================================================================

log('Starting safe Update & Restart transaction.')

if not pluginLoaded() then
    logError('MQ2WebUpdate is not loaded.')
    return
end

local initialStatus =
    getWebStatus()

if initialStatus ~= 'Staged' then
    if initialStatus == 'Up To Date' then
        logGood('Everything is already up to date.')
    else
        logError(
            'Expected updater status Staged, got: ' ..
            initialStatus
        )

        local err = getWebError()

        if err ~= '' then
            logError(err)
        end
    end

    return
end

local sha =
    getRemoteSHA()

log('Staged commit: ' .. sha)

local runningScripts =
    captureRunningTriuneScripts()

log(string.format(
    'Remembered %d running Triune Lua module(s).',
    #runningScripts
))

for _, script in ipairs(runningScripts) do
    log(string.format(
        'Remembered: %s (PID %d)%s',
        script.name,
        script.pid,
        script.arguments ~= '' and
            (' args=' .. script.arguments) or
            ''
    ))
end

if #runningScripts == 0 then
    logError(
        'No running Triune Lua modules were found. ' ..
        'Refusing to apply because there would be nothing to restart.'
    )

    return
end

if not stopScripts(runningScripts) then
    logError(
        'Update aborted because a Triune module did not stop.'
    )

    return
end

-- Give Lua shutdown cleanup/save operations a moment to finish.
mq.delay(500)

log('Applying staged update...')
mq.cmd('/webupdate apply')

local applied, finalStatus =
    waitForApplyResult()

if not applied then
    logError(
        'Apply failed. Status: ' ..
        tostring(finalStatus)
    )

    local err =
        getWebError()

    if err ~= '' then
        logError(err)
    end

    logWarn(
        'Attempting to restart the previously running Triune modules.'
    )

    restartScripts(runningScripts)
    return
end

logGood(
    'Update applied successfully. Status: ' ..
    tostring(finalStatus)
)

restartScripts(runningScripts)

logGood('Update & Restart complete.')

