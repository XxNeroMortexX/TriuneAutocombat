---@diagnostic disable: undefined-global, undefined-field

-- ============================================================================
-- Triune Custom Control Manager
-- Created by: NeroMorte
--
-- NeroMorte-owned Control-tab extensions live here instead of being spread
-- throughout Gennro's triune.lua.
-- ============================================================================

local mq = require('mq')

local M = {}
local PET_PULLER_DISPATCH_TIMEOUT = 30.0
local PET_PULLER_PET_TARGET_LOSS_GRACE = 3.0

local state = {
    lastNoCampMessageAt = 0,
    lastGuardTargetId = 0,
    lastGuardHomeDebugAt = 0,
    lastGuardTraceAt = 0,
    guardTraceTargetCommandId = 0,
    guardTraceTargetBeforeId = 0,
    guardTraceTargetAfterId = 0,
    guardTraceTargetCommandOk = nil,
    guardTraceLastClear = 'none',
    guardTraceLastReset = 'none',
    observedMode = nil,
    petPullerPhase = 'IDLE',
    petPullerCandidateId = 0,
    petPullerAttackSentId = 0,
    petPullerRecallSentId = 0,
    petPullerPlayerTargetClearedId = 0,
    petPullerLastTargetAttemptAt = 0,
    petPullerTargetSettleId = 0,
    petPullerTargetSettleAt = 0,
    petPullerNoCampStopped = false,
    petPullerReturning = false,
    petPullerDispatchAttackId = 0,
    petPullerDispatchStartedAt = 0,
    petPullerPetTargetSeenId = 0,
    petPullerPetTargetLostAt = 0,
    petPullerOwnerEngageAttackId = 0,
    guardObservedActive = false,
    guardPhase = 'IDLE',
    guardTargetId = 0,
    guardTargetKind = nil,
    guardPetCommandSentId = 0,
    guardPetCommandAt = 0,
    guardTargetSettleId = 0,
    guardTargetSettleAt = 0,
    guardDispatchAttackId = 0,
    guardDispatchStartedAt = 0,
    guardOwnerEngageTargetId = 0,
    guardMustReturnHome = false,
}

local function releasePetPullerDispatchAttack()
    if (tonumber(state.petPullerDispatchAttackId) or 0) > 0 then
        mq.cmd('/attack off')
    end
    state.petPullerDispatchAttackId = 0
end

local function releasePetPullerOwnerEngageAttack()
    if (tonumber(state.petPullerOwnerEngageAttackId) or 0) > 0 then
        mq.cmd('/attack off')
    end
    state.petPullerOwnerEngageAttackId = 0
end

local function releaseGuardOwnedAttack()
    if (tonumber(state.guardDispatchAttackId) or 0) > 0
        or (tonumber(state.guardOwnerEngageTargetId) or 0) > 0
    then
        mq.cmd('/attack off')
    end
    state.guardDispatchAttackId = 0
    state.guardDispatchStartedAt = 0
    state.guardOwnerEngageTargetId = 0
end

local function resetGuardState(runtime, recallPets, reason)
    local targetId = tonumber(state.guardTargetId) or 0
    state.guardTraceLastReset = string.format('%s target=%d', tostring(reason or 'resetGuardState'), targetId)
    releaseGuardOwnedAttack()
    if recallPets and targetId > 0 then
        mq.cmd('/say #petcmd back all')
    end
    state.guardPhase = 'IDLE'
    state.guardTargetId = 0
    state.guardTargetKind = nil
    state.guardPetCommandSentId = 0
    state.guardPetCommandAt = 0
    state.guardTargetSettleId = 0
    state.guardTargetSettleAt = 0
    state.guardMustReturnHome = false
    if runtime and runtime.stopMoving then
        runtime.stopMoving()
    end
end

local function resetPetPullerState()
    releasePetPullerDispatchAttack()
    releasePetPullerOwnerEngageAttack()
    state.petPullerPhase = 'IDLE'
    state.petPullerCandidateId = 0
    state.petPullerAttackSentId = 0
    state.petPullerRecallSentId = 0
    state.petPullerPlayerTargetClearedId = 0
    state.petPullerLastTargetAttemptAt = 0
    state.petPullerTargetSettleId = 0
    state.petPullerTargetSettleAt = 0
    state.petPullerDispatchStartedAt = 0
    state.petPullerPetTargetSeenId = 0
    state.petPullerPetTargetLostAt = 0
    state.petPullerReturning = false
end

local function debugPetPuller(ctrl, message)
    if ctrl and ctrl.debug_mode then
        print('\ao[Pet Puller]\ax ' .. tostring(message))
    end
end

local function debugGuard(ctrl, message)
    if ctrl and ctrl.debug_mode then
        print('\ao[Guard]\ax ' .. tostring(message))
    end
end

