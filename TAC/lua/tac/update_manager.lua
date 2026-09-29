-- Created by: NeroMorte - Production MQ2WebUpdate Lua/ImGui frontend.
-- NeroMorte-owned file.
-- Uses the MQ2WebUpdate 4.0 TLO API and v4.0.0 persistent settings commands.

local plugin = {
    id = 'update_manager', name = 'Update Manager', author = 'NeroMorte',
    description = 'Production update planning, staging, apply, policy, and diagnostics frontend.',
    version = '4.1.4',
    window = {
        label = 'Updates', tooltip = 'Open the MQ2WebUpdate Update Manager.',
        flag = 'show_update_manager', desc = 'Check, stage, apply, and diagnose updates',
        headerButton = true, order = 115,
    },
}

local core, ctrl, ImGui, mq
local updateConfig, morteVersion
local commandEncode
local state = {
    initialized = false, configLoaded = false, versionLoaded = false,
    configError = nil, versionError = nil, pendingApply = false,
    refreshAfterApply = false, applyRefreshStarted = 0,
    restartTriuneAfterApply = false,
    pendingDllApply = false, launchDllCoordinator = false, dllMappingId = nil,
    dllPluginName = nil, dllRecoveryStarted = 0,
    pendingProfile = nil,
    selectedManagedProfile = nil, selectedManagedMapping = nil,
    profileDraft = nil, mappingDraft = nil,
    pendingDeleteProfile = nil, pendingDeleteMapping = nil,
    pendingProfileImport = false,
    startupPhase = 'waiting', startupQueue = {}, startupIndex = 0,
    startupCurrent = nil, startupSawBusy = false, startupLastPoll = 0,
    startupPopupItems = {}, showStartupPopup = false,
    globalGitHubCredential = '',
    actionLog = {}, lastPhase = '', lastStatus = '',
}

local C = {
    green = { 0.20, 0.95, 0.35, 1.0 }, yellow = { 1.00, 0.70, 0.20, 1.0 },
    red = { 1.00, 0.35, 0.35, 1.0 }, blue = { 0.30, 0.85, 1.00, 1.0 },
    gray = { 0.65, 0.65, 0.65, 1.0 },
}

local function colorText(color, text)
    ImGui.TextColored(color[1], color[2], color[3], color[4], tostring(text))
end

local function safeRequire(name)
    local ok, result = pcall(require, name)
    if ok then return result, nil end
    return nil, tostring(result)
end

local function loadMetadata()
    updateConfig, state.configError = safeRequire('TAC_support_modules.update_config')
    morteVersion, state.versionError = safeRequire('TAC_support_modules.morte_version')
    state.configLoaded = type(updateConfig) == 'table'
    state.versionLoaded = type(morteVersion) == 'table'
end

