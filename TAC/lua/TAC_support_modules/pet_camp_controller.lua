-- Created By: NeroMorte - Shared, session-only pet telemetry and stationary camp controller.
-- No MQ/ImGui dependencies: the host supplies readings and commands, and tests use the same controller.
local M = {}
local Controller = {}
Controller.__index = Controller
local function count(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

function M.new(api)
    return setmetatable({ api = api, cache = {}, phase = 'IDLE', batch = {}, skipped = {},
        pending = {}, lastAttackAt = -100, refreshAt = -100, message = '', generation = '' }, Controller)
end

-- Edited By: NeroMorte - Keep configuration inside the character's existing saved ctrl table.
function M.defaults(c)
    if c.pet_camp_enabled == nil then c.pet_camp_enabled = false end
    if c.pet_camp_pull_back == nil then c.pet_camp_pull_back = false end
    c.pet_camp_assist_radius = math.max(1, math.floor(tonumber(c.pet_camp_assist_radius) or 30))
    c.pet_camp_batch_size = math.max(1, math.min(100, math.floor(tonumber(c.pet_camp_batch_size) or 1)))
    c.pet_camp_puller_class = c.pet_camp_puller_class or 'Auto'
    -- Created By: NeroMorte - Saved recall grace period starts only after the pulling pet reaches camp.
    c.pet_camp_recall_delay = math.max(0, tonumber(c.pet_camp_recall_delay) or 5)
end

function Controller:enabled()
    local c = self.api.config()
    return c.pet_camp_enabled == true and c.mode == 'Puller' and c.submode == 'Camp' and c.pull_style == 'Pet'
end

function Controller:resetCombat()
    if self.api.endDispatch then self.api.endDispatch() end
    self.phase, self.batch, self.skipped, self.tag = 'IDLE', {}, {}, nil
    self.puller, self.noNextAt, self.fightId = nil, nil, nil
    self.lastAttackAt, self.returnHomeAt = -100, nil
end

-- Edited By: NeroMorte - Spawn/zone identity changes discard telemetry, never reuse a dead pet's flags.
function Controller:refresh()
    for id, p in pairs(self.cache) do
        p.state = {}; p.probedAt = nil; self.pending[id] = true
    end
    self.refreshAt = self.api.now()
end

function Controller:value(id, field)
    local p = self.cache[id]
    return p and p.state[field]
end

function Controller:allValue(field)
    local value, found
    for _, p in pairs(self.cache) do
        local v = p.state[field]
        if v == nil or (found and v ~= value) then return nil end
        value, found = v, true
    end
    if found then return value end
end

-- Edited By: NeroMorte - An outgoing command is a request, not proof the server accepted it.
function Controller:noteCommand(verb, scope)
    local field = verb:match('^(%w+) %w+$')
    if verb == 'follow' or verb == 'guard' or verb == 'sit' or verb == 'back' then field = 'stance' end
    if verb == 'stop' then field = 'stop' end
    if verb == 'hold' or verb == 'ghold' or verb == 'spellhold' or verb == 'taunt' or verb == 'focus' then field = verb end
    if not field then return end
    for id, p in pairs(self.cache) do
        if scope == 'all' or scope == p.scope then
            p.state[field] = nil
            p.commandAt = self.api.now()
            -- Created By: NeroMorte - Routine hold/assist/back commands must not queue target-switching scans.
            -- Keep startup/new-pet/manual requests; otherwise refresh unknown buttons manually or from matching live telemetry.
        end
    end
end

-- Edited By: NeroMorte - Only exact, observed messages set flags. Ambiguous position chat invalidates its field without interrupting pulls.
function Controller:petTell(name, text)
    name = tostring(name or ''):lower()
    text = tostring(text or ''):gsub("^%s*'", ''):gsub("'%s*$", ''):lower()
    for id, p in pairs(self.cache) do
        if p.name:lower() == name then
            if text == 'no longer taunting attackers, master.' then p.state.taunt = false
            elseif text == 'taunting attackers as ordered, master.' then p.state.taunt = true
            else
                if text:find('position', 1, true) then p.state.stance = nil end
                if text:find('taunt', 1, true) then p.state.taunt = nil end
                if text:find('hold', 1, true) then p.state.hold, p.state.ghold, p.state.spellhold = nil, nil, nil end
                if text:find('focus', 1, true) then p.state.focus = nil end
                -- Created By: NeroMorte - Position tells are frequent during pulling, not a request to target pets again.
            end
            return
        end
    end
end

-- Edited By: NeroMorte - Capture window-only fields with settled matching IDs, outside combat/casts/movement.
-- Only restore a probe target if the player has not selected something else in the meantime.
function Controller:tickStates()
    local a, now = self.api, self.api.now()
    if a.checkDispatch then a.checkDispatch() end
    local generation = a.generation()
    if generation ~= self.generation then
        self.cache, self.pending, self.probe, self.windowId = {}, {}, nil, nil
        self.held, self.disabledAssist, self.wasActive = nil, nil, false
        self.generation = generation
        self:resetCombat()
    end
    local alive = {}
    for _, pet in ipairs(a.pets()) do
        if pet.id > 0 and a.alive(pet.id) then
            alive[pet.id] = true
            local old = self.cache[pet.id]
            if not old or old.name ~= pet.name or old.scope ~= pet.scope then
                self.cache[pet.id] = { name = pet.name, scope = pet.scope, cls = pet.cls, state = {} }
                self.pending[pet.id] = true
            end
        end
    end
    for id in pairs(self.cache) do
        if not alive[id] then self.cache[id], self.pending[id] = nil, nil end
    end
    local windowId, state = a.readPet()
    if windowId ~= self.windowId then self.windowId, self.windowAt = windowId, now end
    local p = self.cache[windowId]
    if p and now - (self.windowAt or now) >= 0.3 and now - (p.commandAt or -100) >= 0.3 then
        for field, value in pairs(state or {}) do p.state[field] = value end
        -- An unavailable TLO stays unknown, not a guessed OFF.
        p.readAt = now
        self.pending[windowId] = nil
    end
    if self.probe then
        local probe = self.probe
        if a.target() ~= probe.id then self.probe = nil; return end
        local captured = p and windowId == probe.id and p.readAt and p.readAt >= probe.at + 0.3
        if not a.safeProbe() or now - probe.at >= 3 or captured then
            if a.target() == probe.id then a.restore(probe.original) end
            self.probe = nil
            if a.trace then
                if captured then a.trace(string.format('Captured pet states: [%s] %s (#%d).', p.cls, p.name, probe.id))
                elseif now - probe.at >= 3 then a.trace(string.format('Pet state capture timed out for #%d; Refresh Pet States retries when safe.', probe.id)) end
            end
            -- Created By: NeroMorte - A failed snapshot is not a perpetual between-pull target carousel.
            if now - probe.at >= 3 then self.pending[probe.id] = nil end
        end
        return
    end
    if a.safeProbe() and not self.tag and now - (self.lastProbeAt or -100) >= 0.4 then
        for id in pairs(self.pending) do
            local p2 = self.cache[id]
            -- Retry unavailable windows later, without cycling targets continuously.
            if p2 and now - (p2.probedAt or -100) >= 10 then
                local original = a.target()
                p2.probedAt = now
                self.lastProbeAt = now
                if a.targetPet(id) then
                    self.probe = { id = id, original = original, at = a.now() }
                    self.windowId, self.windowAt = nil, now
                end
                break
            end
        end
    end
    if not self:enabled() or not a.config().running then
        if self.wasActive then
            self:command('back', 'all'); self:command('follow', 'all')
            a.releasePets(); self.wasActive = false
        end
        self:resetCombat()
    end
end

-- Edited By: NeroMorte - Camp-to-mob distance governs assistance; direct player threats also qualify.
function Controller:ownerAllowed(id)
    if not self:enabled() then return true end
    if not id or not self.api.hostile(id) or not self.api.alive(id) then return false end
    return self.api.campDistance(id) <= self.api.config().pet_camp_assist_radius or self.api.directThreat(id)
end

function Controller:choosePuller()
    local choice = self.api.config().pet_camp_puller_class
    local candidates, allOff, havePets = {}, true, false
    for id, p in pairs(self.cache) do
        havePets = true
        if p.state.taunt ~= false then allOff = false end
        if p.state.taunt == true and p.scope ~= 'all' and p.scope ~= 'swarm' and (choice == 'Auto' or p.cls == choice) then
            candidates[#candidates + 1] = { id = id, cls = p.cls, scope = p.scope }
        end
    end
    table.sort(candidates, function(x, y) return x.id < y.id end)
    if candidates[1] then return candidates[1] end
    -- Edited By: NeroMorte - Confirmed no-taunt fallback uses all pets; unknown is not OFF.
    if havePets and allOff then return { id = 0, cls = 'All', scope = 'all' } end
end

function Controller:command(verb, scope)
    if verb == 'hold on' then
        self.held = self.held or {}; self.held[scope] = true
    elseif verb == 'hold off' and self.held then self.held[scope] = nil end
    if verb == 'assist off' then
        self.disabledAssist = self.disabledAssist or {}; self.disabledAssist[scope] = true
    end
    self.api.command(verb, scope)
end

function Controller:recall()
    -- Edited By: NeroMorte - Disable owner auto-assist trigger before recalling any pet.
    if self.api.endDispatch then self.api.endDispatch(true) end
    if self.phase ~= 'RETURN' and self.phase ~= 'FIGHT' then
        self:command('back', self.puller and self.puller.scope or 'all')
        self:command('follow', self.puller and self.puller.scope or 'all')
        -- Created By: NeroMorte - Hold during grace so pet auto-retaliation cannot defeat the delay.
        if self.api.config().pet_camp_pull_back == true and (self.api.config().pet_camp_recall_delay or 5) > 0 then
            self:command('hold on', 'all')
        end
    end
    self.phase, self.tag, self.noNextAt, self.returnHomeAt = 'RETURN', nil, nil, nil
end

function Controller:attack(id, scope)
    local now = self.api.now()
    if self.fightId ~= id or now - self.lastAttackAt >= 3 then
        if not self.api.setTarget(id) then return false end
        if self.api.targetSettled and not self.api.targetSettled(id) then return false end
        -- Edited By: NeroMorte - Preserve the proven far-pet assist/owner-attack trigger.
        -- Gathering enables only the selected class, while camp fighting releases everyone.
        self:command('assist on', scope)
        self:command('hold off', scope)
        self:command('attack', scope)
        if self.api.beginDispatch then self.api.beginDispatch(id) end
        self.fightId, self.lastAttackAt = id, now
    elseif self.api.target() ~= id then self.api.setTarget(id) end
    return true
end

-- Edited By: NeroMorte - Single-pet gather -> recall -> camp fight; arrival overrides the batch quota.
function Controller:combatTick()
    local a, c, now = self.api, self.api.config(), self.api.now()
    if not self:enabled() then return false, false end
    self.wasActive = true
    if self.probe then self.message = 'Reading pet states'; return false, false end
    local mode = tostring(c.pet_camp_pull_back)
    if self.pullMode and self.pullMode ~= mode then
        self:recall(); a.releasePets(); self:resetCombat()
    end
    self.pullMode = mode
    a.ensureCamp()
    a.holdCamp()
    local xt = {}
    -- Created By: NeroMorte - Dead/corpse XTarget entries can linger briefly; do not delay the next live fight.
    for _, id in ipairs(a.hostileXT()) do if a.alive(id) and a.hostile(id) then xt[#xt + 1] = id end end
    for id in pairs(self.batch) do if not a.alive(id) then self.batch[id] = nil end end
    local owned, near, defense = {}, nil, nil
    for id in pairs(self.batch) do owned[id] = true end
    -- Created By: NeroMorte - Actual hostile XTarget IDs are the fight boundary; ToT can change mid-fight.
    local onXT = {}
    for _, id in ipairs(xt) do owned[id], onXT[id] = true, true end
    for id in pairs(owned) do
        if a.alive(id) and self:ownerAllowed(id) then
            if not near or a.campDistance(id) < a.campDistance(near) then near = id end
        end
    end
    for _, id in ipairs(xt) do if a.directThreat(id) then defense = id; break end end
    local targetId = a.target()
    if a.directThreat(targetId) and a.hostile(targetId) and a.alive(targetId) then defense = targetId end
    if near or defense then
        if self.phase ~= 'FIGHT' then self:recall(); a.releasePets(); self.lastAttackAt = -100 end
        self.phase, self.message = 'FIGHT', 'Fighting at camp'
        local id = defense or near
        self:attack(id, 'all')
        return true, self:ownerAllowed(id)
    end
    if self.phase == 'FIGHT' or self.phase == 'RETURN' then
        if next(owned) or #xt > 0 then
            -- Created By: NeroMorte - Once recalled pets arrive, they finish the pull even outside owner assist range.
            -- Never use a gathering pet taking hits as a reason to end GATHER early.
            local returned = self.phase == 'RETURN' and self.puller and a.pullerHome and a.pullerHome(self.puller.id)
            -- Created By: NeroMorte - Give incoming mobs time to close before releasing pets.
            -- The earlier assist-radius/direct-player-threat branch bypasses this wait.
            if self.phase == 'RETURN' then
                if returned then self.returnHomeAt = self.returnHomeAt or now else self.returnHomeAt = nil end
                if returned and now - self.returnHomeAt < c.pet_camp_recall_delay then
                    self.message = string.format('Recall delay: %.1fs remaining', c.pet_camp_recall_delay - (now - self.returnHomeAt))
                    return false, false
                end
            end
            if c.pet_camp_pull_back ~= true or self.phase == 'FIGHT' or returned then
                local remaining
                for id in pairs(owned) do
                    if a.alive(id) and a.hostile(id) and a.petsCanFinish(id)
                        and (not remaining or a.campDistance(id) < a.campDistance(remaining)) then
                        remaining = id
                    end
                end
                if remaining then
                    if self.phase ~= 'FIGHT' then
                        if a.endDispatch then a.endDispatch(true) end
                        a.releasePets(); self.lastAttackAt = -100
                    end
                    self.phase = 'FIGHT'
                    self:attack(remaining, 'all')
                    self.message = 'Pets finishing the pull; player assists only in range or for self-defense'
                    return true, self:ownerAllowed(remaining)
                end
            end
            self.message = 'Waiting for the remaining pull to reach camp'
            return false, false
        end
        if self.phase == 'RETURN' and self.puller and (self.puller.id == 0 or a.alive(self.puller.id)) and a.pullerHome and not a.pullerHome(self.puller.id) then
            self.message = 'Waiting for the pulling pet to return'; return false, false
        end
        a.releasePets()
        self:resetCombat()
    end
    if a.resting() or not a.atCamp() then self.message = 'Waiting at camp'; return false, false end
    -- Edited By: NeroMorte - Preserve plugins such as Auto AA using safe gaps between pulls.
    if self.phase == 'IDLE' and #xt == 0 and not next(self.batch) and a.betweenPulls and a.betweenPulls() then
        self.message = 'Between-pull task'; return false, false
    end
    if c.pet_camp_pull_back ~= true then
        local id = self.fightId
        -- Created By: NeroMorte - Finish every live hostile XTarget before pulling a fresh mob.
        if #xt > 0 then
            if not id or not a.alive(id) or not onXT[id] then id = xt[1] end
        elseif not id or not a.alive(id) or not a.inPullRadius(id) then
            id = a.find({})
        end
        if id then
            a.releasePets()
            self:attack(id, 'all')
            self.message = 'Pets fighting in the pull radius'
            return true, self:ownerAllowed(id)
        end
        self.message = 'No eligible mob in the pull radius'; return false, false
    end
    local puller = self:choosePuller()
    if self.puller and (not puller or puller.id ~= self.puller.id) then
        self:recall(); self.message = 'Pulling pet changed or taunt is unconfirmed'; return false, false
    end
    if not puller then
        self.message = 'Enable taunt on a pulling pet, then refresh pet states when safe'
        return false, false
    end
    self.puller = puller
    if self.phase == 'IDLE' then
        if #xt > 0 then self.message = 'Waiting for hostile XTargets to clear'; return false, false end
        for id, p in pairs(self.cache) do
            if puller.scope ~= 'all' and id ~= puller.id then
                self:command('assist off', p.scope)
                self:command('back', p.scope); self:command('follow', p.scope); self:command('hold on', p.scope)
            end
        end
        self.phase = 'GATHER'
    end
    if self.tag then
        local tag = self.tag
        if not tag.sent then
            if self:attack(tag.id, puller.scope) then tag.sent, tag.at = true, now end
            if not tag.sent then
                if now - tag.at >= 10 then self.skipped[tag.id], self.tag = now + 30, nil end
                self.message = 'Waiting for the pull target to settle'; return true, false
            end
        end
        -- Created By: NeroMorte - Confirm this exact pull ID in XTargets before advancing or recalling.
        if a.alive(tag.id) and onXT[tag.id] then
            if a.endDispatch then a.endDispatch() end
            self.batch[tag.id], self.tag = true, nil
        elseif not a.alive(tag.id) or now - tag.at >= 120 then
            if a.endDispatch then a.endDispatch() end
            self.skipped[tag.id], self.tag = now + 30, nil
        else
            -- A support cast/target change can cancel the owner trigger before pets see it.
            if now - self.lastAttackAt >= 3 then self:attack(tag.id, puller.scope) end
            self.message = string.format('Waiting for pull target in XTargets; %d/%d confirmed', count(self.batch), c.pet_camp_batch_size)
            return true, false
        end
    end
    if count(self.batch) >= c.pet_camp_batch_size then self:recall(); return false, false end
    local exclude = {}
    for id in pairs(self.batch) do exclude[id] = true end
    for id, untilAt in pairs(self.skipped) do if now < untilAt then exclude[id] = true else self.skipped[id] = nil end end
    for _, id in ipairs(xt) do exclude[id] = true end
    local nextId = a.find(exclude)
    if nextId then
        self.noNextAt = nil
        if a.setTarget(nextId) then
            if a.endDispatch then a.endDispatch() end
            self.tag = { id = nextId, at = now, sent = false }
            if self:attack(nextId, puller.scope) then self.tag.sent = true end
        end
        return true, false
    end
    self.noNextAt = self.noNextAt or now
    if now - self.noNextAt >= 1 then
        self:recall()
        self.message = 'No next mob; recalling the pulling pet'
    else self.message = 'Briefly checking for another mob' end
    return false, false
end

return M
