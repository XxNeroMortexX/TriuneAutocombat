---@diagnostic disable: undefined-global, undefined-field

local mq    = require('mq')
local ImGui = require('ImGui')

local M = {}
-- ============================================================================
-- Update
-- ============================================================================

local webUpdateAutoLoadAttempted = false

-- Startup update-check / notification state.
local webUpdateStartupCheckStarted = false
local webUpdateStartupCheckAt = os.clock() + 3.0
local webUpdateStartupCheckPending = false
local webUpdateNotifiedSHA = nil
local webUpdateShowModal = false
local webUpdateSelectTab = false

-- Gennro upstream check is read-only. It never downloads,
-- stages, applies, or merges files from the upstream repository.
local webUpdateUpstreamCheckStarted = false
local webUpdateUpstreamCheckPending = false
local webUpdateUpstreamNotifiedSHA = nil
local webUpdateShowUpstreamModal = false

-- Update & Restart orchestration state.
-- MQ2WebUpdate performs staging asynchronously; Triune only polls status.
local webUpdateRestartPending = false
local webUpdateRestartStartedAt = 0
local webUpdateRestartError = nil
local function isWebUpdatePluginLoaded()
    local ok, loaded = pcall(function()
        return mq.TLO.Plugin('MQ2WebUpdate').IsLoaded()
    end)

    return ok and loaded == true
end

local function tryLoadWebUpdatePlugin()
    if webUpdateAutoLoadAttempted then
        return
    end

    webUpdateAutoLoadAttempted = true

    -- Use only MacroQuest's own Plugin TLO during startup. Triune must
    -- not touch the MQ2WebUpdate-owned WebUpdate TLO until this reset
    -- is complete, otherwise MQ2Lua will register the plugin as a
    -- dependency and unloading it will terminate Triune.
    if isWebUpdatePluginLoaded() then
        mq.cmd('/plugin MQ2WebUpdate unload')

        -- Give MacroQuest a short period to finish the unload before
        -- attempting to load a fresh instance.
        local waited = 0
        while isWebUpdatePluginLoaded() and waited < 2000 do
            mq.delay(50)
            waited = waited + 50
        end
    end

    -- Load a fresh plugin instance. If the DLL is missing, Triune
    -- continues normally and the Update tab shows its missing-plugin
    -- instructions.
    if not isWebUpdatePluginLoaded() then
        mq.cmd('/plugin MQ2WebUpdate')
    end
end

local updateManagerInitialized = false
local function processWebUpdateStartupCheck()
    -- If a startup comparison has already been launched, wait for
    -- MQ2WebUpdate to finish it.
    if webUpdateStartupCheckStarted then
        if not webUpdateStartupCheckPending then
            return
        end

        if not isWebUpdatePluginLoaded() then
            webUpdateStartupCheckPending = false
            return
        end

        local okStatus, status = pcall(function()
            return mq.TLO.WebUpdate.Status()
        end)

        if not okStatus or status == nil then
            return
        end

        status = tostring(status)

        -- These states mean the updater is still doing work.
        if status == 'Comparing'
            or status == 'Scanning'
            or status == 'Checking'
        then
            return
        end

        webUpdateStartupCheckPending = false

        local okAvailable, available = pcall(function()
            return mq.TLO.WebUpdate.UpdateAvailable()
        end)

        if not okAvailable or available ~= true then
            return
        end

        local okSHA, sha = pcall(function()
            return mq.TLO.WebUpdate.RemoteSHA()
        end)

        sha = okSHA and tostring(sha or '') or ''

        -- Notify only once for this remote commit during this
        -- Triune session.
        local notificationKey =
            sha ~= '' and sha or '<unknown>'

        if webUpdateNotifiedSHA == notificationKey then
            return
        end

        webUpdateNotifiedSHA = notificationKey
        webUpdateShowModal = true
        return
    end

    -- Let Triune and the freshly reloaded MQ2WebUpdate plugin finish
    -- startup before contacting GitHub.
    if os.clock() < webUpdateStartupCheckAt then
        return
    end

    webUpdateStartupCheckStarted = true

    if not isWebUpdatePluginLoaded() then
        return
    end

    webUpdateStartupCheckPending = true
    mq.cmd('/webupdate compare')
