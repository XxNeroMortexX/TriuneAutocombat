---@diagnostic disable: undefined-global, undefined-field, need-check-nil
-- ============================================================================
-- TAC/lua/tac/zoneclaim.lua - NMS active-looter handoff by zone
-- ============================================================================
-- Enable this plugin on every box that should participate. When the current
-- NMS looter is no longer in the zone, the highest-priority live Triune box
-- remaining there claims the slot. Priority 1 is highest; ties are alphabetical.

local plugin = {
    id                 = 'zoneclaim',
    name               = 'Zone Claim',
    version            = '1.0.0',
    author             = 'Triune',
    description        = 'Hands the NMS active-looter slot to the highest-priority box in the zone.',
    defaultEnabled     = false,
    tickInterval       = 0.5,
    runOutOfCombatOnly = false,
    hasThread          = false,
    uses               = { boxnet = 'fresh peer zones and per-box priorities for NMS handoff' },
}

local core, mq
local publicApi
local PEER_MAX_AGE_SEC = 3
local ZONE_SETTLE_SEC = 1
local CLAIM_COOLDOWN_SEC = 15
local PRIORITY_MIN = 1
local PRIORITY_MAX = 6
local PRIORITY_BROADCAST_SEC = 5
local PRIORITY_REQUEST_SEC = 5
local EVENT_NAME = 'TacZoneClaimChat'
local MSG_PRIORITY = 'zoneclaim:priority'
local MSG_PRIORITY_REQUEST = 'zoneclaim:priority-request'

local cfg = {
    dzOnly = true,
    priority = PRIORITY_MAX,
    scopeRevision = 0,
    scopeWriter = '',
    targetZones = {},
}

local state = {
    zone = '',
    dzName = '',
    dzInstanceKey = '',
    zoneEnteredAt = 0,
    owner = nil,
    isLeader = false,
    lastClaimAt = -math.huge,
    lastAction = 'waiting for zone and NMS status',
    priorities = {},
    lastPriorityRequestAt = {},
    lastPriorityBroadcastAt = -math.huge,
    boxnet = nil,
    boxnetGeneration = -1,
    unsubscribers = {},
}

local function nowSec()
    if mq and mq.gettime then
        local ok, ms = pcall(mq.gettime)
        if ok and type(ms) == 'number' then return ms / 1000 end
    end
    return os.clock()
end

local function lower(value)
    return tostring(value or ''):lower()
end

local function trim(value)
    return tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')
end

local function myName()
    local ok, name = pcall(function() return mq.TLO.Me.CleanName() end)
    return ok and tostring(name or '') or ''
end

local function currentZone()
    local ok, zone = pcall(function() return mq.TLO.Zone.ShortName() end)
    return ok and tostring(zone or '') or ''
end

local function currentZoneName()
    local ok, name = pcall(function() return mq.TLO.Zone.Name() end)
    return ok and tostring(name or '') or ''
end

local function currentDzName()
    local ok, name = pcall(function() return mq.TLO.DynamicZone.Name() end)
    return ok and tostring(name or '') or ''
end

local function currentDzLeader()
    local ok, name = pcall(function() return mq.TLO.DynamicZone.Leader.Name() end)
    return ok and tostring(name or '') or ''
end