local function addLog(message)
    state.actionLog[#state.actionLog + 1] = os.date('%H:%M:%S') .. '  ' .. tostring(message)
    while #state.actionLog > 100 do table.remove(state.actionLog, 1) end
end

local function runCommand(command, description)
    if not mq or not mq.cmd then
        addLog('ERROR: MacroQuest command API is unavailable.')
        return false
    end
    local ok, err = pcall(mq.cmd, command)
    if not ok then
        addLog('ERROR: ' .. tostring(err))
        return false
    end
    addLog(description or command)
    return true
end

local function dllRecoveryMarkerPath()
    local ok, path = pcall(function()
        local plugins = tostring(mq.TLO.MacroQuest.Path('plugins') or ''):gsub('[\\/]+$', '')
        local root = plugins:match('^(.*)[\\/][^\\/]+$')
        return root and root .. '\\webupdate_stage\\dll-handoff.active'
    end)
    return ok and path or nil
end

local function readEngine()
    local e = {
        available = false, version = '', apiVersion = '', status = '', phase = '',
        busy = false, progress = 0, stageReady = false, restartRequired = false,
        profile = '', profileCount = 0, activeProfile = '', sourceType = '',
        repository = '', branch = '', remoteSHA = '', upstreamSHA = '',
        upstreamStatus = '', upstreamLastError = '', lastError = '', files = {},
        fileCount = 0, sameCount = 0, updateCount = 0, missingCount = 0,
        protectedCount = 0, errorCount = 0, updateAvailable = false, error = nil,
        configurationLoaded = false, configurationPath = '', profiles = {},
        configurationError = '', autoCheckOnLoad = false,
        autoUpstreamOnLoad = false, autoMonitorOnLoad = false,
        autoCheckIntervalMinutes = 0,
        networkTimeoutSeconds = 15, networkRetryCount = 2,
        profileTransferPath = '', diagnosticsPath = '',
        managedProfiles = {}, profileStorePath = '', profileStoreError = '',
        globalGitHubCredentialStored = false,
        repositoryTree = {},
    }

    if not mq or not mq.TLO or not mq.TLO.WebUpdate then
        e.error = 'WebUpdate TLO is unavailable. Load MQ2WebUpdate first.'
        return e
    end

    local ok, err = pcall(function()
        local web = mq.TLO.WebUpdate
        e.version = web.Version() or ''
        e.apiVersion = web.ApiVersion() or ''
        e.status = web.Status() or ''
        e.phase = web.Phase() or ''
        e.busy = web.Busy() and true or false
        e.progress = tonumber(web.Progress()) or 0
        e.stageReady = web.StageReady() and true or false
        e.restartRequired = web.RestartRequired() and true or false
        e.profile = web.Profile() or ''
        e.profileCount = tonumber(web.ProfileCount()) or 0
        e.activeProfile = web.ActiveProfile() or ''
        e.sourceType = web.SourceType() or ''
        e.configurationLoaded = web.ConfigurationLoaded() and true or false
        e.configurationPath = web.ConfigurationPath() or ''
        e.configurationError = web.ConfigurationError() or ''
        e.autoCheckOnLoad = web.AutoCheckOnLoad() and true or false
        e.autoUpstreamOnLoad = web.AutoUpstreamOnLoad() and true or false
        e.autoMonitorOnLoad = web.AutoMonitorOnLoad() and true or false
        e.autoCheckIntervalMinutes = tonumber(web.AutoCheckIntervalMinutes()) or 0
        e.networkTimeoutSeconds = tonumber(web.NetworkTimeoutSeconds()) or 15
        e.networkRetryCount = tonumber(web.NetworkRetryCount()) or 2
        e.profileTransferPath = web.ProfileTransferPath() or ''
        e.diagnosticsPath = web.DiagnosticsPath() or ''
        e.globalGitHubCredentialStored =
            web.GlobalGitHubCredentialStored() and true or false
        e.profileStorePath = web.ProfileStorePath() or ''
        e.profileStoreError = web.ProfileStoreError() or ''
        local managedCount = tonumber(web.ManagedProfileCount()) or 0
        for i = 1, managedCount do
            local profile = web.ManagedProfile(i)
            if profile then
                local item = {
                    id = profile.ID() or '', name = profile.Name() or '',
                    role = profile.Role() or '', enabled = profile.Enabled() and true or false,
                    provider = profile.Provider() or 'github',
                    privateRepository = profile.Private() and true or false,
                    credentialStored = profile.CredentialStored() and true or false,
                    owner = profile.Owner() or '', repository = profile.Repository() or '',
                    reference = profile.Reference() or '', channel = profile.Channel() or '',
                    monitorStatus = profile.MonitorStatus() or 'Not Checked',
                    monitorSHA = profile.MonitorSHA() or '',
                    monitorError = profile.MonitorError() or '',
                    monitorLastChecked = profile.MonitorLastChecked() or '',
                    monitorOnStartup = profile.MonitorOnStartup() and true or false,
                    monitorIntervalMinutes = tonumber(profile.MonitorIntervalMinutes()) or 0,
                    notificationsEnabled = profile.NotificationsEnabled() and true or false,
                    acknowledgedSHA = profile.AcknowledgedSHA() or '',
                    planStatus = profile.PlanStatus() or 'Not Checked',
                    planSHA = profile.PlanSHA() or '',
                    planError = profile.PlanError() or '',
                    planLastChecked = profile.PlanLastChecked() or '',
                    planFileCount = tonumber(profile.PlanFileCount()) or 0,
                    planSameCount = tonumber(profile.PlanSameCount()) or 0,
                    planUpdateCount = tonumber(profile.PlanUpdateCount()) or 0,
                    planMissingCount = tonumber(profile.PlanMissingCount()) or 0,
                    planProtectedCount = tonumber(profile.PlanProtectedCount()) or 0,
                    planErrorCount = tonumber(profile.PlanErrorCount()) or 0,
                    planUpdateAvailable = profile.PlanUpdateAvailable() and true or false,
                    planFiles = {},
                    mappings = {},
                }
                local mappingCount = tonumber(profile.MappingCount()) or 0
                for mappingIndex = 1, mappingCount do
                    local mapping = profile.Mapping(mappingIndex)
                    if mapping then
                        item.mappings[#item.mappings + 1] = {
                            id = mapping.ID() or '', name = mapping.Name() or '',
                            enabled = mapping.Enabled() and true or false,
                            recursive = mapping.Recursive() and true or false,
                            required = mapping.Required() and true or false,
                            restartRequired = mapping.RestartRequired() and true or false,
                            remotePath = mapping.RemotePath() or '',
                            destinationRoot = mapping.DestinationRoot() or '',
                            destinationPath = mapping.DestinationPath() or '',
                            includePatterns = mapping.IncludePatterns() or '',
                            excludePatterns = mapping.ExcludePatterns() or '',
                            maximumFileBytes = mapping.MaximumFileBytes() or '',
                        }
                    end
                end
                for fileIndex = 1, item.planFileCount do
                    local file = profile.PlanFile(fileIndex)
                    if file then
                        item.planFiles[#item.planFiles + 1] = {
                            name = file.Name() or '', repoPath = file.RepoPath() or '',
                            sourcePath = file.SourcePath() or '',
                            destinationPath = file.DestinationPath() or '',
                            mappingId = file.MappingID() or '',
                            mappingRelativePath = file.MappingRelativePath() or '',
                            error = file.Error() or '', status = file.Status() or '',
                            protection = file.Protection() or '',
                        }
                    end
                end
                e.managedProfiles[#e.managedProfiles + 1] = item
            end
        end
        e.repository = web.Repository() or ''
        e.branch = web.Branch() or ''
        e.remoteSHA = web.RemoteSHA() or ''
        e.upstreamSHA = web.UpstreamSHA() or ''
        e.upstreamStatus = web.UpstreamStatus() or ''
        e.upstreamLastError = web.UpstreamLastError() or ''
        e.lastError = web.LastError() or ''
        e.fileCount = tonumber(web.FileCount()) or 0
        local treeCount = tonumber(web.TreeFileCount()) or 0
        for i = 1, treeCount do
            local treeFile = web.TreeFile(i)
            if treeFile then
                e.repositoryTree[#e.repositoryTree + 1] = {
                    mappingId = treeFile.MappingID() or '',
                    repositoryPath = treeFile.RepositoryPath() or '',
                    relativePath = treeFile.RelativePath() or '',
                    size = tonumber(treeFile.Size()) or 0,
                    selected = treeFile.Selected() and true or false,
                }
            end
        end
        e.sameCount = tonumber(web.SameCount()) or 0
        e.updateCount = tonumber(web.UpdateCount()) or 0
        e.missingCount = tonumber(web.MissingCount()) or 0
        e.protectedCount = tonumber(web.ProtectedCount()) or 0
        e.errorCount = tonumber(web.ErrorCount()) or 0
        e.updateAvailable = web.UpdateAvailable() and true or false
        for i = 1, e.profileCount do
            local profile = web.Profile(i)
            if profile then
                e.profiles[#e.profiles + 1] = {
                    id = profile.ID() or '', name = profile.Name() or '',
                    sourceType = profile.SourceType() or '',
                    repository = profile.Repository() or '', branch = profile.Branch() or '',
                }
            end
        end
        for i = 1, e.fileCount do
            local file = web.File(i)
            if file then
                e.files[#e.files + 1] = {
                    name = file.Name() or '', repoPath = file.RepoPath() or '',
                    sourcePath = file.SourcePath() or '', destinationPath = file.DestinationPath() or '',
                    mappingId = file.MappingID() or '',
                    mappingRelativePath = file.MappingRelativePath() or '',
                    error = file.Error() or '', status = file.Status() or '',
                    protection = file.Protection() or '',
                }
            end
        end
        e.available = true
    end)

    if not ok then e.error = tostring(err); return e end
    if e.phase ~= state.lastPhase or e.status ~= state.lastStatus then
        if state.lastPhase ~= '' or state.lastStatus ~= '' then
            addLog(string.format('Backend: %s / %s', e.phase, e.status))
        end
        state.lastPhase, state.lastStatus = e.phase, e.status
    end
    return e
end

local function textValue(label, value)
    ImGui.TextDisabled(label .. ':')
    ImGui.SameLine()
    ImGui.Text(tostring(value or 'Unknown'))
end

local function yesNo(value) return value and 'Yes' or 'No' end
local function beginDisabled(value) if value then ImGui.BeginDisabled() end end
local function endDisabled(value) if value then ImGui.EndDisabled() end end

local function statusText(status)
    local normalized = string.upper(status or '')
    local color = C.gray
    if normalized == 'SAME' or normalized == 'PROTECTED' or normalized == 'LINK PROTECTED' then
        color = C.green
    elseif normalized == 'UPDATE' or normalized == 'MISSING' or normalized == 'NEW FILE' then
        color = C.yellow
    elseif normalized == 'ERROR' or normalized == 'UNKNOWN' then
        color = C.red
    end
    colorText(color, status)
end

local function unavailable(engine)
    colorText(C.red, engine.error or 'MQ2WebUpdate is unavailable.')
    ImGui.TextWrapped('Load MQ2WebUpdate, then reopen this window.')
end

local function drawSummary(e)
    colorText(C.blue, 'MQ2WebUpdate Production Engine')
    ImGui.Separator()
    ImGui.Text(string.format('Engine %s  |  API %s  |  Profile %s',
        e.version, e.apiVersion, e.activeProfile ~= '' and e.activeProfile or '<none>'))
    ImGui.Text(string.format('Status: %s  |  Phase: %s  |  Progress: %d%%', e.status, e.phase, e.progress))
    ImGui.Text(string.format('Repository: %s  |  Branch: %s', e.repository, e.branch))
    ImGui.Text(string.format('Stage Ready: %s  |  Restart Required: %s',
        yesNo(e.stageReady), yesNo(e.restartRequired)))
    if e.remoteSHA ~= '' then ImGui.TextWrapped('Remote SHA: ' .. e.remoteSHA)
    else ImGui.TextDisabled('Remote SHA: not checked') end
    if e.lastError ~= '' then colorText(C.red, 'Last Error:'); ImGui.TextWrapped(e.lastError) end
end

local function drawActions(e)
    ImGui.Spacing(); ImGui.Separator(); ImGui.Text('Update Actions')
    local disabled = not e.available or e.busy
    beginDisabled(disabled)
    if ImGui.Button('Check for Updates', core.px(145), core.px(26)) then
        state.pendingApply = false
        state.refreshAfterApply = false
        state.restartTriuneAfterApply = false
        runCommand('/webupdate compare', 'Started read-only update comparison.')
    end
    ImGui.SameLine()
    if ImGui.Button('Stage Updates', core.px(125), core.px(26)) then
        state.pendingApply = false
        state.refreshAfterApply = false
        state.restartTriuneAfterApply = false
        runCommand('/webupdate stage', 'Started verified update staging.')
    end
    endDisabled(disabled)
    ImGui.SameLine()
    if ImGui.Button('Status to Chat', core.px(115), core.px(26)) then
        runCommand('/webupdate status', 'Printed backend status to chat.')
    end

    local dllStaged = false
    local function stagedPluginName(file)
        local destination = tostring(file.destinationPath or '')
        local name = destination:match('[\\/]plugins[\\/]([%w_-]+)%.dll$')
        if not name then return nil end
        for _, profile in ipairs(e.managedProfiles or {}) do
            if profile.role == 'main' then
                for _, mapping in ipairs(profile.mappings or {}) do
                    if mapping.id == file.mappingId and
                        mapping.destinationRoot == 'plugins' then
                        return name
                    end
                end
            end
        end
        return nil
    end
    for _, file in ipairs(e.files or {}) do
        local status = string.upper(tostring(file.status or ''))
        if stagedPluginName(file) and
            (status == 'UPDATE' or status == 'MISSING') then
            dllStaged = true
        end
    end
    local applyDisabled = not e.available or e.busy or not e.stageReady or dllStaged
    beginDisabled(applyDisabled)
    if ImGui.Button('Apply Staged Files', core.px(145), core.px(26)) then
        state.pendingApply = true
        addLog('Apply confirmation requested.')
    end
    endDisabled(applyDisabled)
    if applyDisabled and not dllStaged then
        ImGui.SameLine(); ImGui.TextDisabled('A verified staged transaction is required.')
    end
    if dllStaged then
        ImGui.SameLine()
        ImGui.TextDisabled('DLL requires the independent handoff.')
        beginDisabled(not e.stageReady or e.busy)
        for _, file in ipairs(e.files or {}) do
            local status = string.upper(tostring(file.status or ''))
            local name = stagedPluginName(file)
            if name and tostring(file.mappingId or ''):match('^[%w_-]+$') and
                (status == 'UPDATE' or status == 'MISSING') and
                not tostring(file.protection or ''):upper():find('PROTECTED', 1, true) then
                if ImGui.Button('Update ' .. name .. '##dll_' .. file.mappingId,
                    core.px(175), core.px(26)) then
                    state.pendingDllApply = true
                    state.dllMappingId = file.mappingId
                    state.dllPluginName = name
                end
            end
        end
        endDisabled(not e.stageReady or e.busy)
    end

    if state.pendingDllApply then
        ImGui.Spacing(); ImGui.Separator(); colorText(C.yellow, 'Confirm DLL Update')
        ImGui.TextWrapped('Update ' .. tostring(state.dllPluginName) .. ' from its verified staged file, with backup and rollback. Other staged files will need a fresh Stage afterward.')
        if ImGui.Button('Yes, Update DLL', core.px(145), core.px(26)) then
            state.pendingDllApply = false
            local sent = runCommand('/webupdate dll prepare ' .. state.dllMappingId,
                'Requested verified DLL handoff preparation.')
            local verified = sent and readEngine()
            state.launchDllCoordinator = verified and verified.lastError == '' or false
            if not state.launchDllCoordinator then
                addLog('DLL handoff preparation failed; plugin remains installed.')
            end
        end
        ImGui.SameLine()
        if ImGui.Button('Cancel DLL Update', core.px(145), core.px(26)) then
            state.pendingDllApply = false
        end
        ImGui.Separator()
    end

    if state.pendingApply then
        ImGui.Spacing(); ImGui.Separator(); colorText(C.yellow, 'Confirm Apply')
        ImGui.TextWrapped('Apply the verified staged transaction now? MQ2WebUpdate will back up, verify, commit, and roll back on failure. Link-protected files will not be overwritten.')
        if ImGui.Button('Yes, Apply Now', core.px(135), core.px(26)) then
            state.pendingApply = false
            state.restartTriuneAfterApply = false
            for _, file in ipairs(e.files or {}) do
                local status = string.upper(tostring(file.status or ''))
                local protection = string.upper(tostring(file.protection or ''))
                local destination = string.lower(tostring(file.destinationPath or ''))
                if (status == 'UPDATE' or status == 'MISSING') and
                    not protection:find('PROTECTED', 1, true) and
                    destination:match('%.lua$') then
                    state.restartTriuneAfterApply = true
                    break
                end
            end
            state.refreshAfterApply = runCommand('/webupdate apply',
                'Requested staged transaction apply.')
            if not state.refreshAfterApply then state.restartTriuneAfterApply = false end
            state.applyRefreshStarted = os.time()
        end
        ImGui.SameLine()
        if ImGui.Button('Cancel Apply', core.px(110), core.px(26)) then
            state.pendingApply = false
            addLog('Apply cancelled by user.')
        end
        ImGui.Separator()
    end
    if e.busy then colorText(C.blue, string.format('Operation in progress: %d%%', e.progress)) end
end

local function drawFilePlan(e)
    ImGui.Spacing(); ImGui.Separator()
    ImGui.Text(string.format('File Plan  |  Total %d  Same %d  Update %d  New %d  Protected %d  Errors %d',
        e.fileCount, e.sameCount, e.updateCount, e.missingCount, e.protectedCount, e.errorCount))
    if #e.files == 0 then
        ImGui.TextDisabled('Run Check for Updates or Stage Updates to build a file plan.')
        return
    end
    local mainProfileId = ''
    for _, profile in ipairs(e.managedProfiles or {}) do
        if profile.enabled and profile.role == 'main' then mainProfileId = profile.id; break end
    end
    if ImGui.BeginTable('##ProductionUpdateFilePlan', 7,
        ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
        ImGui.TableSetupColumn('File', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Status', ImGuiTableColumnFlags.WidthFixed, core.px(95))
        ImGui.TableSetupColumn('Protection', ImGuiTableColumnFlags.WidthFixed, core.px(115))
        ImGui.TableSetupColumn('Remote Source', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Local Destination', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Error', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Selection', ImGuiTableColumnFlags.WidthFixed, core.px(95))
        ImGui.TableHeadersRow()
        for _, file in ipairs(e.files) do
            local normalizedStatus = string.upper(file.status or '')
            local protected = file.protection ~= ''
            local visible = true
            if ctrl.update_show_same == false and normalizedStatus == 'SAME' then visible = false end
            if ctrl.update_show_protected == false and protected then visible = false end
            if ctrl.update_changes_only == true and
                normalizedStatus ~= 'UPDATE' and normalizedStatus ~= 'MISSING' and
                normalizedStatus ~= 'ERROR' then visible = false end
            if visible then
            local status = file.status
            if string.upper(status) == 'MISSING' then status = 'New File' end
            ImGui.TableNextRow()
            ImGui.TableSetColumnIndex(0); ImGui.Text(file.name ~= '' and file.name or file.repoPath)
            ImGui.TableSetColumnIndex(1); statusText(status)
            ImGui.TableSetColumnIndex(2)
            if file.protection ~= '' then statusText(file.protection) else ImGui.TextDisabled('-') end
            ImGui.TableSetColumnIndex(3)
            if file.sourcePath ~= '' then ImGui.TextWrapped(file.sourcePath) else ImGui.TextDisabled('-') end
            ImGui.TableSetColumnIndex(4)
            if file.destinationPath ~= '' then ImGui.TextWrapped(file.destinationPath) else ImGui.TextDisabled('-') end
            ImGui.TableSetColumnIndex(5)
            if file.error ~= '' then colorText(C.red, file.error) else ImGui.TextDisabled('-') end
            ImGui.TableSetColumnIndex(6)
            beginDisabled(mainProfileId == '' or file.mappingId == '' or e.busy or e.stageReady)
            if ImGui.Button('Uncheck##file_' .. file.mappingId .. '_' .. file.mappingRelativePath,
                core.px(82), core.px(21)) then
                runCommand(string.format('/webupdate mappings exclude %s %s %s',
                    mainProfileId, file.mappingId, commandEncode(file.mappingRelativePath)),
                    'Unchecked ' .. file.mappingRelativePath .. '. Run Check for Updates to refresh the plan.')
            end
            endDisabled(mainProfileId == '' or file.mappingId == '' or e.busy or e.stageReady)
            end
        end
        ImGui.EndTable()
    end
end

local function toggleButton(label, value, command, description)
    local text = (value and '[X] ' or '[ ] ') .. label .. (value and ' - ON' or ' - OFF')
    if ImGui.Button(text, core.px(285), core.px(25)) then
        runCommand(command .. (value and ' off' or ' on'), description)
    end
end

local inputDraft

local function drawSettingsTab()
    local e = readEngine()
    colorText(C.blue, 'Global Update Settings'); ImGui.Separator()
    if not e.available then unavailable(e); return end

    ImGui.Text('Backend Automation')
    ImGui.TextWrapped('These settings are validated and saved atomically by MQ2WebUpdate. They affect real updater behavior.')
    beginDisabled(e.busy or e.stageReady)
    toggleButton('Check Main Download on load', e.autoCheckOnLoad,
        '/webupdate setting checkonload', 'Changed startup check for the Main Download repository.')
    toggleButton('Check all Monitors on load', e.autoMonitorOnLoad,
        '/webupdate setting monitoronload', 'Changed startup checks for all enabled Monitor Only repositories.')
    toggleButton('Check Gennro when loaded', e.autoUpstreamOnLoad,
        '/webupdate setting upstreamonload', 'Changed startup upstream-check setting.')
    ImGui.TextDisabled('Main and Monitor startup checks are independent. Individual Monitor profiles may also request startup checks when the global Monitor option is off.')
    endDisabled(e.busy or e.stageReady)

    ImGui.Spacing(); ImGui.Text('Scheduled Read-Only Checks')
    textValue('Current interval', e.autoCheckIntervalMinutes == 0 and 'Disabled' or
        (tostring(e.autoCheckIntervalMinutes) .. ' minutes'))
    local intervals = {
        { value = 0, label = 'Off' }, { value = 15, label = '15 min' },
        { value = 60, label = '1 hour' }, { value = 360, label = '6 hours' },
        { value = 1440, label = '24 hours' },
    }
    beginDisabled(e.busy or e.stageReady)
    for index, option in ipairs(intervals) do
        if index > 1 then ImGui.SameLine() end
        beginDisabled(option.value == e.autoCheckIntervalMinutes)
        if ImGui.Button(option.label .. '##interval' .. tostring(option.value), core.px(85), core.px(24)) then
            runCommand('/webupdate setting interval ' .. tostring(option.value),
                'Changed scheduled-check interval to ' .. option.label .. '.')
        end
        endDisabled(option.value == e.autoCheckIntervalMinutes)
    end
    endDisabled(e.busy or e.stageReady)

    ImGui.Spacing(); ImGui.SeparatorText('Global GitHub Authentication')
    ImGui.TextWrapped('Optional for public repositories and used as a fallback for every GitHub profile. The token is stored only in Windows Credential Manager and is never exported.')
    if e.globalGitHubCredentialStored then
        colorText(C.green, 'Global GitHub credential: STORED')
    else
        ImGui.TextDisabled('Global GitHub credential: NOT CONFIGURED')
    end
    inputDraft('Global GitHub Token', state, 'globalGitHubCredential', 380,
        ImGuiInputTextFlags.Password)
    beginDisabled(e.busy or e.stageReady)
    if ImGui.Button('Store / Replace Global Token', core.px(205), core.px(24)) then
        runCommand('/webupdate credential set global ' ..
            commandEncode(state.globalGitHubCredential),
            'Stored the global GitHub credential securely in Windows Credential Manager.')
        state.globalGitHubCredential = ''
    end
    ImGui.SameLine()
    if ImGui.Button('Remove Global Token', core.px(155), core.px(24)) then
        runCommand('/webupdate credential delete global',
            'Removed the global GitHub credential.')
        state.globalGitHubCredential = ''
    end
    endDisabled(e.busy or e.stageReady)

    ImGui.Spacing(); ImGui.Text('GitHub Network Policy')
    ImGui.TextWrapped('These values are enforced by every GitHub API and file-download request. Retries are limited to timeouts, rate limits, and server failures.')
    textValue('Request timeout', tostring(e.networkTimeoutSeconds) .. ' seconds')
    textValue('Retry attempts', tostring(e.networkRetryCount))
    beginDisabled(e.busy or e.stageReady)
    local timeouts = { 5, 15, 30, 60, 120 }
    for index, value in ipairs(timeouts) do
        if index > 1 then ImGui.SameLine() end
        beginDisabled(value == e.networkTimeoutSeconds)
        if ImGui.Button(tostring(value) .. 's##timeout' .. tostring(value), core.px(64), core.px(24)) then
            runCommand('/webupdate setting timeout ' .. tostring(value),
                'Changed GitHub request timeout to ' .. tostring(value) .. ' seconds.')
        end
        endDisabled(value == e.networkTimeoutSeconds)
    end
    ImGui.Text('Retries:')
    for value = 0, 5 do
        if value > 0 then ImGui.SameLine() end
        beginDisabled(value == e.networkRetryCount)
        if ImGui.Button(tostring(value) .. '##retries' .. tostring(value), core.px(44), core.px(24)) then
            runCommand('/webupdate setting retries ' .. tostring(value),
                'Changed GitHub retry count to ' .. tostring(value) .. '.')
        end
        endDisabled(value == e.networkRetryCount)
    end
    endDisabled(e.busy or e.stageReady)

    ImGui.Spacing(); ImGui.Separator(); ImGui.Text('File Plan Display')
    local function localToggle(label, key)
        local enabled = ctrl[key] ~= false
        if key == 'update_changes_only' then enabled = ctrl[key] == true end
        if ImGui.Button(label .. ': ' .. (enabled and 'Shown' or 'Hidden'), core.px(180), core.px(24)) then
            ctrl[key] = not enabled
            core.saveLoadout(true)
            addLog('Changed display preference: ' .. label .. '.')
        end
    end
    localToggle('Unchanged files', 'update_show_same')
    ImGui.SameLine(); localToggle('Protected files', 'update_show_protected')
    ImGui.SameLine(); localToggle('Changes only', 'update_changes_only')

    ImGui.Spacing(); ImGui.Separator(); ImGui.Text('Locked Production Protections')
    colorText(C.green, 'Always enabled: path validation, reparse rejection, SHA-256 verification, staging, backup, rollback, recovery, and apply confirmation.')
    ImGui.TextDisabled('These protections cannot be disabled through the GUI or settings file.')

    ImGui.Spacing(); ImGui.Separator(); ImGui.Text('Configuration Management')
    textValue('Settings file', e.configurationPath)
    textValue('Profile store', e.profileStorePath)
    textValue('Profile transfer file', e.profileTransferPath)
    textValue('Diagnostics file', e.diagnosticsPath)
    if e.configurationError ~= '' then colorText(C.red, e.configurationError) end
    beginDisabled(e.busy or e.stageReady)
    if ImGui.Button('Reset Safe Defaults', core.px(150), core.px(25)) then
        runCommand('/webupdate config reset', 'Requested safe configuration reset.')
    end
    endDisabled(e.busy or e.stageReady)
    ImGui.SameLine()
    if ImGui.Button('Show in Chat', core.px(110), core.px(25)) then
        runCommand('/webupdate config show', 'Printed saved configuration to chat.')
    end
    ImGui.Spacing()
    beginDisabled(e.busy or e.stageReady)
    if ImGui.Button('Export Profiles', core.px(130), core.px(25)) then
        runCommand('/webupdate profiles export', 'Exported repository profiles and mappings without credentials.')
    end
    ImGui.SameLine()
    if ImGui.Button('Import Profiles', core.px(130), core.px(25)) then
        state.pendingProfileImport = true
    end
    endDisabled(e.busy or e.stageReady)
    ImGui.SameLine()
    if ImGui.Button('Export Diagnostics', core.px(145), core.px(25)) then
        runCommand('/webupdate diagnostics export', 'Exported sanitized diagnostics without credentials.')
    end
    ImGui.TextDisabled('Imports are validated as a complete set and published atomically. GitHub tokens are never exported or imported.')
    if state.pendingProfileImport then
        colorText(C.yellow, 'Import replaces the complete repository/profile configuration with the validated transfer file. Continue?')
        beginDisabled(e.busy or e.stageReady)
        if ImGui.Button('Confirm Profile Import', core.px(175), core.px(25)) then
            runCommand('/webupdate profiles import', 'Requested validated profile import from the fixed transfer file.')
            state.pendingProfileImport = false
        end
        ImGui.SameLine()
        if ImGui.Button('Cancel Import', core.px(105), core.px(25)) then
            state.pendingProfileImport = false
        end
        endDisabled(e.busy or e.stageReady)
    end
end

local function drawManagedRepositoryPlan(profile)
    ImGui.Spacing(); ImGui.Separator()
    ImGui.Text(string.format(
        'File Plan  |  Total %d  Same %d  Update %d  New %d  Protected %d  Errors %d',
        profile.planFileCount or 0, profile.planSameCount or 0,
        profile.planUpdateCount or 0, profile.planMissingCount or 0,
        profile.planProtectedCount or 0, profile.planErrorCount or 0))

    if #(profile.planFiles or {}) == 0 then
        if profile.planStatus == 'Checking' then
            colorText(C.blue, 'Repository comparison is running...')
        else
            ImGui.TextDisabled('Run Check Repository to build this repository\'s read-only file plan.')
        end
        return
    end

    local tableId = '##RepositoryPlan_' .. tostring(profile.id)
    if ImGui.BeginTable(tableId, 6,
        ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg +
        ImGuiTableFlags.Resizable + ImGuiTableFlags.ScrollX) then
        ImGui.TableSetupColumn('File', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Status', ImGuiTableColumnFlags.WidthFixed, core.px(95))
        ImGui.TableSetupColumn('Protection', ImGuiTableColumnFlags.WidthFixed, core.px(115))
        ImGui.TableSetupColumn('Remote Source', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Local Destination', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn('Error', ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableHeadersRow()

        for _, file in ipairs(profile.planFiles) do
            local normalizedStatus = string.upper(file.status or '')
            local protected = file.protection ~= ''
            local visible = true
            if ctrl.update_show_same == false and normalizedStatus == 'SAME' then visible = false end
            if ctrl.update_show_protected == false and protected then visible = false end
            if ctrl.update_changes_only == true and
                normalizedStatus ~= 'UPDATE' and normalizedStatus ~= 'MISSING' and
                normalizedStatus ~= 'ERROR' then visible = false end

            if visible then
                local status = file.status
                if string.upper(status or '') == 'MISSING' then status = 'New File' end
                ImGui.TableNextRow()
                ImGui.TableSetColumnIndex(0)
                ImGui.Text(file.name ~= '' and file.name or file.repoPath)
                ImGui.TableSetColumnIndex(1); statusText(status)
                ImGui.TableSetColumnIndex(2)
                if file.protection ~= '' then statusText(file.protection)
                else ImGui.TextDisabled('-') end
                ImGui.TableSetColumnIndex(3)
                if file.sourcePath ~= '' then ImGui.TextWrapped(file.sourcePath)
                else ImGui.TextDisabled('-') end
                ImGui.TableSetColumnIndex(4)
                if file.destinationPath ~= '' then ImGui.TextWrapped(file.destinationPath)
                else ImGui.TextDisabled('-') end
                ImGui.TableSetColumnIndex(5)
                if file.error ~= '' then colorText(C.red, file.error)
                else ImGui.TextDisabled('-') end
            end
        end
        ImGui.EndTable()
    end
end

-- Keep the per-repository file view independent of ImGui tables.  The table
-- renderer can leave an open scope when one of its bindings fails mid-frame.
local function drawRepositoryFileList(e, profile, files, mainDownload)
    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Text(string.format(
        'File Plan  |  Total %d  Same %d  Update %d  New %d  Protected %d  Errors %d',
        mainDownload and e.fileCount or profile.planFileCount,
        mainDownload and e.sameCount or profile.planSameCount,
        mainDownload and e.updateCount or profile.planUpdateCount,
        mainDownload and e.missingCount or profile.planMissingCount,
        mainDownload and e.protectedCount or profile.planProtectedCount,
        mainDownload and e.errorCount or profile.planErrorCount))
    if #files == 0 then
        ImGui.TextDisabled('No file plan yet. Run a repository check to see files.')
        return
    end

    -- Always close a table that opened, including when a binding raises while
    -- drawing a row.  The plain rows below remain available for that session.
    if not state.fileTableUnavailable then
        local tableOpened = false
        local ok, err = pcall(function()
            local flags = ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg
                + ImGuiTableFlags.Resizable + ImGuiTableFlags.ScrollX
                + ImGuiTableFlags.SizingFixedFit
            tableOpened = ImGui.BeginTable('##RepositoryFilePlan_' .. tostring(profile.id),
                mainDownload and 7 or 6, flags)
            if not tableOpened then return end
            ImGui.TableSetupColumn('File', ImGuiTableColumnFlags.WidthFixed, core.px(210))
            ImGui.TableSetupColumn('Status', ImGuiTableColumnFlags.WidthFixed, core.px(100))
            ImGui.TableSetupColumn('Protection', ImGuiTableColumnFlags.WidthFixed, core.px(120))
            ImGui.TableSetupColumn('Remote Source', ImGuiTableColumnFlags.WidthFixed, core.px(220))
            ImGui.TableSetupColumn('Local Destination', ImGuiTableColumnFlags.WidthFixed, core.px(310))
            ImGui.TableSetupColumn('Error', ImGuiTableColumnFlags.WidthFixed, core.px(200))
            if mainDownload then
                ImGui.TableSetupColumn('Selection', ImGuiTableColumnFlags.WidthFixed, core.px(90))
            end
            ImGui.TableHeadersRow()
            for _, file in ipairs(files) do
                local status = tostring(file.status or '')
                local protection = tostring(file.protection or '')
                local normalized = string.upper(status)
                local visible = true
                if ctrl.update_show_same == false and normalized == 'SAME' then visible = false end
                if ctrl.update_show_protected == false and protection ~= '' then visible = false end
                if ctrl.update_changes_only == true and normalized ~= 'UPDATE'
                    and normalized ~= 'MISSING' and normalized ~= 'ERROR' then visible = false end
                if visible then
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    local name = tostring(file.name or '')
                    ImGui.TextWrapped(name ~= '' and name or tostring(file.repoPath or ''))
                    ImGui.TableSetColumnIndex(1)
                    statusText(normalized == 'MISSING' and 'New File' or status)
                    ImGui.TableSetColumnIndex(2)
                    if protection ~= '' then statusText(protection) else ImGui.TextDisabled('-') end
                    ImGui.TableSetColumnIndex(3)
                    ImGui.TextWrapped(file.sourcePath ~= '' and tostring(file.sourcePath or '') or '-')
                    ImGui.TableSetColumnIndex(4)
                    ImGui.TextWrapped(file.destinationPath ~= '' and tostring(file.destinationPath or '') or '-')
                    ImGui.TableSetColumnIndex(5)
                    if file.error and file.error ~= '' then colorText(C.red, file.error)
                    else ImGui.TextDisabled('-') end
                    if mainDownload then
                        ImGui.TableSetColumnIndex(6)
                        local mappingId = tostring(file.mappingId or '')
                        local relativePath = tostring(file.mappingRelativePath or '')
                        if mappingId ~= '' and relativePath ~= '' and not e.busy and not e.stageReady then
                            if ImGui.Button('Uncheck##file_' .. mappingId .. '_' .. relativePath,
                                core.px(82), core.px(21)) then
                                runCommand(string.format('/webupdate mappings exclude %s %s %s',
                                    profile.id, mappingId, commandEncode(relativePath)),
                                    'Unchecked ' .. relativePath .. '. Run Check for Updates to refresh the plan.')
                            end
                        else
                            ImGui.TextDisabled('-')
                        end
                    end
                end
            end
        end)
        if tableOpened then
            local closed, closeError = pcall(ImGui.EndTable)
            if not closed then ok, err = false, closeError end
        end
        if ok then return end
        state.fileTableUnavailable = true
        addLog('File-plan table unavailable: ' .. tostring(err))
        ImGui.TextDisabled('Table unavailable; displaying the same file plan as rows.')
    end

    for _, file in ipairs(files) do
        local status = tostring(file.status or '')
        local protection = tostring(file.protection or '')
        local normalized = string.upper(status)
        local visible = true
        if ctrl.update_show_same == false and normalized == 'SAME' then visible = false end
        if ctrl.update_show_protected == false and protection ~= '' then visible = false end
        if ctrl.update_changes_only == true and normalized ~= 'UPDATE'
            and normalized ~= 'MISSING' and normalized ~= 'ERROR' then visible = false end
        if visible then
            local fileName = tostring(file.name or '')
            if fileName == '' then fileName = tostring(file.repoPath or '') end
            statusText(normalized == 'MISSING' and 'New File' or status)
            ImGui.SameLine()
            ImGui.TextWrapped(fileName)
            if protection ~= '' then ImGui.TextDisabled('Protection: ' .. protection) end
            if file.sourcePath and file.sourcePath ~= '' then
                ImGui.TextWrapped('Remote: ' .. file.sourcePath)
            end
            if file.destinationPath and file.destinationPath ~= '' then
                ImGui.TextWrapped('Local: ' .. file.destinationPath)
            end
            if file.error and file.error ~= '' then colorText(C.red, file.error) end
            local mappingId = tostring(file.mappingId or '')
            local relativePath = tostring(file.mappingRelativePath or '')
            if mainDownload and mappingId ~= '' and relativePath ~= '' then
                local disabled = e.busy or e.stageReady
                beginDisabled(disabled)
                if ImGui.Button('Uncheck##file_' .. mappingId .. '_' .. relativePath,
                    core.px(82), core.px(21)) then
                    runCommand(string.format('/webupdate mappings exclude %s %s %s',
                        profile.id, mappingId, commandEncode(relativePath)),
                        'Unchecked ' .. relativePath .. '. Run Check for Updates to refresh the plan.')
                end
                endDisabled(disabled)
            end
            ImGui.Separator()
        end
    end
end

local function drawManagedRepositoryTab(e, profile)
    if profile.role == 'main' then
        drawSummary(e)
        ImGui.TextDisabled(string.format(
            'Main Download: %s/%s @ %s',
            profile.owner, profile.repository, profile.reference))
        drawActions(e)
        drawRepositoryFileList(e, profile, e.files, true)
        return
    end

    if profile.role == 'monitor' then
        colorText(C.blue, profile.name .. ' - Monitor Only')
    else
        ImGui.TextDisabled(profile.name .. ' - Disabled')
    end
    ImGui.Separator()
    textValue('Repository', profile.owner .. '/' .. profile.repository)
    textValue('Provider', profile.provider == 'github' and 'GitHub' or profile.provider)
    textValue('Reference', profile.reference)
    textValue('Status', profile.planStatus ~= '' and profile.planStatus or 'Not Checked')
    textValue('Last checked', profile.planLastChecked ~= '' and profile.planLastChecked or '<never>')
    textValue('Remote SHA', profile.planSHA ~= '' and profile.planSHA or '<not checked>')
    if profile.planError ~= '' then
        colorText(C.red, 'Last Error:')
        ImGui.TextWrapped(profile.planError)
    end

    if profile.role == 'monitor' then
        beginDisabled(e.busy or not profile.enabled)
        if ImGui.Button('Check Repository##' .. profile.id, core.px(145), core.px(26)) then
            runCommand('/webupdate profiles test ' .. profile.id,
                'Started read-only repository comparison for ' .. profile.name .. '.')
        end
        endDisabled(e.busy or not profile.enabled)
        ImGui.SameLine()
        ImGui.TextDisabled('Monitor Only: staging, downloading, and applying are unavailable.')
    else
        ImGui.TextDisabled('Enable this repository and assign Monitor Only or Main Download to check it.')
    end

    drawRepositoryFileList(e, profile, profile.planFiles, false)
end

local function drawUpdatesTab()
    local e = readEngine()
    if not e.available then unavailable(e); return end

    ImGui.TextWrapped('Each configured repository has an independent status and file plan. Only the Main Download repository can stage or apply files.')
    if #e.managedProfiles == 0 then
        ImGui.TextDisabled('No repository profiles are configured.')
        return
    end

    if ImGui.BeginTabBar('##ManagedRepositoryUpdateTabs') then
        for _, profile in ipairs(e.managedProfiles) do
            local roleTag = profile.role == 'main' and ' [MAIN]'
                or (profile.role == 'monitor' and ' [MONITOR]' or ' [DISABLED]')
            local label = profile.name .. roleTag .. '###repository_update_' .. profile.id
            if ImGui.BeginTabItem(label) then
                drawManagedRepositoryTab(e, profile)
                ImGui.EndTabItem()
            end
        end
        ImGui.EndTabBar()
    end
end

local function sourceLabel(source)
    if type(source) ~= 'table' then return '<unavailable>' end
    return string.format('%s/%s @ %s', source.owner or '?', source.repository or '?', source.ref or '?')
end

local function ensureTriuneRepositoryPreference(profile)
    if type(ctrl.update_repository_startup) ~= 'table' then
        ctrl.update_repository_startup = {}
    end
    local preference = ctrl.update_repository_startup[profile.id]
    local created = false
    if type(preference) ~= 'table' then
        local enabledByDefault = profile.id == 'morte' or profile.id == 'gennro'
        preference = { check = enabledByDefault, popup = enabledByDefault }
        ctrl.update_repository_startup[profile.id] = preference
        created = true
    end
    if preference.check == nil then preference.check = false; created = true end
    if preference.popup == nil then preference.popup = false; created = true end
    return preference, created
end

commandEncode = function(value)
    return (tostring(value or ''):gsub('[^%w%-%_%.]', function(character)
        return string.format('%%%02X', string.byte(character))
    end))
end

local function copyProfileDraft(profile)
    local triunePreference = ensureTriuneRepositoryPreference(profile)
    return {
        id = profile.id, name = profile.name, owner = profile.owner,
        repository = profile.repository, reference = profile.reference,
        channel = profile.channel, role = profile.role,
        enabled = profile.enabled, privateRepository = profile.privateRepository,
        monitorOnStartup = profile.monitorOnStartup,
        monitorIntervalMinutes = tostring(profile.monitorIntervalMinutes or 0),
        notificationsEnabled = profile.notificationsEnabled,
        acknowledgedSHA = profile.acknowledgedSHA or '',
        triuneStartupCheck = triunePreference.check == true,
        triuneStartupPopup = triunePreference.popup == true,
        credential = '',
    }
end

local function copyMappingDraft(mapping)
    return {
        id = mapping.id, name = mapping.name, remotePath = mapping.remotePath,
        destinationRoot = mapping.destinationRoot,
        destinationPath = mapping.destinationPath,
        includePatterns = mapping.includePatterns,
        excludePatterns = mapping.excludePatterns,
        maximumFileBytes = mapping.maximumFileBytes,
        enabled = mapping.enabled, recursive = mapping.recursive,
        required = mapping.required, restartRequired = mapping.restartRequired,
    }
end

inputDraft = function(label, draft, field, width, flags)
    ImGui.SetNextItemWidth(core.px(width or 280))
    local value, changed = ImGui.InputText(label, tostring(draft[field] or ''), flags or 0)
    if changed then draft[field] = value end
end

local function setProfileField(profileId, field, value)
    return runCommand(string.format('/webupdate profiles set %s %s %s',
        profileId, field, commandEncode(value)), 'Saved repository ' .. field .. '.')
end

local function setMappingField(profileId, mappingId, field, value)
    return runCommand(string.format('/webupdate mappings set %s %s %s %s',
        profileId, mappingId, field, commandEncode(value)), 'Saved mapping ' .. field .. '.')
end

local function drawProfileEditorTab()
    local e = readEngine()
    colorText(C.blue, 'Repository & Deployment Profile Editor'); ImGui.Separator()
    if not e.available then unavailable(e); return end
    if e.profileStoreError ~= '' then colorText(C.red, e.profileStoreError) end
    textValue('Profile store', e.profileStorePath)
    ImGui.TextWrapped('Exactly one repository is Main Download. Monitor repositories are checked but can never stage or install files.')
    beginDisabled(e.busy)
    if ImGui.Button('Check Monitor Repositories', core.px(185), core.px(25)) then
        runCommand('/webupdate monitors', 'Started read-only checks for all Monitor Only repositories.')
    end
    endDisabled(e.busy)

    if not state.profileDraft then
    if ImGui.BeginTable('##ManagedRepositories', 8,
        ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable +
        ImGuiTableFlags.ScrollX + ImGuiTableFlags.SizingFixedFit) then
        ImGui.TableSetupColumn('Repository', ImGuiTableColumnFlags.WidthFixed, core.px(250))
        ImGui.TableSetupColumn('Role', ImGuiTableColumnFlags.WidthFixed, core.px(90))
        ImGui.TableSetupColumn('Provider', ImGuiTableColumnFlags.WidthFixed, core.px(80))
        ImGui.TableSetupColumn('Reference', ImGuiTableColumnFlags.WidthFixed, core.px(100))
        ImGui.TableSetupColumn('Credential', ImGuiTableColumnFlags.WidthFixed, core.px(95))
        ImGui.TableSetupColumn('Comparison Status', ImGuiTableColumnFlags.WidthFixed, core.px(125))
        ImGui.TableSetupColumn('Last Checked', ImGuiTableColumnFlags.WidthFixed, core.px(135))
        ImGui.TableSetupColumn('Edit', ImGuiTableColumnFlags.WidthFixed, core.px(70))
        ImGui.TableHeadersRow()
        for _, profile in ipairs(e.managedProfiles) do
            ImGui.TableNextRow()
            ImGui.TableSetColumnIndex(0); ImGui.Text(profile.owner .. '/' .. profile.repository)
            ImGui.TableSetColumnIndex(1)
            if profile.role == 'main' then colorText(C.green, 'Main')
            elseif profile.role == 'monitor' then colorText(C.blue, 'Monitor')
            else ImGui.TextDisabled('Disabled') end
            ImGui.TableSetColumnIndex(2); ImGui.Text(profile.provider == 'github' and 'GitHub' or profile.provider)
            ImGui.TableSetColumnIndex(3); ImGui.Text(profile.reference)
            ImGui.TableSetColumnIndex(4)
            if profile.credentialStored then colorText(C.green, 'Stored')
            elseif profile.privateRepository then colorText(C.yellow, 'Required')
            else ImGui.TextDisabled('Optional') end
            ImGui.TableSetColumnIndex(5)
            if profile.planStatus == 'Up To Date' then colorText(C.green, profile.planStatus)
            elseif profile.planStatus == 'Update Available' then colorText(C.yellow, profile.planStatus)
            elseif profile.planStatus == 'Not Checked' then ImGui.TextDisabled(profile.planStatus)
            else colorText(C.red, profile.planStatus) end
            ImGui.TableSetColumnIndex(6)
            ImGui.Text(profile.planLastChecked ~= '' and profile.planLastChecked or '-')
            ImGui.TableSetColumnIndex(7)
            if ImGui.Button('Edit##profile_' .. profile.id, core.px(58), core.px(22)) then
                state.selectedManagedProfile = profile.id
                state.selectedManagedMapping = nil
                state.profileDraft = copyProfileDraft(profile)
                state.mappingDraft = nil
            end
        end
        ImGui.EndTable()
    end

    ImGui.Spacing()
    if ImGui.Button('Add Repository', core.px(125), core.px(25)) then
        state.profileDraft = {
            id = 'new-profile', name = 'New Repository', owner = 'owner',
            repository = 'repository', reference = 'main', channel = 'stable',
            role = 'monitor', enabled = true, privateRepository = false,
            monitorOnStartup = false, monitorIntervalMinutes = '0',
            notificationsEnabled = true, acknowledgedSHA = '',
            credential = '', isNew = true,
        }
        state.selectedManagedProfile = nil
        state.selectedManagedMapping = nil
    end

    return
    end

    local draft = state.profileDraft
    if not draft then return end
    ImGui.Spacing(); ImGui.Separator()
    colorText(C.blue, draft.isNew and 'Add Repository' or ('Edit Repository: ' .. draft.name))
    if ImGui.Button('Back to Repository List', core.px(175), core.px(24)) then
        state.profileDraft = nil
        state.mappingDraft = nil
        state.selectedManagedProfile = nil
        state.selectedManagedMapping = nil
        return
    end
    ImGui.Separator()
    inputDraft('Profile ID', draft, 'id', 220)
    inputDraft('Display Name', draft, 'name', 320)
    ImGui.Text('Provider'); ImGui.SameLine(); colorText(C.blue, 'GitHub (v4 locked)')
    inputDraft('GitHub Owner', draft, 'owner', 260)
    inputDraft('Repository', draft, 'repository', 300)
    inputDraft('Branch / Tag / Commit', draft, 'reference', 300)
    inputDraft('Channel', draft, 'channel', 180)
    inputDraft('Monitor Interval Minutes (0=manual)', draft, 'monitorIntervalMinutes', 180)
    inputDraft('Acknowledged Commit SHA', draft, 'acknowledgedSHA', 360)
    ImGui.Spacing(); ImGui.Separator(); ImGui.Text('MQ2WebUpdate Backend Behavior')
    if draft.role == 'monitor' then
        if ImGui.Button((draft.monitorOnStartup and '[X] ' or '[ ] ') ..
            'Check when MQ2WebUpdate loads' ..
            (draft.monitorOnStartup and ' - ON' or ' - OFF'), core.px(285), core.px(23)) then
            draft.monitorOnStartup = not draft.monitorOnStartup
        end
        if ImGui.Button((draft.notificationsEnabled and '[X] ' or '[ ] ') ..
            'Backend chat notification' ..
            (draft.notificationsEnabled and ' - ON' or ' - OFF'), core.px(285), core.px(23)) then
            draft.notificationsEnabled = not draft.notificationsEnabled
        end
    else
        ImGui.TextDisabled('Main Download plugin-load checking is controlled in Global Update Settings.')
    end

    ImGui.Spacing(); ImGui.Text('Triune Startup Behavior')
    if ImGui.Button((draft.triuneStartupCheck and '[X] ' or '[ ] ') ..
        'Check this repository when Triune starts' ..
        (draft.triuneStartupCheck and ' - ON' or ' - OFF'), core.px(335), core.px(23)) then
        draft.triuneStartupCheck = not draft.triuneStartupCheck
    end
    if ImGui.Button((draft.triuneStartupPopup and '[X] ' or '[ ] ') ..
        'Show Triune popup for this repository' ..
        (draft.triuneStartupPopup and ' - ON' or ' - OFF'), core.px(335), core.px(23)) then
        draft.triuneStartupPopup = not draft.triuneStartupPopup
    end
    ImGui.TextDisabled('The button text is the current state. Triune checks are fresh and read-only.')
    if not draft.isNew then
        if draft.role == 'monitor' then
            ImGui.TextDisabled('Monitor status is read-only and can never Stage or Apply.')
        end
        for _, profile in ipairs(e.managedProfiles) do
            if profile.id == draft.id then
                textValue('Comparison status', profile.planStatus ~= '' and profile.planStatus or 'Not Checked')
                textValue('Resolved SHA', profile.planSHA ~= '' and profile.planSHA or '<not checked>')
                textValue('Last checked', profile.planLastChecked ~= '' and profile.planLastChecked or '<never>')
                if profile.planError ~= '' then colorText(C.red, profile.planError) end
                if profile.planSHA ~= '' then
                    if ImGui.Button('Acknowledge Current SHA', core.px(175), core.px(23)) then
                        draft.acknowledgedSHA = profile.planSHA
                        setProfileField(draft.id, 'acknowledgedsha', profile.planSHA)
                    end
                end
                break
            end
        end
        beginDisabled(e.busy)
        if ImGui.Button('Check Repository', core.px(145), core.px(24)) then
            if draft.role == 'main' then
                runCommand('/webupdate compare',
                    'Started read-only Main Download comparison for ' .. draft.id .. '.')
            else
                runCommand('/webupdate profiles test ' .. draft.id,
                    'Started read-only repository comparison for ' .. draft.id .. '.')
            end
        end
        endDisabled(e.busy)
    end

    if draft.isNew then
        if ImGui.Button('Create Repository', core.px(145), core.px(25)) then
            if runCommand('/webupdate profiles create ' .. draft.id, 'Created repository profile.') then
                setProfileField(draft.id, 'name', draft.name)
                setProfileField(draft.id, 'owner', draft.owner)
                setProfileField(draft.id, 'repository', draft.repository)
                setProfileField(draft.id, 'reference', draft.reference)
                setProfileField(draft.id, 'channel', draft.channel)
                setProfileField(draft.id, 'monitorinterval', draft.monitorIntervalMinutes)
                setProfileField(draft.id, 'monitorstartup', draft.monitorOnStartup and 'on' or 'off')
                setProfileField(draft.id, 'notifications', draft.notificationsEnabled and 'on' or 'off')
                setProfileField(draft.id, 'acknowledgedsha', draft.acknowledgedSHA)
                ctrl.update_repository_startup[draft.id] = {
                    check = draft.triuneStartupCheck == true,
                    popup = draft.triuneStartupPopup == true,
                }
                core.saveLoadout(true)
                state.selectedManagedProfile = draft.id
                draft.isNew = false
                state.profileDraft = nil
                state.mappingDraft = nil
                state.selectedManagedProfile = nil
                state.selectedManagedMapping = nil
            end
        end
    else
        if ImGui.Button('Save Repository Fields', core.px(165), core.px(25)) then
            setProfileField(draft.id, 'name', draft.name)
            setProfileField(draft.id, 'owner', draft.owner)
            setProfileField(draft.id, 'repository', draft.repository)
            setProfileField(draft.id, 'reference', draft.reference)
            setProfileField(draft.id, 'channel', draft.channel)
            setProfileField(draft.id, 'monitorinterval', draft.monitorIntervalMinutes)
            setProfileField(draft.id, 'monitorstartup', draft.monitorOnStartup and 'on' or 'off')
            setProfileField(draft.id, 'notifications', draft.notificationsEnabled and 'on' or 'off')
            setProfileField(draft.id, 'acknowledgedsha', draft.acknowledgedSHA)
            ctrl.update_repository_startup[draft.id] = {
                check = draft.triuneStartupCheck == true,
                popup = draft.triuneStartupPopup == true,
            }
            core.saveLoadout(true)
            state.profileDraft = nil
            state.mappingDraft = nil
            state.selectedManagedProfile = nil
            state.selectedManagedMapping = nil
        end
        ImGui.SameLine()
        if ImGui.Button('Set Main Download', core.px(145), core.px(25)) then
            setProfileField(draft.id, 'role', 'main')
        end
        ImGui.SameLine()
        if ImGui.Button('Set Monitor Only', core.px(130), core.px(25)) then
            setProfileField(draft.id, 'role', 'monitor')
        end
        ImGui.SameLine()
        if ImGui.Button('Disable', core.px(80), core.px(25)) then
            setProfileField(draft.id, 'role', 'disabled')
        end

        ImGui.Spacing()
        inputDraft('Duplicate As Profile ID', draft, 'duplicateId', 220)
        if ImGui.Button('Duplicate Repository', core.px(155), core.px(24)) then
            local newId = tostring(draft.duplicateId or '')
            if newId == '' then addLog('ERROR: Enter a new Profile ID for the duplicate.')
            else
                runCommand('/webupdate profiles duplicate ' .. draft.id .. ' ' .. newId,
                    'Duplicated repository profile as ' .. newId .. '.')
            end
        end
        ImGui.SameLine()
        beginDisabled(draft.id == 'morte' or draft.id == 'gennro' or draft.role == 'main')
        if ImGui.Button('Remove Repository', core.px(145), core.px(24)) then
            state.pendingDeleteProfile = draft.id
        end
        endDisabled(draft.id == 'morte' or draft.id == 'gennro' or draft.role == 'main')

        if state.pendingDeleteProfile == draft.id then
            colorText(C.yellow, 'Remove this repository profile and its mappings? Stored credentials will also be removed.')
            if ImGui.Button('Confirm Remove Repository', core.px(190), core.px(24)) then
                if runCommand('/webupdate profiles delete ' .. draft.id,
                    'Removed repository profile ' .. draft.id .. '.') then
                    state.profileDraft = nil
                    state.mappingDraft = nil
                    state.selectedManagedProfile = nil
                end
                state.pendingDeleteProfile = nil
            end
            ImGui.SameLine()
            if ImGui.Button('Cancel Remove##profile', core.px(115), core.px(24)) then
                state.pendingDeleteProfile = nil
            end
        end

        ImGui.Spacing(); ImGui.Text('Repository Access')
        if ImGui.Button(draft.privateRepository and 'Private Repository' or 'Public Repository', core.px(150), core.px(24)) then
            draft.privateRepository = not draft.privateRepository
            setProfileField(draft.id, 'private', draft.privateRepository and 'on' or 'off')
        end
        ImGui.SeparatorText('GitHub Authentication')
        ImGui.TextDisabled(draft.privateRepository
            and 'A token is required for this private repository.'
            or 'Optional for public repositories; raises GitHub limits and improves reliability.')
        inputDraft('GitHub Token', draft, 'credential', 380, ImGuiInputTextFlags.Password)
        if ImGui.Button('Store / Replace Token', core.px(155), core.px(24)) then
            runCommand('/webupdate credential set ' .. draft.id .. ' ' .. commandEncode(draft.credential),
                'Stored GitHub credential securely in Windows Credential Manager.')
            draft.credential = ''
        end
        ImGui.SameLine()
        if ImGui.Button('Remove Token', core.px(110), core.px(24)) then
            runCommand('/webupdate credential delete ' .. draft.id, 'Removed GitHub credential.')
            draft.credential = ''
        end

        local selectedProfile = nil
        for _, profile in ipairs(e.managedProfiles) do
            if profile.id == draft.id then selectedProfile = profile; break end
        end
        if selectedProfile then
            ImGui.Spacing(); ImGui.Separator(); ImGui.Text('Deployment Mappings')
            if selectedProfile.role == 'main' and type(updateConfig) == 'table' and
                type(updateConfig.payloads) == 'table' then
                ImGui.Text('Plugin DLLs from update_config.lua')
                for _, payload in ipairs(updateConfig.payloads) do
                    if payload.type == 'mq_plugin' and payload.source == selectedProfile.id and
                        payload.destinationRoot == 'plugins' and
                        type(payload.id) == 'string' and
                        payload.id:match('^[%w_-]+$') and
                        type(payload.remote) == 'string' and
                        type(payload.destination) == 'string' and
                        payload.destination:match('^[%w_-]+%.dll$') and
                        payload.remote:match('^[%w_./-]+%.dll$') and
                        payload.remote:match('([^/]+)$') == payload.destination then
                        local mappingId = 'plugin-' .. payload.id
                        local existing = false
                        for _, mapping in ipairs(selectedProfile.mappings) do
                            if mapping.id == mappingId then existing = true; break end
                        end
                        if existing then
                            ImGui.TextDisabled(payload.destination .. ' is configured')
                        elseif ImGui.Button('Add ' .. payload.destination .. '##payload_' .. payload.id,
                            core.px(230), core.px(24)) then
                            if runCommand('/webupdate mappings create ' .. draft.id .. ' ' .. mappingId,
                                'Created plugin mapping for ' .. payload.destination .. '.') then
                                setMappingField(draft.id, mappingId, 'name', payload.pluginName or payload.id)
                                setMappingField(draft.id, mappingId, 'remote', payload.remote)
                                setMappingField(draft.id, mappingId, 'root', 'plugins')
                                setMappingField(draft.id, mappingId, 'destination', '')
                                setMappingField(draft.id, mappingId, 'recursive', 'off')
                                setMappingField(draft.id, mappingId, 'required', payload.required and 'on' or 'off')
                                addLog('Run Check for Updates to inspect the new plugin mapping.')
                            end
                        end
                    end
                end
            end
            for _, mapping in ipairs(selectedProfile.mappings) do
                if ImGui.Button(mapping.name .. '##mapping_' .. mapping.id, core.px(200), core.px(23)) then
                    state.selectedManagedMapping = mapping.id
                    state.mappingDraft = copyMappingDraft(mapping)
                end
                ImGui.SameLine(); ImGui.TextDisabled(string.format('%s -> %s/%s',
                    mapping.remotePath, mapping.destinationRoot, mapping.destinationPath))
            end
            if ImGui.Button('Add Mapping', core.px(110), core.px(24)) then
                state.mappingDraft = {
                    id = 'new-mapping', name = 'New Mapping', remotePath = 'files',
                    destinationRoot = 'lua', destinationPath = '', includePatterns = '**',
                    excludePatterns = '', maximumFileBytes = '67108864', enabled = true,
                    recursive = true, required = true, restartRequired = false, isNew = true,
                }
            end
            ImGui.SameLine()
            if ImGui.Button('Add Plugin DLL', core.px(130), core.px(24)) then
                state.mappingDraft = {
                    id = 'plugin-new', name = 'New MQ Plugin DLL',
                    remotePath = 'plugins/MQ2Example.dll',
                    destinationRoot = 'plugins', destinationPath = '',
                    includePatterns = '**', excludePatterns = '',
                    maximumFileBytes = '67108864', enabled = true,
                    recursive = false, required = true, restartRequired = false,
                    isNew = true,
                }
            end

            ImGui.Spacing(); ImGui.Separator(); ImGui.Text('Repository File Browser')
            ImGui.TextDisabled('Run Check for Updates after changing a repository or mapping. Every eligible GitHub file appears here; unchecked files remain visible.')
            if selectedProfile.role ~= 'main' then
                ImGui.TextDisabled('The loaded tree belongs to the Main Download repository. Set this profile as Main and run Check to browse it.')
            elseif #e.repositoryTree == 0 then
                ImGui.TextDisabled('No repository tree is loaded yet.')
            else
                local folders, folderOrder = {}, {}
                for _, entry in ipairs(e.repositoryTree) do
                    local folder = entry.relativePath:match('^(.*)/[^/]+$')
                    if folder and folder ~= '' then
                        local key = entry.mappingId .. '|' .. folder
                        if not folders[key] then
                            folders[key] = { mappingId = entry.mappingId, path = folder, selected = true }
                            folderOrder[#folderOrder + 1] = key
                        end
                        if not entry.selected then folders[key].selected = false end
                    end
                end
                if ImGui.BeginTable('##RepositoryTreeBrowser', 5,
                ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg + ImGuiTableFlags.Resizable) then
                ImGui.TableSetupColumn('Selected', ImGuiTableColumnFlags.WidthFixed, core.px(80))
                ImGui.TableSetupColumn('Mapping', ImGuiTableColumnFlags.WidthFixed, core.px(110))
                ImGui.TableSetupColumn('Repository File', ImGuiTableColumnFlags.WidthStretch)
                ImGui.TableSetupColumn('Size', ImGuiTableColumnFlags.WidthFixed, core.px(85))
                ImGui.TableSetupColumn('Change', ImGuiTableColumnFlags.WidthFixed, core.px(95))
                ImGui.TableHeadersRow()
                for _, key in ipairs(folderOrder) do
                    local folder = folders[key]
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    if folder.selected then colorText(C.green, 'All') else colorText(C.yellow, 'Partial') end
                    ImGui.TableSetColumnIndex(1); ImGui.Text(folder.mappingId)
                    ImGui.TableSetColumnIndex(2); colorText(C.blue, '[Folder] ' .. folder.path)
                    ImGui.TableSetColumnIndex(3); ImGui.TextDisabled('-')
                    ImGui.TableSetColumnIndex(4)
                    local folderLabel = folder.selected and 'Uncheck' or 'Check All'
                    if ImGui.Button(folderLabel .. '##folder_' .. key, core.px(80), core.px(21)) then
                        runCommand(string.format('/webupdate mappings folderselection %s %s %s %s',
                            draft.id, folder.mappingId, commandEncode(folder.path),
                            folder.selected and 'off' or 'on'),
                            folderLabel .. ' folder ' .. folder.path .. '. Run Check for Updates to refresh.')
                    end
                end
                for _, entry in ipairs(e.repositoryTree) do
                    ImGui.TableNextRow()
                    ImGui.TableSetColumnIndex(0)
                    if entry.selected then colorText(C.green, 'Selected') else ImGui.TextDisabled('Excluded') end
                    ImGui.TableSetColumnIndex(1); ImGui.Text(entry.mappingId)
                    ImGui.TableSetColumnIndex(2); ImGui.TextWrapped(entry.repositoryPath)
                    ImGui.TableSetColumnIndex(3); ImGui.Text(tostring(entry.size))
                    ImGui.TableSetColumnIndex(4)
                    local label = entry.selected and 'Uncheck' or 'Check'
                    if ImGui.Button(label .. '##tree_' .. entry.mappingId .. '_' .. entry.relativePath,
                        core.px(80), core.px(21)) then
                        runCommand(string.format('/webupdate mappings selection %s %s %s %s',
                            draft.id, entry.mappingId, commandEncode(entry.relativePath),
                            entry.selected and 'off' or 'on'),
                            label .. 'ed ' .. entry.relativePath .. '. Run Check for Updates to refresh.')
                    end
                end
                ImGui.EndTable()
                end
            end
        end
    end

    local mapping = state.mappingDraft
    if not mapping or draft.isNew then return end
    ImGui.Spacing(); ImGui.Separator(); ImGui.Text(mapping.isNew and 'Add Mapping' or 'Edit Mapping')
    inputDraft('Mapping ID', mapping, 'id', 220)
    inputDraft('Mapping Name', mapping, 'name', 300)
    inputDraft('Remote File / Folder', mapping, 'remotePath', 360)
    inputDraft('Destination Subfolder', mapping, 'destinationPath', 360)
    inputDraft('Include Patterns', mapping, 'includePatterns', 420)
    inputDraft('Exclude / Unchecked Files', mapping, 'excludePatterns', 420)
    ImGui.SameLine()
    if ImGui.Button('Select All##clear_exclusions', core.px(95), core.px(22)) then
        mapping.excludePatterns = ''
    end
    ImGui.TextDisabled('Default is all files. Uncheck files in the File Plan, or edit semicolon-separated glob exclusions here.')
    inputDraft('Maximum File Bytes', mapping, 'maximumFileBytes', 180)
    ImGui.Text('Mapping Options')
    for _, option in ipairs({
        { key = 'enabled', label = 'Enabled' },
        { key = 'recursive', label = 'Recursive' },
        { key = 'required', label = 'Required' },
        { key = 'restartRequired', label = 'Restart Required' },
    }) do
        local active = mapping[option.key] and true or false
        if ImGui.Button((active and '[ON] ' or '[OFF] ') .. option.label ..
            '##mapping_option_' .. option.key, core.px(145), core.px(23)) then
            mapping[option.key] = not active
        end
        ImGui.SameLine()
    end
    ImGui.NewLine()
    ImGui.Text('Destination Root')
    for index, root in ipairs({ 'lua', 'macros', 'plugins', 'config', 'resources' }) do
        if index > 1 then ImGui.SameLine() end
        local isCurrentRoot = mapping.destinationRoot == root
        beginDisabled(isCurrentRoot)
        if ImGui.Button(root .. '##root_' .. root, core.px(78), core.px(23)) then mapping.destinationRoot = root end
        endDisabled(isCurrentRoot)
    end

    if mapping.isNew then
        if ImGui.Button('Create Mapping', core.px(125), core.px(25)) then
            if runCommand('/webupdate mappings create ' .. draft.id .. ' ' .. mapping.id,
                'Created deployment mapping.') then
                mapping.isNew = false
                addLog('Save Mapping Fields to publish the remote and destination settings.')
            end
        end
    else
        if ImGui.Button('Save Mapping Fields', core.px(150), core.px(25)) then
            setMappingField(draft.id, mapping.id, 'name', mapping.name)
            setMappingField(draft.id, mapping.id, 'remote', mapping.remotePath)
            setMappingField(draft.id, mapping.id, 'root', mapping.destinationRoot)
            setMappingField(draft.id, mapping.id, 'destination', mapping.destinationPath)
            setMappingField(draft.id, mapping.id, 'include', mapping.includePatterns)
            setMappingField(draft.id, mapping.id, 'exclude', mapping.excludePatterns)
            setMappingField(draft.id, mapping.id, 'maxbytes', mapping.maximumFileBytes)
            setMappingField(draft.id, mapping.id, 'enabled', mapping.enabled and 'on' or 'off')
            setMappingField(draft.id, mapping.id, 'recursive', mapping.recursive and 'on' or 'off')
            setMappingField(draft.id, mapping.id, 'required', mapping.required and 'on' or 'off')
            setMappingField(draft.id, mapping.id, 'restart', mapping.restartRequired and 'on' or 'off')
        end
        ImGui.SameLine()
        if ImGui.Button('Remove Mapping', core.px(120), core.px(25)) then
            state.pendingDeleteMapping = mapping.id
        end
        if state.pendingDeleteMapping == mapping.id then
            colorText(C.yellow, 'Remove this deployment mapping? At least one mapping must remain.')
            if ImGui.Button('Confirm Remove Mapping', core.px(175), core.px(24)) then
                if runCommand('/webupdate mappings delete ' .. draft.id .. ' ' .. mapping.id,
                    'Removed deployment mapping ' .. mapping.id .. '.') then
                    state.mappingDraft = nil
                    state.selectedManagedMapping = nil
                end
                state.pendingDeleteMapping = nil
            end
            ImGui.SameLine()
            if ImGui.Button('Cancel Remove##mapping', core.px(115), core.px(24)) then
                state.pendingDeleteMapping = nil
            end
        end
    end
end

local function drawSourcesTab()
    local e = readEngine()
    colorText(C.blue, 'Update Sources'); ImGui.Separator()
    if e.available then
        textValue('Active backend profile', e.activeProfile ~= '' and e.activeProfile or '<none>')
        textValue('Backend source type', e.sourceType ~= '' and e.sourceType or '<unknown>')
        textValue('Deployment repository', e.repository)
        textValue('Deployment branch', e.branch)
    else unavailable(e) end
    ImGui.Spacing(); ImGui.Separator()
    ImGui.Text('Managed Repository Roles')
    ImGui.TextWrapped('Repository roles and mappings are edited in the Repositories tab. Only the single Main Download profile can stage or install files.')
    for _, profile in ipairs(e.managedProfiles) do
        if profile.role == 'main' then colorText(C.green, '[MAIN] ' .. profile.name)
        elseif profile.role == 'monitor' then colorText(C.blue, '[MONITOR] ' .. profile.name)
        else ImGui.TextDisabled('[DISABLED] ' .. profile.name) end
        ImGui.SameLine(); ImGui.TextDisabled(profile.owner .. '/' .. profile.repository .. ' @ ' .. profile.reference)
    end

    ImGui.Spacing(); ImGui.Separator(); ImGui.Text('Persistent Configuration')
    textValue('Backend settings loaded', yesNo(e.configurationLoaded))
    textValue('Settings file', e.configurationPath ~= '' and e.configurationPath or '<unavailable>')
    ImGui.TextDisabled('The backend writes this file atomically. Users do not need to edit it.')

    if state.configLoaded and updateConfig.sources then
        ImGui.Spacing(); ImGui.Separator(); ImGui.Text('Declared Release Metadata')
        textValue('NeroMorte release', sourceLabel(updateConfig.sources.morte))
        textValue('Gennro upstream', sourceLabel(updateConfig.sources.gennro))
    elseif state.configError then colorText(C.red, state.configError) end
end

local function drawSafetyTab()
    colorText(C.blue, 'Release & Safety Policy'); ImGui.Separator()
    if state.versionLoaded then
        textValue('NeroMorte release', morteVersion.morte and morteVersion.morte.version)
        textValue('Based on Gennro', morteVersion.morte and morteVersion.morte.basedOnGennro)
        textValue('Release channel', morteVersion.morte and morteVersion.morte.channel)
        textValue('Expected engine', morteVersion.engine and morteVersion.engine.expectedVersion)
        textValue('Minimum engine', morteVersion.engine and morteVersion.engine.minimumVersion)
    else colorText(C.red, state.versionError or 'Version metadata is unavailable.') end
    ImGui.Spacing(); ImGui.Separator(); ImGui.Text('Declared Update Safety Policy')
    local t = state.configLoaded and updateConfig.transaction or nil
    local v = state.configLoaded and updateConfig.verification or nil
    local p = state.configLoaded and updateConfig.protection or nil
    textValue('Transactional staging', t and yesNo(t.enabled) or 'Unavailable')
    textValue('Backup before modification', t and yesNo(t.backupBeforeModification) or 'Unavailable')
    textValue('Rollback on failure', t and yesNo(t.rollbackOnFailure) or 'Unavailable')
    textValue('Interrupted recovery', t and yesNo(t.recoverInterruptedTransaction) or 'Unavailable')
    textValue('SHA-256 download verification', v and yesNo(v.verifyDownloads) or 'Unavailable')
    textValue('Reparse-point protection', p and yesNo(p.rejectUnsafeReparseTargets) or 'Unavailable')
    ImGui.Spacing()
    ImGui.TextWrapped('Runtime symbolic links remain protected. User configuration is not implicitly deleted. Every live mutation requires a verified staged transaction.')
end

local function drawDiagnosticsTab()
    local e = readEngine()
    colorText(C.blue, 'Diagnostics'); ImGui.Separator()
    textValue('Frontend', state.initialized and 'Initialized' or 'Not initialized')
    textValue('Configuration', state.configLoaded and 'Loaded' or 'Unavailable')
    textValue('Version metadata', state.versionLoaded and 'Loaded' or 'Unavailable')
    if e.available then
        textValue('Backend', string.format('%s / API %s', e.version, e.apiVersion))
        textValue('Upstream status', e.upstreamStatus ~= '' and e.upstreamStatus or '<not checked>')
        if e.upstreamSHA ~= '' then textValue('Upstream SHA', e.upstreamSHA) end
        if e.upstreamLastError ~= '' then colorText(C.red, 'Upstream Error'); ImGui.TextWrapped(e.upstreamLastError) end
        if e.lastError ~= '' then colorText(C.red, 'Backend Error'); ImGui.TextWrapped(e.lastError) end
    else unavailable(e) end
    if state.configError then ImGui.TextWrapped('Configuration error: ' .. state.configError) end
    if state.versionError then ImGui.TextWrapped('Version error: ' .. state.versionError) end

    ImGui.Spacing()
    if ImGui.Button('Status to Chat', core.px(115), core.px(24)) then
        runCommand('/webupdate status', 'Printed backend status to chat.')
    end
    ImGui.SameLine()
    if ImGui.Button('Protection to Chat', core.px(140), core.px(24)) then
        runCommand('/webupdate protect', 'Printed link protection report to chat.')
    end
    ImGui.SameLine()
    if ImGui.Button('Reload Metadata', core.px(125), core.px(24)) then
        package.loaded['TAC_support_modules.update_config'] = nil
        package.loaded['TAC_support_modules.morte_version'] = nil
        loadMetadata(); addLog('Reloaded updater metadata.')
    end
    ImGui.SameLine()
    if ImGui.Button('Clear GUI Log', core.px(110), core.px(24)) then state.actionLog = {} end

    ImGui.Spacing(); ImGui.Separator(); ImGui.Text('GUI Session Log')
    if #state.actionLog == 0 then ImGui.TextDisabled('No GUI actions recorded this session.')
    else for _, entry in ipairs(state.actionLog) do ImGui.TextWrapped(entry) end end
end

local function findManagedProfile(engine, profileId)
    for _, profile in ipairs(engine.managedProfiles or {}) do
        if profile.id == profileId then return profile end
    end
    return nil
end

local function finishTriuneStartupProfile(engine)
    local current = state.startupCurrent
    if not current then return end
    local profile = findManagedProfile(engine, current.id)
    if profile then
        local preference = ensureTriuneRepositoryPreference(profile)
        local failed = profile.planErrorCount > 0 or profile.planStatus == 'Compare Error'
        if preference.popup and (profile.planUpdateAvailable or failed) then
            state.startupPopupItems[#state.startupPopupItems + 1] = {
                id = profile.id, name = profile.name, role = profile.role,
                status = profile.planStatus, sha = profile.planSHA,
                checked = profile.planLastChecked, updates = profile.planUpdateCount,
                newFiles = profile.planMissingCount,
                protected = profile.planProtectedCount,
                errors = profile.planErrorCount, error = profile.planError,
            }
        end
        addLog(string.format('Triune startup check completed for %s: %s.',
            profile.name, profile.planStatus))
    end
    state.startupCurrent = nil
    state.startupSawBusy = false
    state.startupPhase = 'next'
end

local function processTriuneStartupChecks()
    if not state.initialized or state.startupPhase == 'complete' then return end
    local now = os.time()
    if state.startupLastPoll == now then return end
    state.startupLastPoll = now

    local engine = readEngine()
    if not engine.available then return end

    if state.startupPhase == 'waiting' then
        if engine.busy then return end
        local changed = false
        state.startupQueue = {}
        for _, profile in ipairs(engine.managedProfiles) do
            local preference, created = ensureTriuneRepositoryPreference(profile)
            if created then changed = true end
            if profile.enabled and profile.role ~= 'disabled' and preference.check then
                state.startupQueue[#state.startupQueue + 1] = profile.id
            end
        end
        if changed then core.saveLoadout(true) end
        state.startupIndex = 0
        state.startupPhase = 'next'
    end

    if state.startupPhase == 'next' then
        if engine.busy then return end
        state.startupIndex = state.startupIndex + 1
        local profileId = state.startupQueue[state.startupIndex]
        if not profileId then
            state.startupPhase = 'complete'
            state.showStartupPopup = #state.startupPopupItems > 0
            if #state.startupQueue > 0 then
                addLog('All enabled Triune startup repository checks completed.')
            end
            return
        end
        local profile = findManagedProfile(engine, profileId)
        if not profile then return end
        state.startupCurrent = {
            id = profile.id,
            baselineChecked = profile.planLastChecked or '',
            requestedAt = now,
        }
        local command = profile.role == 'main'
            and '/webupdate compare'
            or ('/webupdate profiles test ' .. profile.id)
        if runCommand(command, 'Triune startup check started for ' .. profile.name .. '.') then
            state.startupPhase = 'waiting_result'
        else
            state.startupCurrent = nil
            state.startupPhase = 'next'
        end
        return
    end

    if state.startupPhase == 'waiting_result' then
        if engine.busy then
            state.startupSawBusy = true
            return
        end
        local current = state.startupCurrent
        local profile = current and findManagedProfile(engine, current.id) or nil
        if not profile then return end
        local timestampChanged = profile.planLastChecked ~= '' and
            profile.planLastChecked ~= current.baselineChecked
        local settledWithoutBusy = now - current.requestedAt >= 3 and
            profile.planStatus ~= 'Checking'
        if (state.startupSawBusy and profile.planStatus ~= 'Checking') or
            timestampChanged or settledWithoutBusy then
            finishTriuneStartupProfile(engine)
        end
    end
end

local function drawTriuneStartupPopup()
    if not state.showStartupPopup or not ImGui or not core then return end
    core.pushTheme()
    ImGui.SetNextWindowSize(core.px(620), core.px(360), ImGuiCond.FirstUseEver)
    local open, draw = ImGui.Begin(
        'Triune Repository Update Check###NeroMorteTriuneStartupUpdatePopup',
        state.showStartupPopup)
    if not open then state.showStartupPopup = false end
    if draw then
        colorText(C.yellow, 'Fresh Triune startup repository check completed.')
        ImGui.TextWrapped('Updates or repository errors were found. Nothing was staged or installed.')
        ImGui.Separator()
        for _, item in ipairs(state.startupPopupItems) do
            local role = item.role == 'main' and 'MAIN' or 'MONITOR'
            colorText(item.errors > 0 and C.red or C.blue,
                string.format('[%s] %s - %s', role, item.name, item.status))
            ImGui.Text(string.format('Updates: %d   New: %d   Protected: %d   Errors: %d',
                item.updates, item.newFiles, item.protected, item.errors))
            if item.sha ~= '' then ImGui.TextWrapped('Remote SHA: ' .. item.sha) end
            if item.checked ~= '' then ImGui.TextDisabled('Checked: ' .. item.checked) end
            if item.error ~= '' then colorText(C.red, item.error) end
            ImGui.Separator()
        end
        if ImGui.Button('Open Updates', core.px(125), core.px(26)) then
            ctrl.show_update_manager = true
            core.saveLoadout(true)
            state.showStartupPopup = false
        end
        ImGui.SameLine()
        if ImGui.Button('Dismiss', core.px(95), core.px(26)) then
            state.showStartupPopup = false
        end
    end
    ImGui.End()
    core.popTheme()
end

local function drawWindow()
    if not core or not ctrl or not ImGui or not ctrl.show_update_manager then return end
    core.pushTheme()
    ImGui.SetNextWindowSize(core.px(900), core.px(600), ImGuiCond.FirstUseEver)
    core.preBeginWindow('update_manager')
    local flags = bit.bor(ImGuiWindowFlags.None, ImGuiWindowFlags.HorizontalScrollbar or 0)
    local open, draw = ImGui.Begin('MQ2WebUpdate - Production Update Manager###NeroMorteWebUpdateManager', ctrl.show_update_manager, flags)
    if not open then ctrl.show_update_manager = false; core.saveLoadout(true) end
    if draw then
        core.postBeginWindow('update_manager')
        local recoveryPath = dllRecoveryMarkerPath()
        local recoveryFile = recoveryPath and io.open(recoveryPath, 'rb') or nil
        if recoveryFile then
            recoveryFile:close()
            colorText(C.yellow, 'An interrupted plugin DLL update needs recovery.')
            beginDisabled(os.time() - state.dllRecoveryStarted < 10)
            if ImGui.Button('Recover Interrupted DLL Update', core.px(235), core.px(26)) then
                state.dllRecoveryStarted = os.time()
                runCommand('/lua run TAC_support_modules/webupdate_dll_handoff',
                    'Started independent recovery of interrupted plugin DLL update.')
            end
            endDisabled(os.time() - state.dllRecoveryStarted < 10)
            ImGui.Separator()
        end
        if ImGui.BeginTabBar('##NeroMorteUpdateManagerTabs') then
            if ImGui.BeginTabItem('Updates') then drawUpdatesTab(); ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Sources') then drawSourcesTab(); ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Repositories') then drawProfileEditorTab(); ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Settings') then drawSettingsTab(); ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Safety') then drawSafetyTab(); ImGui.EndTabItem() end
            if ImGui.BeginTabItem('Diagnostics') then drawDiagnosticsTab(); ImGui.EndTabItem() end
            ImGui.EndTabBar()
        end
    end
    ImGui.End(); core.popTheme()
end

local function refreshAfterSuccessfulApply()
    if not state.refreshAfterApply then return end
    if os.time() - state.applyRefreshStarted > 60 then
        state.refreshAfterApply = false
        state.restartTriuneAfterApply = false
        addLog('Apply refresh timed out. Run Check for Updates to refresh the file plan.')
        return
    end
    local ok, status, busy = pcall(function()
        local web = mq and mq.TLO and mq.TLO.WebUpdate
        if not web then return nil, true end
        return web.Status(), web.Busy()
    end)
    if not ok or busy or not status then return end
    local normalized = string.upper(tostring(status))
    if normalized == 'APPLIED' then
        -- Clear first so a synchronous comparison cannot request another one.
        state.refreshAfterApply = false
        local restart = state.restartTriuneAfterApply
        state.restartTriuneAfterApply = false
        if restart then
            runCommand('/ac restart', 'Lua files applied; restarting Triune.')
        else
            runCommand('/webupdate compare', 'Apply completed; refreshing the file plan.')
        end
    elseif normalized == 'ERROR' or normalized == 'FAILED' or
        normalized == 'ROLLBACK' or normalized == 'ROLLED BACK' then
        state.refreshAfterApply = false
        state.restartTriuneAfterApply = false
        addLog('Apply did not complete; the file plan was not refreshed.')
    end
end

function plugin.onInit(coreApi)
    core, ctrl, ImGui, mq = coreApi, coreApi.ctrl, coreApi.ImGui, coreApi.mq
    if ctrl.show_update_manager == nil then ctrl.show_update_manager = false end
    if ctrl.update_show_same == nil then ctrl.update_show_same = true end
    if ctrl.update_show_protected == nil then ctrl.update_show_protected = true end
    if ctrl.update_changes_only == nil then ctrl.update_changes_only = false end
    if type(ctrl.update_repository_startup) ~= 'table' then
        ctrl.update_repository_startup = {}
    end
    state.startupPhase = 'waiting'
    state.startupQueue = {}
    state.startupIndex = 0
    state.startupCurrent = nil
    state.startupSawBusy = false
    state.startupLastPoll = 0
    state.startupPopupItems = {}
    state.showStartupPopup = false
    state.refreshAfterApply = false
    state.pendingDllApply = false
    state.launchDllCoordinator = false
    state.restartTriuneAfterApply = false
    state.applyRefreshStarted = 0
    loadMetadata(); state.initialized = true
    addLog('Production Update Manager initialized.')
end

function plugin.onDestroy() state.initialized = false end
function plugin.onDrawUI()
    if state.launchDllCoordinator then
        state.launchDllCoordinator = false
        runCommand('/lua run TAC_support_modules/webupdate_dll_handoff',
            'Started independent Lua DLL handoff.')
    end
    refreshAfterSuccessfulApply()
    processTriuneStartupChecks()
    drawTriuneStartupPopup()
    drawWindow()
end

function plugin.onDrawSettings()
    local isOpen = ctrl and ctrl.show_update_manager == true
    core.accent((core.colors and core.colors.GOLD) or { 1.0, 0.70, 0.54, 1.0 },
        'MQ2WebUpdate Production Update Manager')
    if ImGui.Button((isOpen and 'Window: Visible (Click to Hide)' or 'Window: Hidden (Click to Show)')
        .. '##updateManagerToggleWin', core.px(250), core.px(24)) then
        ctrl.show_update_manager = not isOpen
        core.saveLoadout(true)
    end
    ImGui.TextDisabled('NeroMorte production updater frontend v' .. plugin.version)
end

return plugin