end

local function getTriuneVersionInfo()
    local okVersion, versionInfo = pcall(require, 'triune_version')

    if okVersion and type(versionInfo) == 'table' then
        return versionInfo
    end

    return nil
end

local function processWebUpdateUpstreamCheck()
    if webUpdateUpstreamCheckStarted then
        if not webUpdateUpstreamCheckPending then
            return
        end

        if not isWebUpdatePluginLoaded() then
            webUpdateUpstreamCheckPending = false
            return
        end

        local okStatus, status = pcall(function()
            return mq.TLO.WebUpdate.UpstreamStatus()
        end)

        if not okStatus or status == nil then
            return
        end

        status = tostring(status)

        if status == 'Checking' then
            return
        end

        webUpdateUpstreamCheckPending = false

        if status ~= 'Ready' then
            return
        end

        local okSHA, remoteSHA = pcall(function()
            return mq.TLO.WebUpdate.UpstreamSHA()
        end)

        remoteSHA = okSHA and tostring(remoteSHA or '') or ''

        if remoteSHA == '' then
            return
        end

        local versionInfo = getTriuneVersionInfo()
        local baselineSHA =
            versionInfo
            and tostring(versionInfo.upstream_sha or '')
            or ''

        if baselineSHA == '' then
            return
        end

        -- Same SHA means this Morte build already contains the
        -- current Gennro upstream commit.
        if remoteSHA == baselineSHA then
            return
        end

        -- Notify only once per upstream SHA during this session.
        if webUpdateUpstreamNotifiedSHA == remoteSHA then
            return
        end

        webUpdateUpstreamNotifiedSHA = remoteSHA
        webUpdateShowUpstreamModal = true
        return
    end

    -- Use the same short startup delay as the normal Morte check.
    if os.clock() < webUpdateStartupCheckAt then
        return
    end

    webUpdateUpstreamCheckStarted = true

    if not isWebUpdatePluginLoaded() then
        return
    end

    webUpdateUpstreamCheckPending = true

    -- READ ONLY:
    -- this command requests only gennro/main's current commit SHA.
    mq.cmd('/webupdate upstreamsilent')
end

local function drawWebUpdateUpstreamModal(setCompact)
    if not webUpdateShowUpstreamModal then
        return
    end

    -- If a normal Morte update notification is currently open,
    -- let that finish first.
    if webUpdateShowModal then
        return
    end

    ImGui.OpenPopup(
        'Gennro Upstream Changes Available##WebUpdateUpstreamModal'
    )

    local visible, open = ImGui.BeginPopupModal(
        'Gennro Upstream Changes Available##WebUpdateUpstreamModal',
        true,
        ImGuiWindowFlags.AlwaysAutoResize
    )

    if visible then
        ImGui.Text('Gennro has published new TriuneAutocombat changes.')
        ImGui.Spacing()

        ImGui.TextWrapped(
            'Nothing has been downloaded, staged, merged, or installed from Gennro.'
        )

        ImGui.TextWrapped(
            'This notification only tells you that the Morte fork may need to be synced with upstream.'
        )

        ImGui.Spacing()

        if ImGui.Button('View Update') then
            webUpdateShowUpstreamModal = false
            webUpdateSelectTab = true
            if setCompact then setCompact(false) end
            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()

        if ImGui.Button('Not Now') then
            webUpdateShowUpstreamModal = false
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    elseif open == false then
        webUpdateShowUpstreamModal = false
    end
