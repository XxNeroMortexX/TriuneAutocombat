-- Exercise the production controller against deterministic multi-pet/server readings.
local module = assert(loadfile('TAC/lua/TAC_support_modules/pet_camp_controller.lua'))()
assert(loadfile('TAC/lua/triune.lua'))
local function fixture()
    local f = { now = 0, target = 99, safe = false, generation = 'zone1', atCamp = true,
        settled = true, dispatches = {},
        window = 0, flags = {}, commands = {}, probes = {}, restored = {}, xt = {}, mobs = {},
        pets = { { id = 280, name = 'Morer', cls = 'Nec', scope = 'nec' },
            { id = 278, name = 'Varndrim', cls = 'Mag', scope = 'mag' },
            { id = 279, name = 'Poisonsilk', cls = 'Bst', scope = 'bst' } },
        c = { running = true, mode = 'Puller', submode = 'Camp', pull_style = 'Pet', pet_camp_enabled = true,
            pet_camp_pull_back = true, pet_camp_batch_size = 20, pet_camp_assist_radius = 30, pet_camp_puller_class = 'Auto' } }
    local ctrl
    local api = {
        config = function() return f.c end, now = function() return f.now end,
        generation = function() return f.generation end, pets = function() return f.pets end,
        alive = function(id)
            for _, pet in ipairs(f.pets) do if pet.id == id then return true end end
            return f.mobs[id] and not f.mobs[id].dead or false
        end,
        hostile = function(id) return f.mobs[id] ~= nil and not f.mobs[id].dead end,
        readPet = function() return f.window, f.flags end,
        safeProbe = function() return f.safe end,
        target = function() return f.target end,
        targetPet = function(id) f.target = id; f.probes[#f.probes + 1] = id; return true end,
        restore = function(id) f.target = id; f.restored[#f.restored + 1] = id end,
        setTarget = function(id) f.target = id; return true end,
        targetSettled = function() return f.settled end,
        beginDispatch = function(id) f.dispatches[#f.dispatches + 1] = id end,
        endDispatch = function(force) f.forcedStop = force; f.dispatchEnded = (f.dispatchEnded or 0) + 1 end,
        command = function(verb, scope) f.commands[#f.commands + 1] = verb .. ' ' .. scope; ctrl:noteCommand(verb, scope) end,
        releasePets = function()
            if ctrl.held then
                for scope in pairs(ctrl.held) do f.commands[#f.commands + 1] = 'hold off ' .. scope end
                ctrl.held = nil
            end
        end,
        ensureCamp = function() end, holdCamp = function() f.returns = (f.returns or 0) + 1 end,
        atCamp = function() return f.atCamp end,
        pullerHome = function() return f.petHome ~= false end,
        campDistance = function(id) return f.mobs[id] and f.mobs[id].dist or math.huge end,
        inPullRadius = function(id) return f.mobs[id] and f.mobs[id].dist <= 500 end,
        directThreat = function(id) return f.mobs[id] and f.mobs[id].direct == true or false end,
        hostileXT = function() return f.xt end,
        engagedByUs = function(id) return f.mobs[id] and f.mobs[id].engaged == true or false end,
        resting = function() return f.resting end,
        find = function(excluded)
            local ids = {}; for id in pairs(f.mobs) do ids[#ids + 1] = id end; table.sort(ids)
            for _, id in ipairs(ids) do if not f.mobs[id].dead and f.mobs[id].dist <= 500 and not excluded[id] then return id end end
        end,
    }
    ctrl = module.new(api); f.ctrl = ctrl; ctrl:tickStates()
    return f, ctrl
end

-- Window readings never leak onto another pet; known false must remain false.
local f, c = fixture()
f.window, f.flags = 279, { taunt = false, hold = false, stance = 'FOLLOW' }
c:tickStates(); assert(c:value(279, 'taunt') == nil)
f.now = 0.4; c:tickStates()
assert(c:value(279, 'taunt') == false and c:value(278, 'taunt') == nil)
assert(c:value(279, 'assist') == nil and c:allValue('taunt') == nil)
c:petTell('Morer', "'Taunting attackers as ordered, Master.'")
assert(c:value(280, 'taunt') == true)
c:petTell('NotMyPet', "'No longer taunting attackers, Master.'")
assert(c:value(280, 'taunt') == true)
c:petTell('Morer', "'Changing position, Master.'")
assert(c:value(280, 'taunt') == true and c:value(280, 'stance') == nil)
c:noteCommand('taunt off', 'nec'); assert(c:value(280, 'taunt') == nil)
c:petTell('Morer', "'No longer taunting attackers, Master.'"); assert(c:value(280, 'taunt') == false)

-- No combat/cast/movement snapshots; matching settled windows restore the original target.
f, c = fixture(); c:tickStates(); assert(#f.probes == 0)
f.safe = true; c:tickStates(); assert(#f.probes == 1 and c.probe)
local id = c.probe.id
f.window, f.flags = id, { taunt = true, focus = false }
f.now = 0.1; c:tickStates(); assert(c.probe)
f.now = 0.5; c:tickStates(); assert(not c.probe and f.target == 99)
assert(c:value(id, 'taunt') == true)
-- A manual target change during snapshot wins over restoration.
f.now = 1; c:tickStates(); assert(c.probe)
f.target = 888; f.now = 1.2; c:tickStates(); assert(not c.probe and f.target == 888)
-- Death/replacement/zone reset cannot reuse previous flags.
f.pets = { { id = 281, name = 'Newpet', cls = 'Nec', scope = 'nec' } }
f.safe = false; c:tickStates(); assert(c:value(id, 'taunt') == nil and c:value(281, 'taunt') == nil)
f.generation = 'zone2'; c:tickStates(); assert(c.phase == 'IDLE' and c:value(281, 'taunt') == nil)

-- Unknown or OFF taunt blocks gathering, with no attack commands.
f, c = fixture(); f.mobs[100] = { dist = 200 }
c:combatTick(); assert(#f.commands == 0 and c.message:find('taunt'))
c:petTell('Morer', "'Taunting attackers as ordered, Master.'")
c:combatTick(); assert(c.tag.id == 100 and c.phase == 'GATHER')
assert(f.commands[#f.commands] == 'attack nec')
for _, cmd in ipairs(f.commands) do assert(cmd ~= 'attack all' and not cmd:find('qattack')) end
assert(c.batch[100] == nil) -- Sending an attack is not a confirmed tag.
-- Different nearby/group XTargets do not count as the pulling pet's confirmed tags.
f.xt = { 101 }; f.mobs[101] = { dist = 200, engaged = false }
f.now = 1; c:combatTick(); assert(c.tag.id == 100 and c.batch[101] == nil)
f.mobs[100].engaged = true; f.xt = { 100, 101 }
f.mobs[102] = { dist = 200 }
f.now = 2; c:combatTick(); assert(c.batch[100] and c.tag.id == 102)
-- Arrival at camp ends gathering immediately even though the requested total is 20.
f.mobs[100].dist = 25; f.now = 2.5
local have, engage = c:combatTick()
assert(have and engage and c.phase == 'FIGHT' and c.tag == nil)
assert(f.commands[#f.commands] == 'attack all' and c.held == nil)
local foundRecall = false
for _, cmd in ipairs(f.commands) do if cmd == 'back nec' then foundRecall = true end end
assert(foundRecall and f.forcedStop == true)
-- No new batch until old pull and hostile XTargets are gone.
f.mobs[100].dead = true; f.xt = { 102 }; f.mobs[102].engaged = true
f.now = 3; c:combatTick(); assert(c.phase == 'FIGHT' and c.tag == nil)
f.mobs[102].dead = true; f.xt = {}; f.mobs[101].dead = true
f.now = 4; c:combatTick(); assert(c.phase == 'GATHER' and c.tag == nil)

-- Quota reached recalls; an empty next scan briefly rechecks then recalls a smaller batch.
for _, goal in ipairs({ 1, 20 }) do
    f, c = fixture(); f.c.pet_camp_batch_size = goal
    c:petTell('Morer', "'Taunting attackers as ordered, Master.'")
    f.mobs[100] = { dist = 200 }; c:combatTick()
    f.mobs[100].engaged = true; f.xt = { 100 }; f.now = 1; c:combatTick()
    if goal == 1 then assert(c.phase == 'RETURN')
    else assert(c.phase == 'GATHER'); f.now = 2.1; c:combatTick(); assert(c.phase == 'RETURN') end
    assert(f.commands[#f.commands] == 'follow nec')
end

-- Tag timeout skips failure, pet death recalls, and direct threats permit defense without chase.
f, c = fixture(); c:petTell('Morer', "'Taunting attackers as ordered, Master.'")
f.mobs[100] = { dist = 200 }; c:combatTick(); f.now = 121; c:combatTick()
assert(c.tag == nil and c.skipped[100] and c.batch[100] == nil)
f.mobs[103] = { dist = 150, direct = true, engaged = true }; f.xt = { 103 }
assert(c:ownerAllowed(103)); assert(not c:ownerAllowed(100))
have, engage = c:combatTick(); assert(have and engage and c.phase == 'FIGHT')
f.pets = { f.pets[2], f.pets[3] }; f.safe = false; c:tickStates(); assert(c:value(280, 'taunt') == nil)
f.c.running = false; c:tickStates(); assert(c.phase == 'IDLE')

-- Pets fight in the radius without pull-back; owner still only helps inside assist radius.
f, c = fixture(); f.c.pet_camp_pull_back = false
f.mobs[100] = { dist = 200 }
have, engage = c:combatTick(); assert(have and not engage and f.commands[#f.commands] == 'attack all')
f.mobs[100].dist = 20; f.mobs[100].engaged = true; f.xt = { 100 }
have, engage = c:combatTick(); assert(have and engage)
f.c.pet_camp_enabled = false; assert(not c:enabled() and c:ownerAllowed(100))
-- Recalled pet must get home before an empty batch restarts; safe between-pull plugins keep working.
f, c = fixture(); c:petTell('Morer', "'Taunting attackers as ordered, Master.'")
f.petHome = false; c:combatTick(); f.now = 1.1; c:combatTick(); assert(c.phase == 'RETURN')
f.mobs[110] = { dist = 200 }; f.now = 2; c:combatTick(); assert(c.phase == 'RETURN' and c.tag == nil)
f.petHome = true; c.api.betweenPulls = function() return true end; c:combatTick()
assert(c.phase == 'IDLE' and c.message == 'Between-pull task')
c.api.betweenPulls = function() return false end; c:combatTick(); assert(c.tag.id == 110)
-- Known OFF fallback, target settling, assist enabled on dispatch, and taunt correction.
f, c = fixture()
for _, pet in ipairs(f.pets) do c:petTell(pet.name, "'No longer taunting attackers, Master.'") end
assert(c:choosePuller().scope == 'all')
f.mobs[100] = { dist = 300 }; f.settled = false
c:combatTick(); assert(c.tag and not c.tag.sent and #f.dispatches == 0)
f.now = 0.5; f.settled = true; c:combatTick()
assert(c.tag.sent and f.commands[#f.commands] == 'attack all' and f.dispatches[1] == 100)
assert(f.commands[#f.commands - 2] == 'assist on all')
for _, command in ipairs(f.commands) do assert(not command:find('assist off', 1, true)) end
c:petTell('Morer', "'Taunting attackers as ordered, Master.'")
assert(c:choosePuller().scope == 'nec')
f.now = 1; c:combatTick(); assert(c.phase == 'RETURN' and c.tag == nil)
assert(f.commands[#f.commands] == 'follow all')
local defaults = {}; module.defaults(defaults)
assert(defaults.pet_camp_enabled == false and defaults.pet_camp_batch_size == 1)
print('PASS: pet identity/cache/events, safe target snapshots, single taunting pet, confirmed tags, arrival/quotas, recall, defense and disabled behavior')

-- A matching ToT is insufficient: wait for the selected ID to appear in an actual XTarget slot.
f, c = fixture(); f.c.pet_camp_batch_size = 1
c:petTell('Morer', "'Taunting attackers as ordered, Master.'")
f.mobs[100] = { dist = 200, engaged = true }; f.mobs[101] = { dist = 250 }
c:combatTick(); f.now = 15; c:combatTick()
assert(c.tag.id == 100 and not c.batch[100] and c.phase == 'GATHER')
f.xt = { 100 }; f.now = 16; c:combatTick()
assert(c.phase == 'RETURN' and c.batch[100] and f.forcedStop == true)
-- Pets-only mode cannot acquire a fresh mob while another hostile XTarget remains.
f, c = fixture(); f.c.pet_camp_pull_back = false
f.mobs[100] = { dist = 200 }; f.mobs[101] = { dist = 210 }; f.mobs[102] = { dist = 220 }
c:combatTick(); assert(c.fightId == 100)
f.mobs[100].dead = true; f.xt = { 101 }; f.now = 1; c:combatTick()
assert(c.fightId == 101 and f.target == 101)
f.mobs[101].dead = true; f.xt = {}; f.now = 2; c:combatTick()
assert(c.fightId == 102)
print('PASS: exact XTarget confirmation, long-distance wait, count-one recall, remaining-fight priority')