local function emitGuardTrace(ctrl, trace)
    if not ctrl or not ctrl.debug_mode or not trace then return end

    print(string.format(
        '[GuardTrace] entered=YES callerSeen=%s mode=%s submode=%s active=%s running=%s phase=%s camp=%s returnLatch=%s playerCampDist=%.1f returnRadius=%.1f pullRadius=%.1f assistRadius=%.1f petSearchRadius=%.1f scanRadius=%.1f',
        tostring(trace.callerSeen), tostring(trace.mode), tostring(trace.submode), tostring(trace.active), tostring(trace.running),
        tostring(trace.phase), tostring(trace.camp), tostring(trace.returnLatch),
        tonumber(trace.playerCampDistance) or -1, tonumber(trace.returnRadius) or -1,
        tonumber(trace.pullRadius) or -1, tonumber(trace.assistRadius) or -1,
        tonumber(trace.petSearchRadius) or -1, tonumber(trace.scanRadius) or -1))
    print(string.format(
        '[GuardTrace] campLoc=(%.1f,%.1f,%.1f) playerLoc=(%.1f,%.1f,%.1f) stateTarget=%s stateKind=%s targetAtEntry=%s targetNow=%s lastReset=%s lastClear=%s',
        tonumber(trace.campX) or 0, tonumber(trace.campY) or 0, tonumber(trace.campZ) or 0,
        tonumber(trace.playerX) or 0, tonumber(trace.playerY) or 0, tonumber(trace.playerZ) or 0,
        tostring(trace.stateTargetId), tostring(trace.stateTargetKind),
        tostring(trace.targetAtEntry), tostring(trace.targetNow),
        tostring(trace.lastReset), tostring(trace.lastClear)))

    local queries = trace.queries or {}
    print(string.format('[GuardTrace] rawQueries=%s', #queries > 0 and table.concat(queries, ' | ') or 'not-run'))
    local candidates = trace.candidates or {}
    if #candidates == 0 then
        print('[GuardTrace] raw[1]=nil')
    else
        for _, row in ipairs(candidates) do
            print(string.format(
                '[GuardTrace] raw[%d] id=%s name=%s type=%s playerDist=%.1f campDist=%.1f z=%.1f targetable=%s RESULT=%s',
                tonumber(row.index) or 0, tostring(row.id), tostring(row.name), tostring(row.spawnType),
                tonumber(row.playerDistance) or -1, tonumber(row.campDistance) or -1,
                tonumber(row.z) or 0, tostring(row.targetable), tostring(row.result)))
        end
    end
    print(string.format(
        '[GuardTrace] findRoamTarget=%s acquireCampRoamTarget=%s acquireError=%s guardTargetAllowed=%s selectedCandidate=%s targetCommand="/target id %s" targetBefore=%s targetAfter=%s targetCommandOk=%s',
        tostring(trace.findRoamTargetResult), tostring(trace.acquireCampRoamTargetResult),
        tostring(trace.acquireError), tostring(trace.guardTargetAllowed),
        tostring(trace.selectedCandidateId), tostring(trace.targetCommandId),
        tostring(trace.targetBeforeId), tostring(trace.targetAfterId),
        tostring(trace.targetCommandOk)))
end

local function appendUnique(list, value)
    if type(list) ~= 'table' then return end

    for _, existing in ipairs(list) do
        if existing == value then
            return
        end
    end

    list[#list + 1] = value
end

function M.extendModes(MODES)
    -- Created by: NeroMorte - custom Primary Control mode
    MODES.PRIMARY = MODES.PRIMARY or { 'Manual', 'Puller', 'Assist' }

    local hasPetPuller = false
    for _, mode in ipairs(MODES.PRIMARY) do
        if mode == 'Pet Puller' then
            hasPetPuller = true
            break
        end
    end

    if not hasPetPuller then
        table.insert(MODES.PRIMARY, 'Pet Puller')
    end

    MODES.DESC = MODES.DESC or {}
    MODES.DESC['Pet Puller'] =
        'Pets pull enemies to camp; the player engages only inside Guard Assist Radius.'
    if type(MODES) ~= 'table' then return end

    MODES.SUBMODES = MODES.SUBMODES or {}
    MODES.SUBMODES.Puller = MODES.SUBMODES.Puller or { 'Hunt', 'Camp' }

    appendUnique(MODES.SUBMODES.Puller, 'Guard')

    MODES.SUB_DESC = MODES.SUB_DESC or {}
    MODES.SUB_DESC['Puller:Guard'] =
        'Guards the camp area, engages eligible enemies only within the allowed Guard range, then returns to camp after combat.'
end

function M.usesStartCamp(ctrl)
    if not ctrl then
        return false
    end

    if ctrl.mode == 'Pet Puller' then
        return true
    end

    return ctrl.mode == 'Puller'
        and (ctrl.submode == 'Camp' or ctrl.submode == 'Guard')
end

function M.isGuardMode(ctrl)
    return ctrl ~= nil and ctrl.mode == 'Puller' and ctrl.submode == 'Guard'
end
function M.isValidPrimaryMode(mode)
    return mode == 'Manual'
        or mode == 'Puller'
        or mode == 'Assist'
        or mode == 'Pet Puller'
end
function M.isValidPullerSubmode(submode)
    return submode == 'Hunt'
        or submode == 'Camp'
        or submode == 'Guard'
end

function M.sanitizeCtrl(ctrl)
    if not ctrl then return end

    if ctrl.guard_assist_radius == nil then
        ctrl.guard_assist_radius = 50
    end

    if ctrl.camp_return_radius == nil then
        ctrl.camp_return_radius = 15
    end

    ctrl.guard_assist_radius = math.max(
        10,
        math.min(1000, tonumber(ctrl.guard_assist_radius) or 50)
    )

    ctrl.camp_return_radius = math.max(
        3,
        math.min(50, tonumber(ctrl.camp_return_radius) or 15)
    )
end

function M.drawPetPullerSettings(ctx)
    if not ctx or not ctx.ctrl or not ctx.ImGui then
        return
    end

    if ctx.ctrl.mode ~= 'Pet Puller' then
        return
    end

    local mq = require('mq')

    local ImGui   = ctx.ImGui
    local ctrl    = ctx.ctrl
    local runtime = ctx.runtime or {}
    local accent  = ctx.accent
    local GOLD    = ctx.GOLD
    local MUTED   = ctx.MUTED

    local function saveSettings()
        if runtime.saveLoadout then
            runtime.saveLoadout(true)
        end
    end

    local function muted(text)
        if accent and MUTED then
            accent(MUTED, text)
        else
            ImGui.TextDisabled(text)
        end
    end

    local function heading(text)
        if accent and GOLD then
            accent(GOLD, text)
        else
            ImGui.Text(text)
        end
    end

    ImGui.Separator()

    heading('Pet Puller Camp Location')

    if ctrl.camp_loc then
        ImGui.Text(string.format(
            'Camp set at: %.1f, %.1f, %.1f',
            ctrl.camp_loc.x or 0,
            ctrl.camp_loc.y or 0,
            ctrl.camp_loc.z or 0
        ))
    else
        muted('No camp location set -- Pet Puller requires a camp position.')
    end

    if ImGui.Button('Set Here##petPullerCampSet') then
        local mx, my, mz

        pcall(function()
            mx = mq.TLO.Me.X()
            my = mq.TLO.Me.Y()
            mz = mq.TLO.Me.Z()
        end)

        if mx and my and mz then
            if runtime.stopMoving then
                runtime.stopMoving()
            end
            ctrl.camp_loc = {
                x = mx,
                y = my,
                z = mz
            }
            resetPetPullerState()
            state.petPullerNoCampStopped = false

            saveSettings()

            if runtime.updateMapRadiusVisuals then
                runtime.updateMapRadiusVisuals()
            end
        end
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(
            'Set current position as the Pet Puller camp. Player remains based here while pets perform pulls.'
        )
    end

    ImGui.SameLine()

    if ImGui.Button('Clear Camp##petPullerCampClear') then
        M.clearPetPullerCamp(ctrl, runtime)
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip('Clear the Pet Puller camp location.')
    end

    ImGui.SetNextItemWidth(180)

    local pullRad, pullRadChanged = ImGui.SliderInt(
        'Pull Radius##petPullerRadius',
        ctrl.camp_radius or 100,
        10,
        10000
    )

    if pullRadChanged then
        ctrl.camp_radius = pullRad
        saveSettings()

        if runtime.updateMapRadiusVisuals then
            runtime.updateMapRadiusVisuals()
        end
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(
            'Maximum horizontal distance from camp to search for mobs that the pets may pull.'
        )
    end

    ImGui.SetNextItemWidth(180)

    local campZ, campZChanged = ImGui.SliderInt(
        'Pull Height Diff (Z)##petPullerZ',
        ctrl.camp_z or 75,
        10,
        300
    )

    if campZChanged then
        ctrl.camp_z = campZ
        saveSettings()
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(
            'Maximum vertical height difference above or below camp for eligible pull targets.'
        )
    end

    ImGui.SetNextItemWidth(180)

    local minLevel, minChanged = ImGui.SliderInt(
        'Min NPC Level##petPullerMinLevel',
        ctrl.pull_min_level or 1,
        1,
        100
    )

    if minChanged then
        ctrl.pull_min_level = minLevel

        if ctrl.pull_min_level > (ctrl.pull_max_level or 100) then
            ctrl.pull_max_level = ctrl.pull_min_level
        end

        saveSettings()
    end

    ImGui.SameLine()
    ImGui.SetNextItemWidth(180)

    local maxLevel, maxChanged = ImGui.SliderInt(
        'Max NPC Level##petPullerMaxLevel',
        ctrl.pull_max_level or 100,
        1,
        100
    )

    if maxChanged then
        ctrl.pull_max_level = maxLevel

        if ctrl.pull_max_level < (ctrl.pull_min_level or 1) then
            ctrl.pull_min_level = ctrl.pull_max_level
        end

        saveSettings()
    end

    ImGui.SetNextItemWidth(180)

    local guardRadius, guardChanged = ImGui.SliderInt(
        'Guard Assist Radius##petPullerGuardRadius',
        ctrl.guard_assist_radius or 50,
        10,
        1000
    )

    if guardChanged then
        ctrl.guard_assist_radius = guardRadius
        saveSettings()
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(
            'Distance around camp where the player may personally engage mobs after the pets bring them home.'
        )
    end

    ImGui.SetNextItemWidth(180)

    local returnRadius, returnChanged = ImGui.SliderInt(
        'Camp Return Radius##petPullerReturnRadius',
        ctrl.camp_return_radius or 15,
        3,
        50
    )

    if returnChanged then
        ctrl.camp_return_radius = returnRadius
        saveSettings()
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(
            'How close the player must return to the exact camp location before being considered home.'
        )
    end

    ImGui.SetNextItemWidth(180)

    local xtarRange, xtarChanged = ImGui.SliderInt(
        'Max XTarget Chase Range##petPullerXtar',
        ctrl.xtar_nav_dist or 150,
        25,
        300
    )

    if xtarChanged then
        ctrl.xtar_nav_dist = xtarRange
        saveSettings()
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(
            'Maximum distance used when dealing with active NPCs on Extended Target.'
        )
    end

    --------------------------------------------------------------------------
    -- Created by: NeroMorte - Pet Puller Target Filters##NeroMorte
    --------------------------------------------------------------------------

    ImGui.Separator()
    heading('Pet Puller Target Filters')

    heading('Target Faction Considerations')
    muted('Select which NPC faction considerations Pet Puller is allowed to auto-target.')

    local pullConList = {
        'Scowling',
        'Threateningly',
        'Dubious',
        'Apprehensive',
        'Indifferent',
        'Amiably',
        'Kindly',
        'Warmly',
        'Ally',
    }

    ctrl.pull_con_filter = ctrl.pull_con_filter or {
        ['Scowling']      = true,
        ['Threateningly'] = true,
        ['Dubious']       = true,
        ['Apprehensive']  = true,
        ['Indifferent']   = true,
        ['Amiably']       = true,
        ['Kindly']        = true,
        ['Warmly']        = true,
        ['Ally']          = true,
    }

    if ImGui.Button('Select All##petPullConAll') then
        for _, conName in ipairs(pullConList) do
            ctrl.pull_con_filter[conName] = true
        end

        saveSettings()
    end

    ImGui.SameLine()

    if ImGui.Button('Hostile Only##petPullConHostile') then
        for _, conName in ipairs(pullConList) do
            ctrl.pull_con_filter[conName] =
                conName == 'Scowling'
                or conName == 'Threateningly'
                or conName == 'Dubious'
                or conName == 'Apprehensive'
        end

        saveSettings()
    end

    ImGui.SameLine()

    if ImGui.Button('Hostile + Indifferent##petPullConHostileIndiff') then
        for _, conName in ipairs(pullConList) do
            ctrl.pull_con_filter[conName] =
                conName == 'Scowling'
                or conName == 'Threateningly'
                or conName == 'Dubious'
                or conName == 'Apprehensive'
                or conName == 'Indifferent'
        end

        saveSettings()
    end

    ImGui.SameLine()

    if ImGui.Button('Clear All##petPullConClear') then
        for _, conName in ipairs(pullConList) do
            ctrl.pull_con_filter[conName] = false
        end

        saveSettings()
    end

    for idx, conName in ipairs(pullConList) do
        local current = ctrl.pull_con_filter[conName] == true

        local newValue, changed = ImGui.Checkbox(
            conName .. '##petPullCon_' .. conName,
            current
        )

        if changed then
            ctrl.pull_con_filter[conName] = newValue
            saveSettings()
        end

        if (idx % 3) ~= 0 and idx ~= #pullConList then
            ImGui.SameLine()
        end
    end

    --------------------------------------------------------------------------
    -- Include List
    --------------------------------------------------------------------------

    heading('NPCs to Pull (Include List)')
    muted('If empty, pulls any mob in radius. If populated, ONLY pulls listed names.')

    if ImGui.Button('Pull Current Target##petPullCurrent', 170, 24) then
        local nm

        pcall(function()
            nm = mq.TLO.Target.CleanName()
        end)

        if nm and nm ~= '' then
            if runtime.addPull then
                runtime.addPull(nm)
            end
        else
            print('\ay[Triune]\ax no target selected.')
        end
    end

    ImGui.SameLine()
    ImGui.SetNextItemWidth(180)

    runtime.petPullInput = ImGui.InputText(
        '##petPullAddInput',
        runtime.petPullInput or ''
    )

    ImGui.SameLine()

    if ImGui.Button('Add##petPullAdd') then
        if runtime.petPullInput and runtime.petPullInput ~= '' then
            if runtime.addPull then
                runtime.addPull(runtime.petPullInput)
            end

            runtime.petPullInput = ''
        end
    end

    if ImGui.BeginChild('petPullListFrame', 0, 90, true) then
        if not runtime.pullList or #runtime.pullList == 0 then
            ImGui.TextDisabled('(all mobs allowed)')
        else
            for i, nm in ipairs(runtime.pullList) do
                ImGui.PushID('pet_pl_' .. i)

                if ImGui.Button('x') then
                    if runtime.removePull then
                        runtime.removePull(nm)
                    end
                end

                ImGui.SameLine()
                ImGui.Text(tostring(nm))
                ImGui.PopID()
            end
        end
    end

    ImGui.EndChild()

    --------------------------------------------------------------------------
    -- Ignore List
    --------------------------------------------------------------------------

    heading('NPCs to Ignore (Ignore List)')
    muted('Pet Puller will NEVER auto-target these names. Uses the same shared Ignore List as Puller.')

    if ImGui.Button('Ignore Current Target##petIgnoreCurrent', 170, 24) then
        local nm

        pcall(function()
            nm = mq.TLO.Target.CleanName()
        end)

        if nm and nm ~= '' then
            if mq.TLO.Me.Combat() then
                mq.cmd('/attack off')
            end

            if runtime.addIgnore then
                runtime.addIgnore(nm)
            end
        else
            print('\ay[Triune]\ax no target selected.')
        end
    end

    ImGui.SameLine()
    ImGui.SetNextItemWidth(180)

    runtime.petIgnoreInput = ImGui.InputText(
        '##petIgnoreAddInput',
        runtime.petIgnoreInput or ''
    )

    ImGui.SameLine()

    if ImGui.Button('Add##petIgnoreAdd') then
        if runtime.petIgnoreInput and runtime.petIgnoreInput ~= '' then
            if runtime.addIgnore then
                runtime.addIgnore(runtime.petIgnoreInput)
            end

            runtime.petIgnoreInput = ''
        end
    end

    if ImGui.BeginChild('petIgnoreListFrame', 0, 90, true) then
        if not runtime.ignoreList or #runtime.ignoreList == 0 then
            ImGui.TextDisabled('(none ignored)')
        else
            for i, nm in ipairs(runtime.ignoreList) do
                ImGui.PushID('pet_ig_' .. i)

                if ImGui.Button('x') then
                    if runtime.removeIgnore then
                        runtime.removeIgnore(nm)
                    end
                end

                ImGui.SameLine()
                ImGui.Text(tostring(nm))
                ImGui.PopID()
            end
        end
    end

    ImGui.EndChild()

    ImGui.Separator()
    muted('Pets pull to camp; the player engages only inside Guard Assist Radius.')
end

function M.initializeStartCamp(ctrl, runtime)
    if not M.usesStartCamp(ctrl) or ctrl.camp_loc then
        return false
    end

    local myX, myY, myZ
    pcall(function()
        myX = mq.TLO.Me.X()
        myY = mq.TLO.Me.Y()
        myZ = mq.TLO.Me.Z()
    end)

    if myX == nil or myY == nil or myZ == nil then
        return false
    end

    ctrl.camp_loc = { x = myX, y = myY, z = myZ }

    if runtime and runtime.saveLoadout then
        runtime.saveLoadout(true)
    end
    if runtime and runtime.updateMapRadiusVisuals then
        runtime.updateMapRadiusVisuals()
    end

    print(string.format(
        '\ag[Triune]\ax %s: Set camp location at START (Y:%.1f, X:%.1f, Z:%.1f)',
        ctrl.mode == 'Pet Puller' and 'Pet Puller' or 'Puller (Camp)',
        myY,
        myX,
        myZ
    ))
    return true
end

function M.clearPetPullerCamp(ctrl, runtime)
    if not ctrl or ctrl.mode ~= 'Pet Puller' then
        return false
    end

    if runtime and runtime.stopMoving then
        runtime.stopMoving()
    end

    ctrl.camp_loc = nil
    resetPetPullerState()
    state.petPullerNoCampStopped = true

    if runtime and runtime.clearTarget then
        runtime.clearTarget()
    end
    if runtime and runtime.saveLoadout then
        runtime.saveLoadout(true)
    end
    if runtime and runtime.updateMapRadiusVisuals then
        runtime.updateMapRadiusVisuals()
    end

    return true
end
function M.drawGuardSettings(ctx)
    local ImGui = ctx and ctx.ImGui
    local ctrl = ctx and ctx.ctrl
    local runtime = ctx and ctx.runtime
    local accent = ctx and ctx.accent
    local GOLD = ctx and ctx.GOLD
    local MUTED = ctx and ctx.MUTED

    if not ImGui or not ctrl then
        return
    end

    M.sanitizeCtrl(ctrl)

    ImGui.Dummy(0, 2)

    if accent and GOLD then
        accent(GOLD, 'Guard Movement')
    else
        ImGui.Text('Guard Movement')
    end

    ImGui.SetNextItemWidth(180)
    local assistRadius, assistChanged = ImGui.SliderInt(
        'Guard Assist Radius##guardAssistRadius',
        ctrl.guard_assist_radius or 50,
        10,
        1000
    )

    if assistChanged then
        ctrl.guard_assist_radius = assistRadius
        if runtime and runtime.saveLoadout then
            runtime.saveLoadout(true)
        end
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(
            'Maximum distance from the Camp center that the player may travel to personally engage an enemy.\n'
            .. 'Guard will never chase farther than this setting, even if Pull Radius is larger.'
        )
    end

    ImGui.SetNextItemWidth(180)
    local returnRadius, returnChanged = ImGui.SliderInt(
        'Camp Return Radius##guardReturnRadius',
        ctrl.camp_return_radius or 15,
        3,
        50
    )

    if returnChanged then
        ctrl.camp_return_radius = returnRadius
        if runtime and runtime.saveLoadout then
            runtime.saveLoadout(true)
        end
    end

    if ImGui.IsItemHovered() then
        ImGui.SetTooltip(
            'How close the player must return to the saved Camp location before Guard considers the character back at camp.\n'
            .. 'Smaller values return closer to the exact saved camp point.'
        )
    end

    local petSearchRadius = tonumber(ctrl.camp_radius) or 100
    local ownerAssistRadius = tonumber(ctrl.guard_assist_radius) or 50

    if accent and MUTED then
        accent(
            MUTED,
            string.format(
                'Pet search range: %d | Owner assist range: %d',
                math.floor(petSearchRadius),
                math.floor(ownerAssistRadius)
            )
        )
    else
        ImGui.Text(
            string.format(
                'Pet search range: %d | Owner assist range: %d',
                math.floor(petSearchRadius),
                math.floor(ownerAssistRadius)
            )
        )
    end
end

local function getSpawn(id)
    if not id or id <= 0 then return nil end

    local spawn = mq.TLO.Spawn(id)
    if not spawn or not spawn() then return nil end

    return spawn
end

local function distanceFromCamp(ctrl, id)
    if not ctrl or not ctrl.camp_loc then return math.huge end

    local spawn = getSpawn(id)
    if not spawn then return math.huge end

    local sx, sy, sz
    pcall(function()
        sx = spawn.X()
        sy = spawn.Y()
        sz = spawn.Z()
    end)

    if not sx or not sy then
        return math.huge
    end

    local dx = sx - ctrl.camp_loc.x
    local dy = sy - ctrl.camp_loc.y

    return math.sqrt(dx * dx + dy * dy), sz
end

local function playerDistanceFromCamp(ctrl)
    if not ctrl or not ctrl.camp_loc then return math.huge end

    local x = mq.TLO.Me.X()
    local y = mq.TLO.Me.Y()

    if not x or not y then
        return math.huge
    end

    local dx = x - ctrl.camp_loc.x
    local dy = y - ctrl.camp_loc.y

    return math.sqrt(dx * dx + dy * dy)
end

local function targetAllowed(ctrl, runtime, id, radius)
    local spawn = getSpawn(id)
    if not spawn then return false end

    local spawnType = ''
    local dead = false

    pcall(function()
        spawnType = spawn.Type() or ''
        dead = spawn.Dead() or false
    end)

    if spawnType ~= 'NPC' or dead or spawnType == 'Corpse' then
        return false
    end

    local name = ''
    pcall(function() name = spawn.CleanName() or '' end)

    if runtime.isIgnored and runtime.isIgnored(name) then
        return false
    end

    if runtime.isUnreachable and runtime.isUnreachable(id) then
        return false
    end

    local horizontalDistance, spawnZ = distanceFromCamp(ctrl, id)

    if horizontalDistance > radius then
        return false
    end

    if spawnZ and ctrl.camp_loc.z then
        local maxZ = tonumber(ctrl.camp_z) or 75

        if math.abs(spawnZ - ctrl.camp_loc.z) > maxZ then
            return false
        end
    end

    local level = 0
    pcall(function() level = spawn.Level() or 0 end)

    local minLevel = tonumber(ctrl.pull_min_level) or 1
    local maxLevel = tonumber(ctrl.pull_max_level) or 100

    if level > 0 and (level < minLevel or level > maxLevel) then
        return false
    end

    local isXTarget = runtime.isXTargetId
        and runtime.isXTargetId(id)
        or false

    if not isXTarget
        and runtime.verifyTargetCon
        and not runtime.verifyTargetCon(id, true)
    then
        return false
    end

    return true
end

local function acquireCampRoamTarget(ctrl, runtime, radius, guardTrace)
    if not runtime.findRoamTarget then
        return nil, radius, 'runtime.findRoamTarget is unavailable'
    end

    -- findRoamTarget's NearestSpawn query is player-centered, while Guard
    -- admission is camp-centered. HOME permits a nonzero player/camp offset,
    -- so widen only the scan circle and retain the exact Guard camp cap via
    -- the optional anchor-radius override.
    local playerCampDistance = playerDistanceFromCamp(ctrl)
    if playerCampDistance == math.huge then playerCampDistance = 0 end
    local scanRadius = radius + math.max(0, playerCampDistance)

    local ok, id = pcall(
        runtime.findRoamTarget,
        scanRadius,
        tonumber(ctrl.camp_z) or 75,
        tonumber(ctrl.pull_min_level) or 1,
        tonumber(ctrl.pull_max_level) or 100,
        true,
        radius,
        guardTrace
    )

    if not ok then
        if guardTrace then
            guardTrace.acquireCampRoamTargetResult = nil
            guardTrace.acquireError = tostring(id)
        end
        return nil, scanRadius, tostring(id)
    end

    if guardTrace then guardTrace.acquireCampRoamTargetResult = id end
    return id, scanRadius, nil
end

local function debugGuardCandidateRejections(ctrl, runtime, effectiveRadius, scanRadius)
    if not ctrl.debug_mode then return end

    local maxZ = tonumber(ctrl.camp_z) or 75
    local query = string.format('npc radius %d zradius %d targetable', math.ceil(scanRadius), maxZ)
    local found = 0
    for i = 1, 5 do
        local spawn = mq.TLO.NearestSpawn(i, query)
        if not spawn or not spawn() then break end
        found = found + 1

        local id = spawn.ID() or 0
        local name = spawn.CleanName() or ''
        local spawnType = spawn.Type() or ''
        local dead = spawn.Dead() or false
        local stateName = spawn.State and spawn.State() or ''
        local level = spawn.Level() or 0
        local campDistance, spawnZ = distanceFromCamp(ctrl, id)
        local reasons = {}

        if spawnType ~= 'NPC' then reasons[#reasons + 1] = 'not NPC' end
        if dead or spawnType == 'Corpse' or stateName == 'DEAD' then reasons[#reasons + 1] = 'dead/corpse' end
        if campDistance > effectiveRadius then reasons[#reasons + 1] = 'outside camp radius' end
        if spawnZ and ctrl.camp_loc.z and math.abs(spawnZ - ctrl.camp_loc.z) > maxZ then
            reasons[#reasons + 1] = 'Z'
        end
        local minLevel = tonumber(ctrl.pull_min_level) or 1
        local maxLevel = tonumber(ctrl.pull_max_level) or 100
        if level > 0 and (level < minLevel or level > maxLevel) then reasons[#reasons + 1] = 'level' end
        if runtime.isSpawnPetOrPlayer and runtime.isSpawnPetOrPlayer(id) then
            reasons[#reasons + 1] = 'player/pet'
        end
        if runtime.isIgnored and runtime.isIgnored(name) then reasons[#reasons + 1] = 'ignored' end
        if runtime.isUnreachable and runtime.isUnreachable(id) then reasons[#reasons + 1] = 'unreachable' end
        if runtime.isPullAllowed and not runtime.isPullAllowed(name) then reasons[#reasons + 1] = 'Pull Include/Ignore' end
        if runtime.isConAllowed and not runtime.isConAllowed(spawn) then reasons[#reasons + 1] = 'con/faction' end
        if runtime.isHostileTarget and not runtime.isHostileTarget(id) then reasons[#reasons + 1] = 'hostile validation' end

        local sx, sy, sz = spawn.X() or 0, spawn.Y() or 0, spawn.Z() or 0
        if runtime.isCoordInActiveHazard and runtime.isCoordInActiveHazard(sx, sy, sz)
            and (ctrl.combat_style or 'Melee') == 'Melee'
        then
            reasons[#reasons + 1] = 'hazard'
        end

        local pathStatus = 'not-required'
        local navReady = runtime.navLoaded and runtime.navLoaded()
        local playerOffMesh = runtime.isPlayerOffMesh and runtime.isPlayerOffMesh()
        if navReady and not playerOffMesh then
            local meshLoaded = false
            pcall(function() meshLoaded = mq.TLO.Navigation.MeshLoaded() or false end)
            if meshLoaded then
                local directDistance = spawn.Distance3D() or spawn.Distance() or math.huge
                local closeReach = runtime.desiredRange and runtime.desiredRange(id) or 14
                local hasLoS = runtime.hasLoS and runtime.hasLoS(id) or false
                if directDistance > closeReach or not hasLoS then
                    local pathExists = false
                    local pathOk = pcall(function()
                        pathExists = mq.TLO.Navigation.PathExists('id ' .. id)() or false
                    end)
                    pathStatus = pathOk and (pathExists and 'yes' or 'no') or 'error'
                    if pathOk and not pathExists then
                        reasons[#reasons + 1] = 'path'
                    elseif pathOk and pathExists then
                        local pathLength = 0
                        pcall(function()
                            pathLength = mq.TLO.Navigation.PathLength('id ' .. id)() or 0
                        end)
                        local maxRatio = tonumber(ctrl.nav_max_path_ratio) or 2.5
                        if pathLength > 0 and directDistance > 20
                            and (pathLength / directDistance) > maxRatio
                        then
                            reasons[#reasons + 1] = 'path ratio'
                        end
                    end
                end
            end
        end

        debugGuard(ctrl, string.format(
            'Candidate #%d %s: campDist=%.1f targetable=yes alive=%s level=%d Z=%.1f path=%s RESULT=%s',
            id, name, campDistance, tostring(not dead and stateName ~= 'DEAD'), level,
            spawnZ and math.abs(spawnZ - (ctrl.camp_loc.z or spawnZ)) or 0,
            pathStatus, #reasons == 0 and 'VALID' or ('REJECT: ' .. table.concat(reasons, ', '))))
    end

    if found == 0 then
        debugGuard(ctrl, string.format('No targetable NPCs returned by NearestSpawn query: %s', query))
    end
end

local function returnToCamp(ctrl, runtime)
    if not ctrl.camp_loc then
        return
    end

    if runtime.moveTowardLoc then
        runtime.moveTowardLoc(
            ctrl.camp_loc.x,
            ctrl.camp_loc.y,
            ctrl.camp_loc.z,
            tonumber(ctrl.camp_return_radius) or 15
        )
    end
end

function M.syncMode(ctrl, runtime)
    local mode = ctrl and ctrl.mode or nil
    local guardActive = M.isGuardMode(ctrl)
    if state.guardObservedActive ~= guardActive then
        resetGuardState(runtime, false)
        state.guardObservedActive = guardActive
    end
    if state.observedMode == mode then
        return
    end

    local previousMode = state.observedMode
    state.observedMode = mode

    if mode == 'Pet Puller' then
        resetPetPullerState()
        state.petPullerNoCampStopped = not (ctrl and ctrl.camp_loc)
        if runtime and runtime.stopMoving then
            runtime.stopMoving()
        end
        mq.cmd('/say #petcmd assist on all')
        debugPetPuller(ctrl, 'Pet assist enabled; player movement reset for camp operation.')
    elseif previousMode == 'Pet Puller' then
        resetPetPullerState()
        state.petPullerNoCampStopped = false
    end
end

local function returnPetPullerToCamp(ctrl, runtime)
    state.petPullerReturning = true
    returnToCamp(ctrl, runtime)
end

local function finishPetPullerReturn(runtime)
    if state.petPullerReturning and runtime.stopMoving then
        runtime.stopMoving()
    end
    state.petPullerReturning = false
end

function M.canPetPullerEngageTarget(ctrl, targetId)
    if not ctrl or ctrl.mode ~= 'Pet Puller' then
        return true
    end
    if not ctrl.camp_loc then
        return false
    end

    local spawn = getSpawn(targetId)
    if not spawn then
        return false
    end

    local spawnType = ''
    local dead = false
    pcall(function()
        spawnType = spawn.Type() or ''
        dead = spawn.Dead() or false
    end)
    if spawnType ~= 'NPC' or dead then
        return false
    end

    local distance, spawnZ = distanceFromCamp(ctrl, targetId)
    local effectiveRadius = math.min(
        tonumber(ctrl.camp_radius) or 100,
        tonumber(ctrl.guard_assist_radius) or 50
    )
    if distance > effectiveRadius then
        return false
    end

    if spawnZ and ctrl.camp_loc.z then
        local maxZ = tonumber(ctrl.camp_z) or 75
        if math.abs(spawnZ - ctrl.camp_loc.z) > maxZ then
            return false
        end
    end

    return true
end

local function isLiveGuardThreat(runtime, id)
    local spawn = getSpawn(id)
    if not spawn then return false end

    local spawnType = ''
    local dead = false
    pcall(function()
        spawnType = spawn.Type() or ''
        dead = spawn.Dead() or false
    end)
    if (spawnType ~= 'NPC' and spawnType ~= 'Pet') or dead or spawnType == 'Corpse' then
        return false
    end
    if runtime and runtime.isHostileTarget and not runtime.isHostileTarget(id) then
        return false
    end
    return true
end

local function isDirectMasterThreat(runtime, id)
    if not isLiveGuardThreat(runtime, id) then return false end

    local meId = mq.TLO.Me.ID() or 0
    if meId <= 0 then return false end

    local spawn = getSpawn(id)
    local targetOfTargetId = 0
    local aggroHolderId = 0
    pcall(function() targetOfTargetId = spawn.TargetOfTarget.ID() or 0 end)
    pcall(function() aggroHolderId = spawn.AggroHolder.ID() or 0 end)
    return targetOfTargetId == meId or aggroHolderId == meId
end

function M.canGuardOwnerEngageTarget(ctrl, targetId)
    if not M.isGuardMode(ctrl) then return true end
    if not ctrl.camp_loc or not targetId or targetId <= 0 then return false end
    if isDirectMasterThreat(nil, targetId) then return true end
    return state.guardOwnerEngageTargetId == targetId
        and (state.guardPhase == 'MASTER_DEFENSE' or state.guardPhase == 'OWNER_DEFENSE')
end

function M.isGuardDirectMasterThreatTarget(ctrl, targetId)
    if not M.isGuardMode(ctrl) then return false end
    return (state.guardPhase == 'MASTER_DEFENSE' and state.guardOwnerEngageTargetId == targetId)
        or isDirectMasterThreat(nil, targetId)
end

function M.canOwnerEngageTarget(ctrl, targetId)
    return M.canPetPullerEngageTarget(ctrl, targetId)
        and M.canGuardOwnerEngageTarget(ctrl, targetId)
end

function M.shouldPreserveGuardDispatchAttack(ctrl)
    return M.isGuardMode(ctrl)
        and (tonumber(state.guardDispatchAttackId) or 0) > 0
end

function M.isGenericCombatReady(ctrl, haveNPC, engage)
    if not ctrl or ctrl.mode ~= 'Pet Puller' then
        return not haveNPC or engage
    end
    return haveNPC == true and engage == true
end

function M.shouldPreservePetPullerDispatchAttack(ctrl)
    return ctrl ~= nil
        and ctrl.mode == 'Pet Puller'
        and (tonumber(state.petPullerDispatchAttackId) or 0) > 0
end

function M.getPetPullerStatus(ctrl)
    return {
        phase = state.petPullerPhase or 'IDLE',
        targetId = tonumber(state.petPullerCandidateId) or 0,
        playerCampDistance = playerDistanceFromCamp(ctrl),
        effectiveAssistRadius = math.min(
            tonumber(ctrl and ctrl.camp_radius) or 100,
            tonumber(ctrl and ctrl.guard_assist_radius) or 50
        ),
    }
end

function M.drawPetPullerCompactStatus(ctx)
    local ImGui = ctx and ctx.ImGui
    local ctrl = ctx and ctx.ctrl
    if not ImGui or not ctrl or ctrl.mode ~= 'Pet Puller' then
        return
    end

    local status = M.getPetPullerStatus(ctrl)
    if ctrl.camp_loc then
        ImGui.TextDisabled(string.format(
            'Camp: %.1f, %.1f, %.1f | %s | Target #%d',
            ctrl.camp_loc.x or 0,
            ctrl.camp_loc.y or 0,
            ctrl.camp_loc.z or 0,
            status.phase,
            status.targetId
        ))
    else
        ImGui.TextDisabled('Camp: Not set | Pet Puller idle')
    end
end

local function isLiveHostile(ctrl, runtime, id)
    local spawn = getSpawn(id)
    if not spawn then return false end

    local spawnType = ''
    local dead = false
    pcall(function()
        spawnType = spawn.Type() or ''
        dead = spawn.Dead() or false
    end)
    if spawnType ~= 'NPC' or dead then return false end

    local name = ''
    pcall(function() name = spawn.CleanName() or '' end)
    if runtime.isIgnored and runtime.isIgnored(name) then return false end
    if runtime.isHostileTarget and not runtime.isHostileTarget(id) then return false end
    return true
end

local function findPetPullerXTargets(ctrl, runtime, effectiveRadius)
    local nearId, nearDistance = 0, math.huge
    local farId, farDistance = 0, math.huge
    local slots = 13
    pcall(function() slots = mq.TLO.Me.XTargetSlots() or 13 end)

    for i = 1, slots do
        local xt = mq.TLO.Me.XTarget(i)
        local id = 0
        pcall(function()
            if xt and xt() then id = xt.ID() or 0 end
        end)

        if id > 0
            and runtime.isXTargetId
            and runtime.isXTargetId(id)
            and isLiveHostile(ctrl, runtime, id)
        then
            local distance = distanceFromCamp(ctrl, id)
            if distance <= effectiveRadius then
                if distance < nearDistance then
                    nearId = id
                    nearDistance = distance
                end
            elseif distance < farDistance then
                farId = id
                farDistance = distance
            end
        end
    end

    return nearId, farId
end

local function releasePetPullerCandidate()
    releasePetPullerDispatchAttack()
    state.petPullerCandidateId = 0
    state.petPullerAttackSentId = 0
    state.petPullerRecallSentId = 0
    state.petPullerPlayerTargetClearedId = 0
    state.petPullerLastTargetAttemptAt = 0
    state.petPullerTargetSettleId = 0
    state.petPullerTargetSettleAt = 0
    state.petPullerDispatchStartedAt = 0
    state.petPullerPetTargetSeenId = 0
    state.petPullerPetTargetLostAt = 0
end

local function recallPetPullerPets(ctrl, targetId)
    if targetId <= 0 or state.petPullerRecallSentId == targetId then
        return
    end

    mq.cmd('/say #petcmd back all')
    state.petPullerRecallSentId = targetId
    debugPetPuller(ctrl, string.format('Recalled pets after XTarget engagement on #%d.', targetId))
end

local function clearPetPullerPlayerTarget(runtime, targetId)
    if targetId <= 0 or state.petPullerPlayerTargetClearedId == targetId then
        return
    end

    local currentId = mq.TLO.Target.ID() or 0
    if currentId == targetId then
        if runtime.clearTarget then
            runtime.clearTarget()
        else
            mq.cmd('/target clear')
        end
    end
    state.petPullerPlayerTargetClearedId = targetId
end

local function failPetPullerCandidate(ctrl, runtime, targetId, reason)
    releasePetPullerDispatchAttack()
    if state.petPullerOwnerEngageAttackId == targetId then
        releasePetPullerOwnerEngageAttack()
    end
    if state.petPullerAttackSentId == targetId then
        recallPetPullerPets(ctrl, targetId)
    end
    clearPetPullerPlayerTarget(runtime, targetId)
    releasePetPullerCandidate()
    state.petPullerPhase = 'HOME'
    debugPetPuller(ctrl, string.format('Cancelled pull candidate #%d: %s', targetId, reason))
end

local function beginPetPullerOwnerEngagement(runtime, targetId)
    local targeted = mq.TLO.Target.ID() == targetId
    if not targeted and runtime.setTarget then
        targeted = runtime.setTarget(targetId) == true
    end
    if not targeted then
        return false
    end

    -- A dispatch attack is only the one-shot pet-assist trigger. End it before
    -- starting the independently tracked, persistent owner combat attack.
    releasePetPullerDispatchAttack()
    local ownerAttackTracked = state.petPullerOwnerEngageAttackId == targetId
    local ownerAttackActive = mq.TLO.Me.Combat() or false
    if not ownerAttackTracked or not ownerAttackActive then
        if not ownerAttackTracked then
            releasePetPullerOwnerEngageAttack()
        end
        mq.cmd('/attack on')
        state.petPullerOwnerEngageAttackId = targetId
    end
    return true
end

function M.petPullerTick(ctrl, runtime)
    local result = {
        haveNPC = false,
        engage = false,
        returning = false,
        home = false,
        distance = 0,
        targetId = 0,
        petPullSent = false,
        phase = state.petPullerPhase or 'IDLE',
    }

    if not ctrl or not runtime or ctrl.mode ~= 'Pet Puller' then
        return result
    end

    M.syncMode(ctrl, runtime)
    M.sanitizeCtrl(ctrl)

    if not ctrl.camp_loc then
        if not state.petPullerNoCampStopped then
            if runtime.stopMoving then runtime.stopMoving() end
            state.petPullerNoCampStopped = true
        end
        resetPetPullerState()
        state.petPullerPhase = 'NO CAMP'
        result.phase = state.petPullerPhase
        return result
    end
    state.petPullerNoCampStopped = false

    local effectiveRadius = math.min(
        tonumber(ctrl.camp_radius) or 100,
        tonumber(ctrl.guard_assist_radius) or 50
    )
    local returnRadius = tonumber(ctrl.camp_return_radius) or 15
    local playerCampDistance = playerDistanceFromCamp(ctrl)
    result.distance = playerCampDistance

    local targetId = tonumber(state.petPullerCandidateId) or 0
    if targetId > 0 and not isLiveHostile(ctrl, runtime, targetId) then
        failPetPullerCandidate(ctrl, runtime, targetId, 'candidate died, disappeared, or became invalid')
        result.home = true
        result.phase = state.petPullerPhase
        return result
    end

    local ownerAttackId = tonumber(state.petPullerOwnerEngageAttackId) or 0
    if ownerAttackId > 0 then
        if not isLiveHostile(ctrl, runtime, ownerAttackId)
            or not M.canPetPullerEngageTarget(ctrl, ownerAttackId)
        then
            releasePetPullerOwnerEngageAttack()
        elseif beginPetPullerOwnerEngagement(runtime, ownerAttackId) then
            state.petPullerPhase = 'ENGAGING'
            result.haveNPC = true
            result.engage = true
            result.targetId = ownerAttackId
            result.phase = state.petPullerPhase
            return result
        end
    end

    local nearXTargetId, farXTargetId = findPetPullerXTargets(ctrl, runtime, effectiveRadius)
    local candidateIsConfirmedXTarget = targetId > 0
        and runtime.isXTargetId
        and runtime.isXTargetId(targetId)
        and isLiveHostile(ctrl, runtime, targetId)
    local candidateAwaitingXTarget = targetId > 0
        and state.petPullerAttackSentId == targetId
        and not candidateIsConfirmedXTarget
    if candidateIsConfirmedXTarget then
        releasePetPullerDispatchAttack()
        recallPetPullerPets(ctrl, targetId)
    end

    if nearXTargetId > 0 then
        finishPetPullerReturn(runtime)
        if beginPetPullerOwnerEngagement(runtime, nearXTargetId) then
            state.petPullerPhase = 'ENGAGING'
            state.petPullerPlayerTargetClearedId = 0
            result.haveNPC = true
            result.engage = true
            result.targetId = nearXTargetId
            result.phase = state.petPullerPhase
            return result
        end
        state.petPullerPhase = 'WAITING TO ENGAGE'
        result.targetId = nearXTargetId
        result.phase = state.petPullerPhase
        return result
    end

    if farXTargetId > 0
        and (not candidateAwaitingXTarget or farXTargetId == targetId)
    then
        releasePetPullerDispatchAttack()
        recallPetPullerPets(ctrl, farXTargetId)
        clearPetPullerPlayerTarget(runtime, farXTargetId)
        state.petPullerPhase = 'PULLING HOME'
        result.targetId = farXTargetId
        if playerCampDistance > returnRadius then
            returnPetPullerToCamp(ctrl, runtime)
            result.returning = true
        else
            finishPetPullerReturn(runtime)
            result.home = true
        end
        result.phase = state.petPullerPhase
        return result
    end

    if targetId > 0 then
        local candidateCampDistance = distanceFromCamp(ctrl, targetId)
        if candidateCampDistance <= effectiveRadius then
            finishPetPullerReturn(runtime)
            if beginPetPullerOwnerEngagement(runtime, targetId) then
                state.petPullerPhase = 'ENGAGING'
                state.petPullerPlayerTargetClearedId = 0
                result.haveNPC = true
                result.engage = true
                result.targetId = targetId
                result.phase = state.petPullerPhase
                return result
            end
            state.petPullerPhase = 'WAITING TO ENGAGE'
            result.targetId = targetId
            result.phase = state.petPullerPhase
            return result
        end

        result.targetId = targetId
        if playerCampDistance > returnRadius then
            state.petPullerPhase = 'RETURNING'
            returnPetPullerToCamp(ctrl, runtime)
            result.returning = true
            result.phase = state.petPullerPhase
            return result
        end
        finishPetPullerReturn(runtime)
        result.home = true

        if state.petPullerAttackSentId ~= targetId then
            local now = os.clock()
            if (now - (state.petPullerLastTargetAttemptAt or 0)) >= 0.75 then
                state.petPullerLastTargetAttemptAt = now
                local targeted = mq.TLO.Target.ID() == targetId
                if not targeted and runtime.setTarget then
                    targeted = runtime.setTarget(targetId) == true
                end

                if targeted then
                    if state.petPullerTargetSettleId ~= targetId then
                        state.petPullerTargetSettleId = targetId
                        state.petPullerTargetSettleAt = now
                        state.petPullerPhase = 'TARGETING'
                    elseif (now - (state.petPullerTargetSettleAt or now)) >= 0.35 then
                        mq.cmd('/say #petcmd qattack all')
                        mq.cmd('/attack on')
                        state.petPullerAttackSentId = targetId
                        state.petPullerDispatchAttackId = targetId
                        state.petPullerDispatchStartedAt = now
                        state.petPullerPetTargetSeenId = 0
                        state.petPullerPetTargetLostAt = 0
                        state.petPullerTargetSettleId = 0
                        state.petPullerTargetSettleAt = 0
                        state.petPullerRecallSentId = 0
                        state.petPullerPlayerTargetClearedId = 0
                        state.petPullerPhase = 'PETS OUT'
                        result.petPullSent = true
                        debugPetPuller(ctrl, string.format('Pets dispatched to pull #%d.', targetId))
                    end
                end
            end
        else
            local now = os.clock()
            local petTargetId = 0
            pcall(function() petTargetId = mq.TLO.Me.Pet.Target.ID() or 0 end)
            if petTargetId == targetId then
                state.petPullerPetTargetSeenId = targetId
                state.petPullerPetTargetLostAt = 0
            else
                if state.petPullerPetTargetSeenId == targetId then
                    if (state.petPullerPetTargetLostAt or 0) == 0 then
                        state.petPullerPetTargetLostAt = now
                    elseif (now - state.petPullerPetTargetLostAt) >= PET_PULLER_PET_TARGET_LOSS_GRACE then
                        failPetPullerCandidate(ctrl, runtime, targetId, 'pet lost the candidate before hostile XTarget confirmation')
                        result.targetId = 0
                        result.home = true
                        result.phase = state.petPullerPhase
                        return result
                    end
                end
            end

            if (now - (state.petPullerDispatchStartedAt or now)) >= PET_PULLER_DISPATCH_TIMEOUT then
                failPetPullerCandidate(ctrl, runtime, targetId, 'hostile XTarget confirmation timed out')
                result.targetId = 0
                result.home = true
                result.phase = state.petPullerPhase
                return result
            end
            state.petPullerPhase = 'PETS OUT'
        end

        result.phase = state.petPullerPhase
        return result
    end

    local ownerInCombat = mq.TLO.Me.Combat() or false
    if ownerInCombat then
        state.petPullerPhase = 'FINISHING'
        result.phase = state.petPullerPhase
        return result
    end

    if playerCampDistance > returnRadius then
        state.petPullerPhase = 'RETURNING'
        returnPetPullerToCamp(ctrl, runtime)
        result.returning = true
        result.phase = state.petPullerPhase
        return result
    end

    finishPetPullerReturn(runtime)
    result.home = true
    state.petPullerPhase = 'HOME'

    if runtime.findRoamTarget then
        local ok, foundId = pcall(function()
            return runtime.findRoamTarget(
                tonumber(ctrl.camp_radius) or 100,
                tonumber(ctrl.camp_z) or 75,
                tonumber(ctrl.pull_min_level) or 1,
                tonumber(ctrl.pull_max_level) or 100,
                true
            )
        end)

        if ok and foundId and foundId > 0 then
            state.petPullerCandidateId = foundId
            state.petPullerAttackSentId = 0
            state.petPullerRecallSentId = 0
            state.petPullerPlayerTargetClearedId = 0
            state.petPullerLastTargetAttemptAt = 0
            state.petPullerTargetSettleId = 0
            state.petPullerTargetSettleAt = 0
            state.petPullerDispatchStartedAt = 0
            state.petPullerPetTargetSeenId = 0
            state.petPullerPetTargetLostAt = 0
            state.petPullerPhase = 'CANDIDATE'
            result.targetId = foundId
            debugPetPuller(ctrl, string.format('Latched pull candidate #%d.', foundId))
        end
    end

    result.phase = state.petPullerPhase
    return result
end

M.petPullerReturnTick = M.petPullerTick

local function guardTargetAllowed(ctrl, runtime, id, petSearchRadius)
    if not targetAllowed(ctrl, runtime, id, petSearchRadius) then return false end
    if runtime.isPullAllowed then
        local spawn = getSpawn(id)
        local name = ''
        pcall(function() name = spawn.CleanName() or '' end)
        if not runtime.isPullAllowed(name) then return false end
    end
    return true
end

local function findGuardDirectMasterThreat(runtime, preferredId)
    if preferredId and preferredId > 0 and isDirectMasterThreat(runtime, preferredId) then
        return preferredId
    end

    local bestId = 0
    local bestDistance = math.huge
    local slots = 13
    pcall(function() slots = mq.TLO.Me.XTargetSlots() or 13 end)
    for i = 1, slots do
        local xt = mq.TLO.Me.XTarget(i)
        local id = 0
        pcall(function()
            if xt and xt() then id = xt.ID() or 0 end
        end)
        if id > 0 and isDirectMasterThreat(runtime, id) then
            local distance = math.huge
            pcall(function()
                local spawn = getSpawn(id)
                distance = spawn.Distance3D() or spawn.Distance() or math.huge
            end)
            if distance < bestDistance then
                bestId = id
                bestDistance = distance
            end
        end
    end
    return bestId
end

local function findGuardXTarget(ctrl, runtime, petSearchRadius, preferredId)
    if preferredId and preferredId > 0
        and runtime.isXTargetId and runtime.isXTargetId(preferredId)
        and guardTargetAllowed(ctrl, runtime, preferredId, petSearchRadius)
    then
        return preferredId
    end

    local bestId = 0
    local lowestHp = 101
    local slots = 13
    pcall(function() slots = mq.TLO.Me.XTargetSlots() or 13 end)
    for i = 1, slots do
        local xt = mq.TLO.Me.XTarget(i)
        local id = 0
        pcall(function()
            if xt and xt() then id = xt.ID() or 0 end
        end)
        if id > 0
            and runtime.isXTargetId and runtime.isXTargetId(id)
            and guardTargetAllowed(ctrl, runtime, id, petSearchRadius)
        then
            local hp = 100
            pcall(function() hp = getSpawn(id).PctHPs() or 100 end)
            if hp < lowestHp then
                bestId = id
                lowestHp = hp
            end
        end
    end
    return bestId
end

local function guardOwnerDefenseRadius(ctrl)
    return tonumber(ctrl.guard_assist_radius) or 50
end

local function isGuardNearOwnerDefense(ctrl, id)
    local campDistance = distanceFromCamp(ctrl, id)
    return campDistance <= guardOwnerDefenseRadius(ctrl)
end

local function clearGuardTarget(runtime, reason)
    local oldTargetId = tonumber(state.guardTargetId) or 0
    if oldTargetId > 0 then
        state.guardTraceLastClear = string.format('%s target=%d', tostring(reason or 'clearGuardTarget'), oldTargetId)
    end
    releaseGuardOwnedAttack()
    state.guardTargetId = 0
    state.guardTargetKind = nil
    state.guardPetCommandSentId = 0
    state.guardPetCommandAt = 0
    state.guardTargetSettleId = 0
    state.guardTargetSettleAt = 0
    state.lastGuardTargetId = 0
    if oldTargetId > 0 and mq.TLO.Target.ID() == oldTargetId
        and runtime and runtime.clearTarget
    then
        runtime.clearTarget()
    end
end

local function setGuardTarget(ctrl, runtime, targetId, targetKind)
    if targetId <= 0 then return false end

    if state.guardTargetId ~= targetId then
        local oldTargetId = tonumber(state.guardTargetId) or 0
        if oldTargetId > 0 then
            state.guardTraceLastClear = string.format('redirect target=%d -> %d', oldTargetId, targetId)
        end
        if (tonumber(state.guardOwnerEngageTargetId) or 0) > 0 then
            state.guardMustReturnHome = true
        end
        releaseGuardOwnedAttack()
        state.guardTargetId = targetId
        state.guardTargetKind = targetKind
        state.guardPetCommandSentId = 0
        state.guardPetCommandAt = 0
        state.guardTargetSettleId = 0
        state.guardTargetSettleAt = 0
    else
        state.guardTargetKind = targetKind
    end

    if mq.TLO.Target.ID() ~= targetId then
        if runtime.stopMoving then runtime.stopMoving() end
        state.guardTraceTargetCommandId = targetId
        state.guardTraceTargetBeforeId = mq.TLO.Target.ID() or 0
        local targetCommandOk = runtime.setTarget and runtime.setTarget(targetId) == true or false
        state.guardTraceTargetCommandOk = targetCommandOk
        state.guardTraceTargetAfterId = mq.TLO.Target.ID() or 0
        if not targetCommandOk then
            return false
        end
    end

    if targetId ~= state.lastGuardTargetId then
        state.lastGuardTargetId = targetId
        local targetName = ''
        pcall(function() targetName = getSpawn(targetId).CleanName() or '' end)
        debugGuard(ctrl, string.format(
            'Guard selected #%d (%s) as %s.', targetId, targetName, targetKind))
    end
    return true
end

local function updateGuardPetAttack(ctrl, runtime, targetId, ownerDefense)
    local now = os.clock()
    local petTargetId = 0
    pcall(function() petTargetId = mq.TLO.Me.Pet.Target.ID() or 0 end)

    -- Guard must give the newly selected target the same settle beat proven by
    -- Pet Puller before sending the NMS qattack + owner-attack trigger sequence.
    if mq.TLO.Target.ID() ~= targetId then
        state.guardTargetSettleId = 0
        state.guardTargetSettleAt = 0
        return
    end

    local retryDue = state.guardPetCommandSentId == targetId
        and petTargetId ~= targetId
        and (now - (state.guardPetCommandAt or 0)) >= 5.0
    local firstDispatch = state.guardPetCommandSentId ~= targetId
    if firstDispatch then
        if state.guardTargetSettleId ~= targetId then
            state.guardTargetSettleId = targetId
            state.guardTargetSettleAt = now
            debugGuard(ctrl, string.format(
                'Target #%d selected; waiting for Guard dispatch settle.', targetId))
            return
        end
        if (now - (state.guardTargetSettleAt or now)) < 0.35 then
            return
        end
    end

    if firstDispatch or retryDue then
        if runtime.isCasting and runtime.isCasting() then return end
        mq.cmd('/say #petcmd qattack all')
        mq.cmd('/attack on')
        if ownerDefense then
            state.guardDispatchAttackId = 0
            state.guardDispatchStartedAt = 0
            state.guardOwnerEngageTargetId = targetId
        else
            state.guardOwnerEngageTargetId = 0
            state.guardDispatchAttackId = targetId
            state.guardDispatchStartedAt = now
        end
        state.guardPetCommandSentId = targetId
        state.guardPetCommandAt = now
        state.guardTargetSettleId = 0
        state.guardTargetSettleAt = 0
        debugGuard(ctrl, string.format(
            'Sent qattack + attack-on for #%d (%s); pet target #%d, dispatch latch #%d.',
            targetId, ownerDefense and 'owner defense' or 'pet only', petTargetId,
            tonumber(state.guardDispatchAttackId) or 0))
    elseif ownerDefense and state.guardOwnerEngageTargetId ~= targetId then
        state.guardDispatchAttackId = 0
        state.guardDispatchStartedAt = 0
        state.guardOwnerEngageTargetId = targetId
        if not mq.TLO.Me.Combat() then mq.cmd('/attack on') end
    elseif not ownerDefense and state.guardOwnerEngageTargetId == targetId then
        releaseGuardOwnedAttack()
        state.guardMustReturnHome = true
    end
end

local function runGuardTarget(ctrl, runtime, result, targetId, targetKind, ownerDefense)
    if not setGuardTarget(ctrl, runtime, targetId, targetKind) then
        return false
    end

    state.guardPhase = ownerDefense
        and (targetKind == 'DIRECT_MASTER_THREAT' and 'MASTER_DEFENSE' or 'OWNER_DEFENSE')
        or targetKind
    if ownerDefense then
        state.guardMustReturnHome = true
    end
    updateGuardPetAttack(ctrl, runtime, targetId, ownerDefense)

    result.targetId = targetId
    result.phase = state.guardPhase
    result.haveNPC = true
    result.engage = ownerDefense
    return true
end

function M.guardTick(ctrl, runtime)
    local result = {
        haveNPC = false,
        engage = false,
        targetId = 0,
        phase = state.guardPhase or 'IDLE',
    }
    if not ctrl or not runtime or not M.isGuardMode(ctrl) then return result end

    M.syncMode(ctrl, runtime)
    M.sanitizeCtrl(ctrl)

    local traceNow = os.clock()
    local traceDue = ctrl.debug_mode and ((state.lastGuardTraceAt or 0) == 0
        or (traceNow - (state.lastGuardTraceAt or 0)) >= 2.5)
    local guardTrace = nil
    if traceDue then
        state.lastGuardTraceAt = traceNow
        guardTrace = {
            mode = ctrl.mode,
            submode = ctrl.submode,
            active = M.isGuardMode(ctrl),
            callerSeen = runtime.guardTraceCallerSeenAt ~= nil,
            running = ctrl.running,
            camp = ctrl.camp_loc ~= nil,
            phase = state.guardPhase,
            returnLatch = state.guardMustReturnHome,
            targetAtEntry = mq.TLO.Target.ID() or 0,
            stateTargetId = state.guardTargetId,
            stateTargetKind = state.guardTargetKind,
            lastReset = state.guardTraceLastReset,
            lastClear = state.guardTraceLastClear,
        }
    end
    local function finishGuardTrace()
        if guardTrace then
            guardTrace.phase = state.guardPhase
            guardTrace.returnLatch = state.guardMustReturnHome
            guardTrace.stateTargetId = state.guardTargetId
            guardTrace.stateTargetKind = state.guardTargetKind
            guardTrace.targetNow = mq.TLO.Target.ID() or 0
            guardTrace.targetCommandId = state.guardTraceTargetCommandId
            guardTrace.targetBeforeId = state.guardTraceTargetBeforeId
            guardTrace.targetAfterId = state.guardTraceTargetAfterId
            guardTrace.targetCommandOk = state.guardTraceTargetCommandOk
            guardTrace.lastReset = state.guardTraceLastReset
            guardTrace.lastClear = state.guardTraceLastClear
            emitGuardTrace(ctrl, guardTrace)
        end
        return result
    end

    if not ctrl.camp_loc then
        if (tonumber(state.guardTargetId) or 0) > 0 then
            resetGuardState(runtime, true, 'camp lost')
            if runtime.clearTarget then runtime.clearTarget() end
        elseif runtime.stopMoving then
            runtime.stopMoving()
        end
        if (os.clock() - (state.lastNoCampMessageAt or 0)) > 5.0 then
            state.lastNoCampMessageAt = os.clock()
            print('\ay[Triune]\ax Puller (Guard): No camp location set. Use Set Here or press START with a blank Guard camp.')
        end
        state.guardPhase = 'NO CAMP'
        result.phase = state.guardPhase
        return finishGuardTrace()
    end

    local petSearchRadius = tonumber(ctrl.camp_radius) or 100
    local ownerAssistRadius = tonumber(ctrl.guard_assist_radius) or 50
    local returnRadius = tonumber(ctrl.camp_return_radius) or 15
    local playerCampDistance = playerDistanceFromCamp(ctrl)
    local currentId = mq.TLO.Target.ID() or 0
    if guardTrace then
        guardTrace.playerCampDistance = playerCampDistance
        guardTrace.returnRadius = returnRadius
        guardTrace.pullRadius = tonumber(ctrl.camp_radius) or 100
        guardTrace.assistRadius = ownerAssistRadius
        guardTrace.petSearchRadius = petSearchRadius
        guardTrace.scanRadius = petSearchRadius + math.max(0, playerCampDistance)
        guardTrace.playerX, guardTrace.playerY, guardTrace.playerZ =
            mq.TLO.Me.X(), mq.TLO.Me.Y(), mq.TLO.Me.Z()
        guardTrace.campX, guardTrace.campY, guardTrace.campZ =
            ctrl.camp_loc.x, ctrl.camp_loc.y, ctrl.camp_loc.z
    end

    local directThreatId = findGuardDirectMasterThreat(runtime, currentId)
    if directThreatId > 0 then
        if guardTrace then guardTrace.selectedCandidateId = directThreatId end
        runGuardTarget(ctrl, runtime, result, directThreatId, 'DIRECT_MASTER_THREAT', true)
        return finishGuardTrace()
    end

    local ownerTargetId = tonumber(state.guardOwnerEngageTargetId) or 0
    if ownerTargetId > 0 then
        local ownerTargetStillNear = guardTargetAllowed(ctrl, runtime, ownerTargetId, petSearchRadius)
            and isGuardNearOwnerDefense(ctrl, ownerTargetId)
        if ownerTargetStillNear then
            if guardTrace then guardTrace.selectedCandidateId = ownerTargetId end
            runGuardTarget(ctrl, runtime, result, ownerTargetId, 'OWNER_DEFENSE', true)
            return finishGuardTrace()
        end
        releaseGuardOwnedAttack()
        state.guardMustReturnHome = true
    end

    if state.guardMustReturnHome or playerCampDistance > returnRadius then
        if playerCampDistance > returnRadius then
            state.guardPhase = 'OWNER_RETURNING'
            if runtime.stopMoving then runtime.stopMoving() end
            returnToCamp(ctrl, runtime)
            result.phase = state.guardPhase
            return finishGuardTrace()
        end
        state.guardMustReturnHome = false
        state.guardPhase = 'GUARD_HOME'
        if runtime.stopMoving then runtime.stopMoving() end
    end

    local preferredId = tonumber(state.guardTargetId) or 0
    local xtarId = findGuardXTarget(ctrl, runtime, petSearchRadius, preferredId)
    if xtarId > 0 then
        local ownerDefense = isGuardNearOwnerDefense(ctrl, xtarId)
        if guardTrace then guardTrace.selectedCandidateId = xtarId end
        runGuardTarget(ctrl, runtime, result, xtarId, 'PET_XTARGET', ownerDefense)
        return finishGuardTrace()
    end

    local localTargetId = 0
    if state.guardTargetKind == 'PET_LOCAL_TARGET'
        and preferredId > 0
        and guardTargetAllowed(ctrl, runtime, preferredId, petSearchRadius)
    then
        localTargetId = preferredId
    else
        if preferredId > 0 then clearGuardTarget(runtime, 'preferred target invalid before local acquisition') end
        local foundId, scanRadius, acquireError = acquireCampRoamTarget(
            ctrl, runtime, petSearchRadius, guardTrace)
        local candidateAllowed = foundId and foundId > 0
            and guardTargetAllowed(ctrl, runtime, foundId, petSearchRadius)
            or false
        if guardTrace then
            guardTrace.scanRadius = scanRadius or guardTrace.scanRadius
            guardTrace.acquireError = acquireError
            guardTrace.guardTargetAllowed = candidateAllowed
            guardTrace.selectedCandidateId = foundId
        end
        if candidateAllowed then
            localTargetId = foundId
        end
    end

    if localTargetId > 0 then
        local ownerDefense = isGuardNearOwnerDefense(ctrl, localTargetId)
        if guardTrace then guardTrace.selectedCandidateId = localTargetId end
        runGuardTarget(ctrl, runtime, result, localTargetId, 'PET_LOCAL_TARGET', ownerDefense)
        return finishGuardTrace()
    end

    clearGuardTarget(runtime, 'no qualifying Guard target')
    state.guardPhase = 'GUARD_HOME'
    result.phase = state.guardPhase
    return finishGuardTrace()
end

return M