end
local function drawWebUpdateModal(setCompact)
    if not webUpdateShowModal then
        return
    end

    -- This is a modal rather than a normal ImGui window. It therefore
    -- stays above Triune and prevents interaction with the window
    -- underneath until the user chooses an action.
    ImGui.OpenPopup(
        'TriuneAutocombat Update Available##WebUpdateModal'
    )

    -- Center the modal on the main viewport when available.
    local centerX = 415
    local centerY = 320

    pcall(function()
        local viewport = ImGui.GetMainViewport()

        if viewport then
            local pos = viewport.Pos
            local size = viewport.Size

            if pos and size then
                centerX = pos.x + (size.x * 0.5)
                centerY = pos.y + (size.y * 0.5)
            end
        end
    end)

    ImGui.SetNextWindowPos(
        centerX,
        centerY,
        ImGuiCond.Appearing,
        0.5,
        0.5
    )

    ImGui.SetNextWindowSize(
        470,
        0,
        ImGuiCond.Appearing
    )

    local modalFlags = bit.bor(
        (ImGuiWindowFlags
            and ImGuiWindowFlags.AlwaysAutoResize) or 0,
        (ImGuiWindowFlags
            and ImGuiWindowFlags.NoCollapse) or 0
    )

    if ImGui.BeginPopupModal(
        'TriuneAutocombat Update Available##WebUpdateModal',
        nil,
        modalFlags
    ) then
        ImGui.TextColored(
            1.0, 0.75, 0.20, 1.0,
            'TriuneAutocombat Update Available'
        )

        ImGui.Separator()
        ImGui.Spacing()

        ImGui.TextWrapped(
            'A new version of TriuneAutocombat is available on GitHub.'
        )

        ImGui.Spacing()

        local function modalWU(fn, fallback)
            local ok, value = pcall(fn)

            if not ok or value == nil then
                return fallback
            end

            return value
        end

        local updateCount = tonumber(modalWU(function()
            return mq.TLO.WebUpdate.UpdateCount()
        end, 0)) or 0

        local missingCount = tonumber(modalWU(function()
            return mq.TLO.WebUpdate.MissingCount()
        end, 0)) or 0

        local protectedCount = tonumber(modalWU(function()
            return mq.TLO.WebUpdate.ProtectedCount()
        end, 0)) or 0

        local errorCount = tonumber(modalWU(function()
            return mq.TLO.WebUpdate.ErrorCount()
        end, 0)) or 0

        local sha = tostring(modalWU(function()
            return mq.TLO.WebUpdate.RemoteSHA()
        end, ''))

        if ImGui.BeginTable(
            '##WebUpdateModalSummary',
            2
        ) then
            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.TextDisabled('Files needing update')
            ImGui.TableNextColumn()
            ImGui.Text(tostring(updateCount))

            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.TextDisabled('Missing files')
            ImGui.TableNextColumn()
            ImGui.Text(tostring(missingCount))

            ImGui.TableNextRow()
            ImGui.TableNextColumn()
            ImGui.TextDisabled('Protected files')
            ImGui.TableNextColumn()
            ImGui.Text(tostring(protectedCount))

            if errorCount > 0 then
                ImGui.TableNextRow()
                ImGui.TableNextColumn()
                ImGui.TextDisabled('Errors')
                ImGui.TableNextColumn()

                ImGui.TextColored(
                    1.0, 0.35, 0.35, 1.0,
                    tostring(errorCount)
                )
            end

            ImGui.EndTable()
        end

        if sha ~= '' then
            ImGui.Spacing()
            ImGui.TextDisabled('Remote commit')
            ImGui.Text(sha)

            if ImGui.IsItemHovered() then
                ImGui.SetTooltip(sha)
            end
        end

        ImGui.Spacing()
        ImGui.Separator()
        ImGui.Spacing()

        if ImGui.Button(
            'View Update',
            150,
            28
        ) then
            webUpdateShowModal = false
            webUpdateSelectTab = true

            -- The Update tab only exists in the full Triune window.
            -- If the user is in Compact Mode, View Update should
            -- behave like the existing Full Window button.
            if setCompact then setCompact(false) end

            ImGui.CloseCurrentPopup()
        end

        ImGui.SameLine()

        if ImGui.Button(
            'Not Now',
            110,
            28
        ) then
            webUpdateShowModal = false
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    end
end

local function startWebUpdateRestart()
    if webUpdateRestartPending then
        return
    end

    if not isWebUpdatePluginLoaded() then
        webUpdateRestartError = 'MQ2WebUpdate is not loaded.'
        return
    end

    webUpdateRestartError = nil
    webUpdateRestartPending = true
    webUpdateRestartStartedAt = os.clock()

    mq.cmd('/webupdate stage')
end