local function currentDzInstanceKey(zone, dzName)
    if dzName == '' then return nil end
    local leader = lower(currentDzLeader())
    if leader == '' then
        local members = {}
        local ok, count = pcall(function() return mq.TLO.DynamicZone.Members() end)
        if ok then
            for index = 1, tonumber(count) or 0 do
                local memberOk, name = pcall(function() return mq.TLO.DynamicZone.Member(index).Name() end)
                if memberOk and type(name) == 'string' and name ~= '' then
                    members[#members + 1] = lower(name)
                end
            end
        end
        table.sort(members)
        leader = table.concat(members, ',')
    end
    if leader == '' then return nil end
    return table.concat({ 'dz', lower(dzName), leader }, ':')
end

local function dzMemberStatus(name)
    local ok, status = pcall(function() return mq.TLO.DynamicZone.Member(name).Status() end)
    return ok and tostring(status or '') or ''
end

local function currentIsInDynamicZone()
    local me = myName()
    return me ~= '' and lower(dzMemberStatus(me)) == 'in dynamic zone'
end

local function boxnet()
    return core and core.boxnet or nil
end

local function currentTargetKey(zone, dzName, dzInstanceKey)
    zone = zone or currentZone()
    dzName = dzName or currentDzName()
    if cfg.dzOnly then
        dzInstanceKey = dzInstanceKey or currentDzInstanceKey(zone, dzName)
        return dzInstanceKey and dzInstanceKey ~= '' and dzInstanceKey or nil
    end
    return zone ~= '' and 'all-zones' or nil
end

local function targetFor(key)
    return key and cfg.targetZones[key] or nil
end

local function saveSettings()
    if core and core.saveLoadout then core.saveLoadout(true) end
end

local function setPriority(name, priority)
    if type(name) ~= 'string' or name == '' then return end
    priority = tonumber(priority)
    if not priority or priority ~= math.floor(priority) or priority < PRIORITY_MIN or priority > PRIORITY_MAX then return end
    state.priorities[lower(name)] = { name = name, priority = priority }
end

local publishPriority

local function nextScopeRevision()
    return math.max(os.time() * 1000, (tonumber(cfg.scopeRevision) or 0) + 1)
end

local function setScope(dzOnly)
    dzOnly = dzOnly == true
    if cfg.dzOnly == dzOnly then return end
    cfg.dzOnly = dzOnly
    cfg.scopeRevision = nextScopeRevision()
    cfg.scopeWriter = myName()
    state.isLeader = false
    state.owner = nil
    state.lastAction = 'global scope changed; waiting for box election'
    publishPriority()
    saveSettings()
end

local function setTargetZone()
    local shortName = currentZone()
    local dzName = currentDzName()
    if cfg.dzOnly and not currentIsInDynamicZone() then
        state.lastAction = 'left dynamic zone; the active looting zone stays with the zone, not the box'
        return false
    end
    if shortName == '' then
        state.lastAction = 'cannot set target zone while zoning'
        return false
    end
    local key = currentTargetKey(shortName, dzName)
    if not key then
        state.lastAction = 'cannot identify this dynamic zone instance'
        return false
    end
    local zoneName = currentZoneName()
    if zoneName == '' then zoneName = shortName end
    local existing = cfg.targetZones[key]
    if existing and existing.zone == shortName and existing.name == zoneName then return true end
    local revision = math.max(os.time() * 1000, (tonumber(existing and existing.revision) or 0) + 1)
    cfg.targetZones[key] = { zone = shortName, name = zoneName, revision = revision, writer = myName() }
    state.isLeader = false
    state.owner = nil
    state.lastAction = 'target zone changed; waiting for box election'
    publishPriority()
    saveSettings()
    return true
end

local function applySharedScope(data)
    if type(data) ~= 'table' or type(data.dzOnly) ~= 'boolean' then return end
    local revision = tonumber(data.scopeRevision)
    local writer = type(data.scopeWriter) == 'string' and data.scopeWriter or ''
    if not revision or revision < 0 or revision ~= math.floor(revision) then return end

    local currentRevision = tonumber(cfg.scopeRevision) or 0
    local currentWriter = tostring(cfg.scopeWriter or '')
    local isNewer = revision > currentRevision
        or (revision == currentRevision and writer ~= '' and (currentWriter == '' or lower(writer) < lower(currentWriter)))
    if not isNewer then return end

    local changed = cfg.dzOnly ~= data.dzOnly
    cfg.dzOnly = data.dzOnly
    cfg.scopeRevision = revision
    cfg.scopeWriter = writer
    if changed then
        state.isLeader = false
        state.owner = nil
        state.lastAction = 'global scope updated; waiting for box election'
    end
    saveSettings()
end

local function mergeTargetZones(data)
    if type(data) ~= 'table' or type(data.targetZones) ~= 'table' then return end
    local currentKey = currentTargetKey(state.zone, state.dzName, state.dzInstanceKey)
    local changed, currentChanged = false, false
    for key, remote in pairs(data.targetZones) do
        if type(key) == 'string' and #key <= 256 and type(remote) == 'table'
            and type(remote.zone) == 'string' and #remote.zone <= 64
            and type(remote.name) == 'string' and #remote.name <= 128 then
            local revision = tonumber(remote.revision)
            local writer = type(remote.writer) == 'string' and remote.writer or ''
            local localEntry = cfg.targetZones[key]
            local localRevision = tonumber(localEntry and localEntry.revision) or 0
            local localWriter = tostring(localEntry and localEntry.writer or '')
            local newer = revision and revision >= 0 and revision == math.floor(revision)
                and (revision > localRevision
                    or (revision == localRevision and writer ~= '' and (localWriter == '' or lower(writer) < lower(localWriter))))
            if newer then
                cfg.targetZones[key] = {
                    zone = remote.zone,
                    name = remote.name,
                    revision = revision,
                    writer = writer,
                }
                changed = true
                if key == currentKey then currentChanged = true end
            end
        end
    end
    if changed then
        if currentChanged then
            state.isLeader = false
            state.owner = nil
            state.lastAction = 'target zone synchronized; waiting for box election'
        end
        saveSettings()
    end
end

publishPriority = function()
    local bn = boxnet()
    if not (bn and bn.broadcast) then return false end
    local name = myName()
    setPriority(name, cfg.priority)
    return bn.broadcast(MSG_PRIORITY, {
        priority = cfg.priority,
        dzOnly = cfg.dzOnly,
        scopeRevision = cfg.scopeRevision,
        scopeWriter = cfg.scopeWriter,
        targetZones = cfg.targetZones,
    }) == true
end

local function receivePriority(data, sender)
    if type(data) ~= 'table' then return end
    local name = sender and sender.character
    if type(name) ~= 'string' or name == '' then name = data.from end
    setPriority(name, data.priority)
    mergeTargetZones(data)
    applySharedScope(data)
end

local function answerPriorityRequest(data, sender)
    local name = sender and sender.character
    if type(name) ~= 'string' or name == '' then name = type(data) == 'table' and data.from or nil end
    local bn = boxnet()
    if type(name) == 'string' and name ~= '' and bn and bn.send then
        bn.send(name, MSG_PRIORITY, {
            priority = cfg.priority,
            dzOnly = cfg.dzOnly,
            scopeRevision = cfg.scopeRevision,
            scopeWriter = cfg.scopeWriter,
            targetZones = cfg.targetZones,
        })
    end
end

local function ensureBoxnetSubscriptions()
    local bn = boxnet()
    if not (bn and bn.subscribe) then return false end
    local generation = bn.generation and bn.generation() or 0
    if state.boxnet == bn and state.boxnetGeneration == generation then return true end

    for _, unsubscribe in ipairs(state.unsubscribers) do pcall(unsubscribe) end
    state.unsubscribers = {}
    state.boxnet = bn
    state.boxnetGeneration = generation
    state.unsubscribers[#state.unsubscribers + 1] = bn.subscribe(MSG_PRIORITY, receivePriority)
    state.unsubscribers[#state.unsubscribers + 1] = bn.subscribe(MSG_PRIORITY_REQUEST, answerPriorityRequest)
    state.lastPriorityBroadcastAt = -math.huge
    if bn.broadcast then bn.broadcast(MSG_PRIORITY_REQUEST, {}) end
    return true
end

local function requestPriority(name, now)
    local bn = boxnet()
    if not (bn and bn.send) then return end
    local key = lower(name)
    local last = state.lastPriorityRequestAt[key] or -math.huge
    if now - last < PRIORITY_REQUEST_SEC then return end
    state.lastPriorityRequestAt[key] = now
    bn.send(name, MSG_PRIORITY_REQUEST, {})
end

local function priorityFor(name)
    if lower(name) == lower(myName()) then return cfg.priority end
    local entry = state.priorities[lower(name)]
    return entry and entry.priority or nil
end

local function handleChat(line)
    if type(line) ~= 'string' then return end
    local low = line:lower()
    local _, finish = low:find('active looter%s*:%s*')
    if not finish then return end

    local name = trim(line:sub(finish + 1)):gsub('[%.!]+%s*$', '')
    local normalized = lower(name)
    if normalized == 'you' then
        name = myName()
    elseif normalized == 'nobody' or normalized == 'no one' or normalized == 'none' then
        name = ''
    end
    state.owner = name
end

local function registerEvent()
    if not (mq and mq.event) then return end
    if mq.unevent then pcall(mq.unevent, EVENT_NAME) end
    pcall(mq.event, EVENT_NAME, '#*#', handleChat)
end

local function requestStatus()
    mq.cmd('/say #nms status')
end

local function inZoneCandidates()
    local boxnet = core and core.boxnet
    if not (boxnet and boxnet.available and boxnet.available()) then return nil end

    local dzName = currentDzName()
    local instanceKey = currentDzInstanceKey(currentZone(), dzName)
    local names = { { name = myName(), priority = cfg.priority } }
    local missingPriority
    for _, peer in ipairs(boxnet.peersInZone(PEER_MAX_AGE_SEC) or {}) do
        if peer and type(peer.name) == 'string' and peer.name ~= '' then
            local inCurrentInstance = dzName == '' or (instanceKey ~= nil and peer.hb
                and peer.hb.inDynamicZone == true
                and lower(peer.hb.dzInstanceKey) == lower(instanceKey))
            if inCurrentInstance then
                local priority = priorityFor(peer.name)
                if priority == nil then
                    missingPriority = peer.name
                    requestPriority(peer.name, nowSec())
                else
                    names[#names + 1] = { name = peer.name, priority = priority }
                end
            end
        end
    end
    if missingPriority then return nil, missingPriority end
    table.sort(names, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return lower(a.name) < lower(b.name)
    end)
    return names
end

local function ownerIsInZone(name, zone, dzName, now)
    if lower(name) == lower(myName()) then return true end
    if dzName ~= '' then
        local boxnet = core and core.boxnet
        local peer = boxnet and boxnet.peer and boxnet.peer(name)
        if peer and peer.hb then
            local instanceKey = currentDzInstanceKey(zone, dzName)
            return instanceKey ~= nil
                and now - (peer.seenAt or 0) <= PEER_MAX_AGE_SEC
                and lower(peer.hb.zone) == lower(zone)
                and peer.hb.inDynamicZone == true
                and lower(peer.hb.dzInstanceKey) == lower(instanceKey)
        end
        return lower(dzMemberStatus(name)) == 'in dynamic zone'
    end
    local boxnet = core and core.boxnet
    local peer = boxnet and boxnet.peer and boxnet.peer(name)
    if not peer or not peer.hb or type(peer.hb.zone) ~= 'string' then return false end
    if now - (peer.seenAt or 0) > PEER_MAX_AGE_SEC then return false end
    return lower(peer.hb.zone) == lower(zone)
end

local function tick()
    ensureBoxnetSubscriptions()
    local now = nowSec()
    local zone = currentZone()
    if zone == '' then return end
    local dzName = currentDzName()
    local inDynamicZone = currentIsInDynamicZone()
    local dzInstanceKey = currentDzInstanceKey(zone, dzName) or ''

    if now - state.lastPriorityBroadcastAt >= PRIORITY_BROADCAST_SEC then
        if publishPriority() then state.lastPriorityBroadcastAt = now end
    end

    if zone ~= state.zone or dzName ~= state.dzName or dzInstanceKey ~= state.dzInstanceKey then
        state.zone = zone
        state.dzName = dzName
        state.dzInstanceKey = dzInstanceKey
        state.zoneEnteredAt = now
        state.owner = nil
        state.isLeader = false
        state.lastAction = 'zone changed; waiting for box election'
        if cfg.dzOnly and inDynamicZone then setTargetZone() end
    end

    if cfg.dzOnly and not inDynamicZone then
        state.isLeader = false
        state.lastAction = 'left dynamic zone; waiting for the next available box in this zone'
        return
    end
    local targetKey = currentTargetKey(zone, dzName, dzInstanceKey)
    local target = targetFor(targetKey)
    if cfg.dzOnly and inDynamicZone then
        if not target or lower(zone) ~= lower(target.zone) then
            if setTargetZone() then target = targetFor(targetKey) end
        end
    elseif not cfg.dzOnly then
        if not target or lower(zone) ~= lower(target.zone) then
            if setTargetZone() then target = targetFor(targetKey) end
        end
    end
    if not target then
        state.isLeader = false
        state.lastAction = 'target zone not set for this instance'
        return
    end
    if lower(zone) ~= lower(target.zone) then
        state.isLeader = false
        state.lastAction = 'inactive outside target zone ' .. (target.name ~= '' and target.name or target.zone)
        return
    end

    if now - state.zoneEnteredAt < ZONE_SETTLE_SEC then return end
    local candidates, missingPriority = inZoneCandidates()
    if not candidates or #candidates == 0 then
        state.lastAction = missingPriority and ('waiting for ' .. missingPriority .. "'s priority") or 'Box Network roster unavailable'
        return
    end
    local leader = candidates[1]
    if lower(leader.name) ~= lower(myName()) then
        state.isLeader = false
        state.lastAction = leader.name .. ' is elected to claim'
        return
    end

    if not state.isLeader then
        state.isLeader = true
        state.owner = nil
        requestStatus()
        state.lastAction = 'requested NMS status; waiting for reply'
        return
    end
    if state.owner == nil then
        state.lastAction = 'waiting for a fresh active-looter status'
        return
    end
    if state.owner == '' then
        state.lastAction = 'NMS reports no active looter'
        return
    end
    if ownerIsInZone(state.owner, zone, dzName, now) then
        local ownerPriority = priorityFor(state.owner)
        if ownerPriority == nil then
            state.lastAction = 'waiting for ' .. state.owner .. "'s priority before handoff"
            requestPriority(state.owner, now)
            return
        end
        local localWinsTie = lower(myName()) < lower(state.owner)
        if cfg.priority > ownerPriority or (cfg.priority == ownerPriority and not localWinsTie) then
            state.lastAction = state.owner .. ' remains higher priority in ' .. zone
            return
        end
    end
    if now - state.lastClaimAt < CLAIM_COOLDOWN_SEC then return end

    mq.cmd('/say #nms claim')
    state.owner = nil
    state.lastClaimAt = now
    requestStatus()
    state.lastAction = 'claim sent; refreshing NMS status'
    print(string.format('\ag[Triune Zone Claim]\ax Claim sent in %s; refreshing NMS status.', zone))
end

function plugin.onInit(coreApi)
    core = coreApi
    mq = core.mq
    state.zone = ''
    state.dzName = ''
    state.dzInstanceKey = ''
    state.owner = nil
    state.isLeader = false
    state.lastClaimAt = -math.huge
    state.priorities = {}
    state.lastPriorityRequestAt = {}
    state.lastPriorityBroadcastAt = -math.huge
    state.boxnet = nil
    state.boxnetGeneration = -1
    state.unsubscribers = {}
    state.lastAction = 'waiting for zone and NMS status'
    rawset(core, 'zoneclaim', publicApi)
    ensureBoxnetSubscriptions()
    registerEvent()
end

function plugin.onTick()
    if not core then return end
    mq = core.mq
    tick()
end

function plugin.onZoned()
    state.zone = ''
    state.dzName = ''
    state.dzInstanceKey = ''
    state.owner = nil
    state.isLeader = false
end

function plugin.onDestroy()
    if mq and mq.unevent then pcall(mq.unevent, EVENT_NAME) end
    for _, unsubscribe in ipairs(state.unsubscribers) do pcall(unsubscribe) end
    state.unsubscribers = {}
    state.boxnet = nil
    if core and rawget(core, 'zoneclaim') == publicApi then rawset(core, 'zoneclaim', nil) end
end

function plugin.onLoadSettings(settings)
    if type(settings) ~= 'table' then return end
    local scopeRevision = tonumber(settings.scopeRevision)
    if scopeRevision and scopeRevision >= 0 then
        cfg.dzOnly = settings.dzOnly == true
        cfg.scopeRevision = math.floor(scopeRevision)
        cfg.scopeWriter = type(settings.scopeWriter) == 'string' and settings.scopeWriter or ''
    else
        cfg.dzOnly = true
        cfg.scopeRevision = 0
        cfg.scopeWriter = ''
    end
    cfg.targetZones = {}
    if type(settings.targetZones) == 'table' then
        local latestZoneTarget
        for key, entry in pairs(settings.targetZones) do
            if type(key) == 'string' and type(entry) == 'table'
                and type(entry.zone) == 'string' and type(entry.name) == 'string' then
                local clean = {
                    zone = entry.zone,
                    name = entry.name,
                    revision = tonumber(entry.revision) or 0,
                    writer = type(entry.writer) == 'string' and entry.writer or '',
                }
                if key == 'all-zones' or key:sub(1, 3) == 'dz:' then
                    cfg.targetZones[key] = clean
                elseif key:sub(1, 5) == 'zone:'
                    and (not latestZoneTarget or clean.revision > latestZoneTarget.revision) then
                    latestZoneTarget = clean
                end
            end
        end
        if not cfg.targetZones['all-zones'] and latestZoneTarget then
            cfg.targetZones['all-zones'] = latestZoneTarget
        end
    elseif type(settings.targetZone) == 'string' and settings.targetZone ~= '' then
        cfg.targetZones['all-zones'] = {
            zone = settings.targetZone,
            name = type(settings.targetZoneName) == 'string' and settings.targetZoneName or settings.targetZone,
            revision = tonumber(settings.scopeRevision) or 0,
            writer = type(settings.scopeWriter) == 'string' and settings.scopeWriter or '',
        }
    end
    local priority = tonumber(settings.priority)
    if priority then cfg.priority = math.max(PRIORITY_MIN, math.min(PRIORITY_MAX, math.floor(priority))) end
    state.isLeader = false
    state.owner = nil
    state.lastPriorityBroadcastAt = -math.huge
end

function plugin.onSaveSettings()
    return {
        dzOnly = cfg.dzOnly == true,
        scopeRevision = cfg.scopeRevision,
        scopeWriter = cfg.scopeWriter,
        targetZones = cfg.targetZones,
        priority = cfg.priority,
    }
end

local function priorityRows()
    local rows = {}
    local bn = boxnet()
    local zone = currentZone()
    local dzName = currentDzName()
    local instanceKey = currentDzInstanceKey(zone, dzName)
    local target = targetFor(currentTargetKey(zone, dzName, instanceKey))
    local targetZone = target and target.zone or zone
    local now = nowSec()
    if lower(zone) == lower(targetZone) and (not cfg.dzOnly or currentIsInDynamicZone()) then
        rows[#rows + 1] = { name = myName(), priority = cfg.priority }
    end
    if bn and bn.peers then
        for _, peer in ipairs(bn.peers()) do
            local hb = peer.hb
            local inTargetZone = hb and lower(hb.zone) == lower(targetZone)
                and now - (peer.seenAt or 0) <= PEER_MAX_AGE_SEC
            local inTargetInstance = not cfg.dzOnly or (hb and hb.inDynamicZone == true
                and instanceKey ~= nil and lower(hb.dzInstanceKey) == lower(instanceKey))
            if inTargetZone and inTargetInstance then
                local entry = state.priorities[lower(peer.name)]
                rows[#rows + 1] = { name = peer.name, priority = entry and entry.priority or nil }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.priority == nil then return false end
        if b.priority == nil then return true end
        if a.priority ~= b.priority then return a.priority < b.priority end
        return lower(a.name) < lower(b.name)
    end)
    return rows
end

local function drawNmsControls(idSuffix)
    if not core or not core.ImGui then return end
    local ImGui = core.ImGui
    idSuffix = tostring(idSuffix or 'nms')
    local zone = currentZone()
    local dzName = currentDzName()
    local instanceKey = currentDzInstanceKey(zone, dzName) or ''
    local target = targetFor(currentTargetKey(zone, dzName, instanceKey))
    local targetZoneLabel = target and string.format('%s (%s)', target.name ~= '' and target.name or target.zone, target.zone)
        or (cfg.dzOnly and 'Not set for this DZ instance' or 'Not set for this zone')
    ImGui.TextDisabled('Active looting zone: ' .. targetZoneLabel)
    ImGui.SameLine()
    if ImGui.SmallButton('Manual override##zoneClaimTarget' .. idSuffix) then
        setTargetZone()
    end
    if ImGui.IsItemHovered() then core.setTooltip('Normally the active-looting zone auto-tracks your current zone. This is a manual override for intentional cross-zone switching.') end
    if cfg.dzOnly then
        local instanceLabel = dzName ~= '' and dzName or 'not currently in a DZ'
        local leader = currentDzLeader()
        if leader ~= '' then instanceLabel = instanceLabel .. ' | Leader: ' .. leader end
        ImGui.TextDisabled('DZ instance: ' .. instanceLabel)
    end
    ImGui.SetNextItemWidth(core.px and core.px(180) or 180)
    local scopeLabel = cfg.dzOnly and 'Dynamic zones only' or 'All zones'
    if ImGui.BeginCombo('Scope##zoneClaimScope' .. idSuffix, scopeLabel) then
        if ImGui.Selectable('All zones##zoneClaimAll' .. idSuffix, not cfg.dzOnly) then setScope(false) end
        if ImGui.Selectable('Dynamic zones only##zoneClaimDz' .. idSuffix, cfg.dzOnly) then setScope(true) end
        ImGui.EndCombo()
    end
    ImGui.SetNextItemWidth(core.px and core.px(160) or 160)
    local preview = string.format('%d%s', cfg.priority, cfg.priority == PRIORITY_MIN and ' (highest)' or '')
    if ImGui.BeginCombo('Priority##zoneClaimPriority' .. idSuffix, preview) then
        for priority = PRIORITY_MIN, PRIORITY_MAX do
            local label = string.format('%d%s', priority, priority == PRIORITY_MIN and ' (highest)' or '')
            if ImGui.Selectable(label .. '##zoneClaimChoice' .. idSuffix .. priority, cfg.priority == priority) then
                cfg.priority = priority
                state.priorities[lower(myName())] = { name = myName(), priority = priority }
                state.lastPriorityBroadcastAt = -math.huge
                publishPriority()
                saveSettings()
            end
        end
        ImGui.EndCombo()
    end
    ImGui.TextDisabled('Scope is shared across boxes; priority is per character.')
    ImGui.TextDisabled('1 is highest; ties go to the alphabetically first character.')
    ImGui.TextDisabled(cfg.dzOnly and 'Priority order in this DZ instance:' or 'Priority order in this zone:')
    for _, row in ipairs(priorityRows()) do
        local value = row.priority and tostring(row.priority) or '?'
        ImGui.Text(string.format('%s  %s%s', value, row.name,
            lower(row.name) == lower(myName()) and ' (this box)' or ''))
    end
end

publicApi = { drawControls = drawNmsControls, setCurrentZone = setTargetZone }

function plugin.onCommand(cmd, args)
    if cmd ~= 'zoneclaim' then return false end
    local subcommand = lower(args and args[1])
    if subcommand == 'status' or subcommand == '' then
        print(string.format('\\ag[Triune Zone Claim]\\ax Zone: %s | Scope: %s | Priority: %d | NMS owner: %s | %s',
            state.zone ~= '' and state.zone or 'unknown',
            cfg.dzOnly and 'DZ only' or 'all zones',
            cfg.priority,
            state.owner ~= nil and (state.owner ~= '' and state.owner or 'nobody') or 'unknown',
            state.lastAction))
    else
        print('\\ag[Triune Zone Claim]\\ax Use /ac zoneclaim status. Configure scope and priority in the NMS Loot view.')
    end
    return true
end

plugin.help = {
    '  \ag/ac zoneclaim status\ax - Show the current zone, NMS owner, and handoff state',
    '  Priority 1 is highest; equal priorities are decided alphabetically. Settings are saved per character.',
}

plugin.state = state
plugin.cfg = cfg
plugin.tick = tick
plugin.handleChat = handleChat

return plugin