local function processWebUpdateRestart()
    if not webUpdateRestartPending then
        return
    end

    local ok, status = pcall(function()
        return tostring(mq.TLO.WebUpdate.Status())
    end)

    if not ok then
        webUpdateRestartPending = false
        webUpdateRestartError =
            'Could not read MQ2WebUpdate status.'
        return
    end

    -- Network/staging work is running on MQ2WebUpdate's background worker.
    -- Return immediately so the normal Triune/EQ frame continues.
    if status == 'Staging' or
       status == 'Comparing' or
       status == 'Scanning' or
       status == 'Checking' then

        if (os.clock() - webUpdateRestartStartedAt) > 120.0 then
            webUpdateRestartPending = false
            webUpdateRestartError =
                'Update staging timed out.'
        end

        return
    end

    if status == 'Staged' then
        webUpdateRestartPending = false
        webUpdateRestartError = nil

        -- Separate Lua process takes ownership from this point.
        mq.cmd('/lua run triune_updater')
        return
    end

    if status == 'Up To Date' then
        webUpdateRestartPending = false
        webUpdateRestartError = nil
        return
    end

    if status == 'Stage Error' or
       status == 'Error' then

        webUpdateRestartPending = false

        local lastError = ''

        pcall(function()
            lastError =
                tostring(mq.TLO.WebUpdate.LastError() or '')
        end)

        if lastError ~= '' then
            webUpdateRestartError =
                'Staging failed: ' .. lastError
        else
            webUpdateRestartError =
                'Staging failed.'
        end

        return
    end

    -- Give /webupdate stage a short period to transition into Staging.
    if (os.clock() - webUpdateRestartStartedAt) > 5.0 then
        webUpdateRestartPending = false
        webUpdateRestartError =
            'Unexpected updater status: ' .. tostring(status)
    end
end

local function drawUpdateTab(baseVersion)
    local updateTabFlags = 0

    if webUpdateSelectTab and ImGuiTabItemFlags then
        updateTabFlags = ImGuiTabItemFlags.SetSelected
    end

    if not ImGui.BeginTabItem(
        'Update',
        nil,
        updateTabFlags
    ) then
        return
    end

    -- SetSelected only needs to be requested for one successful
    -- frame.
    webUpdateSelectTab = false

    local function wu(fn, fallback)
        local ok, value = pcall(fn)
        if not ok or value == nil then
            return fallback
        end
        return value
    end

    -- First check through MacroQuest itself. This does not create a
    -- dependency on MQ2WebUpdate when the plugin is missing.
    local pluginReady = isWebUpdatePluginLoaded()

    ImGui.Text('TriuneAutocombat Update')
    ImGui.Separator()

    local versionInfo = nil
    local okVersion, loadedVersion = pcall(require, 'triune_version')
    if okVersion and type(loadedVersion) == 'table' then
        versionInfo = loadedVersion
    end

    ImGui.Text('Triune Version: ' .. tostring((versionInfo and versionInfo.base_version) or baseVersion or 'Unknown'))
    ImGui.Text('Morte Version: ' .. tostring((versionInfo and versionInfo.fork_version) or 'Unknown'))
    ImGui.Spacing()
    if pluginReady and versionInfo then
        local upstreamStatus = wu(function()
            return mq.TLO.WebUpdate.UpstreamStatus()
        end, 'Idle')

        local upstreamSHA = wu(function()
            return mq.TLO.WebUpdate.UpstreamSHA()
        end, '')

        upstreamStatus = tostring(upstreamStatus or 'Idle')
        upstreamSHA = tostring(upstreamSHA or '')

        local baselineSHA =
            tostring(versionInfo.upstream_sha or '')

        if upstreamStatus == 'Checking' then
            ImGui.TextColored(
                1.0, 0.75, 0.20, 1.0,
                'Gennro Upstream: Checking...'
            )
        elseif upstreamStatus == 'Ready'
            and upstreamSHA ~= ''
            and baselineSHA ~= ''
        then
            if upstreamSHA == baselineSHA then
                ImGui.TextColored(
                    0.35, 1.0, 0.35, 1.0,
                    'Gennro Upstream: Up to Date'
                )
            else
                ImGui.TextColored(
                    1.0, 0.55, 0.20, 1.0,
                    'Gennro Upstream: New Changes Available'
                )
            end
        elseif upstreamStatus == 'Error' then
            ImGui.TextColored(
                1.0, 0.35, 0.35, 1.0,
                'Gennro Upstream: Check Failed'
            )
        else
            ImGui.TextDisabled(
                'Gennro Upstream: Not Checked'
            )
        end

        if upstreamSHA ~= '' then
            ImGui.TextWrapped(
                'Gennro SHA: ' .. upstreamSHA
            )
        end

        ImGui.Spacing()
    end

    if not pluginReady then
        ImGui.TextColored(
            1.0, 0.75, 0.20, 1.0,
            'MQ2WebUpdate Plugin Missing'
        )

        ImGui.Spacing()

        ImGui.TextWrapped(
            "Triune's automatic updater requires MQ2WebUpdate.dll."
        )

        ImGui.TextWrapped(
            'Triune will continue to work normally without the updater.'
        )

        ImGui.Spacing()
        ImGui.Separator()
        ImGui.Spacing()

        ImGui.Text('1. Download MQ2WebUpdate.dll')

        ImGui.Text('GitHub Releases:')

        ImGui.SetNextItemWidth(-1)

        ImGui.InputText(
            '##MQ2WebUpdateGitHubURL',
            'https://github.com/XxNeroMortexX/TriuneAutocombat/releases/latest',
            ImGuiInputTextFlags.ReadOnly
        )

        if ImGui.IsItemHovered() then
            ImGui.SetTooltip('Click the address, then press Ctrl+A and Ctrl+C to copy it.')
        end

        ImGui.Spacing()

        ImGui.Text('2. Copy MQ2WebUpdate.dll into your MacroQuest plugins folder:')

        ImGui.TextColored(
            0.40, 0.75, 1.0, 1.0,
            'MacroQuest\\plugins\\MQ2WebUpdate.dll'
        )

        ImGui.TextDisabled(
            'Example: ...\\macroquest\\build\\bin\\release\\plugins\\MQ2WebUpdate.dll'
        )

        ImGui.Spacing()

        ImGui.Text('3. Return here and load the plugin:')

        if ImGui.Button('Load MQ2WebUpdate') then
            mq.cmd('/plugin MQ2WebUpdate')
        end

        ImGui.SameLine()
        ImGui.TextDisabled('Triune will also try to load it automatically when starting.')

        ImGui.Spacing()
        ImGui.Separator()
        ImGui.Spacing()

        ImGui.TextWrapped(
            'If the plugin is not installed yet, use the GitHub address above to download it.'
        )

        ImGui.EndTabItem()
        return
    end

    local status = tostring(wu(function()
        return mq.TLO.WebUpdate.Status()
    end, 'Unknown'))

    local repo = tostring(wu(function()
        return mq.TLO.WebUpdate.Repository()
    end, 'Unknown'))

    local branch = tostring(wu(function()
        return mq.TLO.WebUpdate.Branch()
    end, 'Unknown'))

    local sha = tostring(wu(function()
        return mq.TLO.WebUpdate.RemoteSHA()
    end, ''))

    local lastError = tostring(wu(function()
        return mq.TLO.WebUpdate.LastError()
    end, ''))

    local fileCount = tonumber(wu(function()
        return mq.TLO.WebUpdate.FileCount()
    end, 0)) or 0

    local sameCount = tonumber(wu(function()
        return mq.TLO.WebUpdate.SameCount()
    end, 0)) or 0

    local updateCount = tonumber(wu(function()
        return mq.TLO.WebUpdate.UpdateCount()
    end, 0)) or 0

    local missingCount = tonumber(wu(function()
        return mq.TLO.WebUpdate.MissingCount()
    end, 0)) or 0

    local protectedCount = tonumber(wu(function()
        return mq.TLO.WebUpdate.ProtectedCount()
    end, 0)) or 0

    local errorCount = tonumber(wu(function()
        return mq.TLO.WebUpdate.ErrorCount()
    end, 0)) or 0

    local updateAvailable = wu(function()
        return mq.TLO.WebUpdate.UpdateAvailable()
    end, false) == true

    -- Repository information
    if ImGui.BeginTable('##TriuneUpdateInfo', 2) then
        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.TextDisabled('Repository')
        ImGui.TableNextColumn()
        ImGui.Text(repo)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.TextDisabled('Branch')
        ImGui.TableNextColumn()
        ImGui.Text(branch)

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.TextDisabled('Status')
        ImGui.TableNextColumn()

        if errorCount > 0 then
            ImGui.TextColored(1.0, 0.35, 0.35, 1.0, status)
        elseif updateAvailable then
            ImGui.TextColored(1.0, 0.75, 0.20, 1.0, status)
        elseif status == 'Up To Date' then
            ImGui.TextColored(0.35, 1.0, 0.45, 1.0, status)
        else
            ImGui.Text(status)
        end

        ImGui.TableNextRow()
        ImGui.TableNextColumn()
        ImGui.TextDisabled('Remote Commit')
        ImGui.TableNextColumn()

        if sha ~= '' then
            ImGui.Text(sha)

            if ImGui.IsItemHovered() then
                ImGui.SetTooltip(sha)
            end
        else
            ImGui.TextDisabled('Not checked yet')
        end

        ImGui.EndTable()
    end

    ImGui.Spacing()

    -- Buttons
    if ImGui.Button('Check for Updates') then
        mq.cmd('/webupdate compare')
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Compare installed Triune Lua files against GitHub.')
    end

    ImGui.SameLine()

    local updateRestartDisabled =
        webUpdateRestartPending or
        status == 'Staging' or
        status == 'Comparing' or
        status == 'Scanning' or
        status == 'Checking'

    ImGui.BeginDisabled(updateRestartDisabled)

    if ImGui.Button(
        webUpdateRestartPending and
            'Preparing Update...' or
            'Update & Restart'
    ) then
        startWebUpdateRestart()
    end

    ImGui.EndDisabled()

    if ImGui.IsItemHovered() then
        if webUpdateRestartPending then
            ImGui.SetTooltip(
                'Downloading and staging the update in the background.'
            )
        elseif updateAvailable then
            ImGui.SetTooltip(
                'Safely stage the update, stop Triune, apply it, and restart the same running Triune modules.'
            )
        else
            ImGui.SetTooltip(
                'Check GitHub, stage any changed files, and restart Triune if an update is available.'
            )
        end
    end

    if webUpdateRestartPending then
        ImGui.SameLine()

        ImGui.TextColored(
            1.0, 0.75, 0.20, 1.0,
            'Staging...'
        )
    end

    if webUpdateRestartError then
        ImGui.Spacing()

        ImGui.TextColored(
            1.0, 0.35, 0.35, 1.0,
            webUpdateRestartError
        )
    end

    ImGui.Spacing()
    ImGui.Separator()

    -- Summary
    ImGui.Text('Update Summary')

    if ImGui.BeginTable('##TriuneUpdateSummary', 5) then
        ImGui.TableSetupColumn('Up To Date')
        ImGui.TableSetupColumn('Update')
        ImGui.TableSetupColumn('Missing')
        ImGui.TableSetupColumn('Protected')
        ImGui.TableSetupColumn('Errors')
        ImGui.TableHeadersRow()

        ImGui.TableNextRow()

        ImGui.TableNextColumn()
        ImGui.Text(tostring(sameCount))

        ImGui.TableNextColumn()
        if updateCount > 0 then
            ImGui.TextColored(1.0, 0.75, 0.20, 1.0, tostring(updateCount))
        else
            ImGui.Text(tostring(updateCount))
        end

        ImGui.TableNextColumn()
        if missingCount > 0 then
            ImGui.TextColored(1.0, 0.75, 0.20, 1.0, tostring(missingCount))
        else
            ImGui.Text(tostring(missingCount))
        end

        ImGui.TableNextColumn()
        if protectedCount > 0 then
            ImGui.TextColored(0.40, 0.75, 1.0, 1.0, tostring(protectedCount))
        else
            ImGui.Text(tostring(protectedCount))
        end

        ImGui.TableNextColumn()
        if errorCount > 0 then
            ImGui.TextColored(1.0, 0.35, 0.35, 1.0, tostring(errorCount))
        else
            ImGui.Text(tostring(errorCount))
        end

        ImGui.EndTable()
    end

    if protectedCount > 0 then
        ImGui.Spacing()
        ImGui.Separator()

        ImGui.TextColored(
            0.40, 0.75, 1.0, 1.0,
            'Developer linked files detected'
        )

        ImGui.TextWrapped(
            'Automatic replacement is disabled for protected symbolic links.'
        )
    end

    ImGui.Spacing()
    ImGui.Separator()

    -- Files
    ImGui.Text('Files')

    if fileCount <= 0 then
        ImGui.TextDisabled(
            'No comparison results yet. Click Check for Updates.'
        )
    else
        if ImGui.BeginTable('##TriuneUpdateFiles', 3) then
            ImGui.TableSetupColumn('File')
            ImGui.TableSetupColumn('Status')
            ImGui.TableSetupColumn('Protection')
            ImGui.TableHeadersRow()

            for i = 1, fileCount do
                local name = tostring(wu(function()
                    return mq.TLO.WebUpdate.File(i).Name()
                end, '?'))

                local fileStatus = tostring(wu(function()
                    return mq.TLO.WebUpdate.File(i).Status()
                end, 'UNKNOWN'))

                local protection = tostring(wu(function()
                    return mq.TLO.WebUpdate.File(i).Protection()
                end, 'UNKNOWN'))

                local repoPath = tostring(wu(function()
                    return mq.TLO.WebUpdate.File(i).RepoPath()
                end, ''))

                ImGui.TableNextRow()

                ImGui.TableNextColumn()
                ImGui.Text(name)

                if repoPath ~= '' and ImGui.IsItemHovered() then
                    ImGui.SetTooltip(repoPath)
                end

                ImGui.TableNextColumn()

                if fileStatus == 'SAME' then
                    ImGui.TextColored(
                        0.35, 1.0, 0.45, 1.0,
                        'UP TO DATE'
                    )
                elseif fileStatus == 'UPDATE' then
                    ImGui.TextColored(
                        1.0, 0.75, 0.20, 1.0,
                        'UPDATE'
                    )
                elseif fileStatus == 'MISSING' then
                    ImGui.TextColored(
                        1.0, 0.75, 0.20, 1.0,
                        'MISSING'
                    )
                elseif fileStatus == 'ERROR' then
                    ImGui.TextColored(
                        1.0, 0.35, 0.35, 1.0,
                        'ERROR'
                    )
                else
                    ImGui.Text(fileStatus)
                end

                ImGui.TableNextColumn()

                if protection == 'LINK PROTECTED' then
                    ImGui.TextColored(
                        0.40, 0.75, 1.0, 1.0,
                        protection
                    )
                else
                    ImGui.Text(protection)
                end
            end

            ImGui.EndTable()
        end
    end

    ImGui.Spacing()
    ImGui.Separator()
    ImGui.Text('Update Details')

    if errorCount > 0 then
        ImGui.TextColored(
            1.0, 0.35, 0.35, 1.0,
            'One or more updater errors were reported.'
        )
    elseif status == 'Up To Date' then
        ImGui.TextColored(
            0.35, 1.0, 0.45, 1.0,
            'All checked Lua files are up to date.'
        )
    elseif updateAvailable then
        ImGui.TextColored(
            1.0, 0.75, 0.20, 1.0,
            string.format(
                '%d file(s) need updating; %d missing.',
                updateCount,
                missingCount
            )
        )
    else
        ImGui.TextDisabled(
            'Click Check for Updates to compare against GitHub.'
        )
    end

    if lastError ~= '' then
        ImGui.Spacing()
        ImGui.TextColored(
            1.0, 0.35, 0.35, 1.0,
            'Last Error: ' .. lastError
        )
    end

    ImGui.EndTabItem()
end



-- ============================================================================
-- Public integration API
-- ============================================================================
-- Keep triune.lua integration intentionally small so upstream merges remain
-- easy. All updater state and behavior stays inside this module.

function M.process()
    -- MQ2Lua cannot delay while this module is being imported.
    -- Initialize MQ2WebUpdate on the first normal process tick instead.
    if not updateManagerInitialized then
        updateManagerInitialized = true
        tryLoadWebUpdatePlugin()
    end

    processWebUpdateStartupCheck()
    processWebUpdateUpstreamCheck()
    processWebUpdateRestart()
end

function M.drawTab(baseVersion)
    drawUpdateTab(baseVersion)
end

function M.drawModals(setCompact)
    drawWebUpdateModal(setCompact)
    drawWebUpdateUpstreamModal(setCompact)
end

return M