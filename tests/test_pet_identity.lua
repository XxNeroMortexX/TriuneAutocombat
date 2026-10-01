-- Edited By: NeroMorte - Execute original multi-pet tracking against reversed spawn/class order.
local f = assert(io.open('TAC/lua/triune.lua')); local source = f:read('*a'); f:close()
local now = 10
local pets = {
    [278] = { name = 'Varndrim', race = 'Spectre' },
    [279] = { name = 'Poisonsilk', race = 'Spider' },
    [280] = { name = 'Morer', race = 'Air Elemental' },
}
local living = { 279, 278, 280 }
local petState = { myPets = { Nec = 279, Mag = 278, Bst = 280 }, PET_CLASSES = { Nec = true, Mag = true, Bst = true } }
local runtime, ctrl = {}, { pet_names = {} }
local function spawn(id)
    local p = pets[id]
    return setmetatable({ CleanName = function() return p and p.name end,
        Race = function() return p and p.race end }, { __call = function() return p ~= nil end })
end
local env = setmetatable({ petState = petState, runtime = runtime, ctrl = ctrl,
    os = { clock = function() return now end }, myClasses = { 'Nec', 'Mag', 'Bst' },
    mq = { TLO = { Spawn = spawn } },
    isSpawnAlive = function(id) return pets[id] ~= nil end,
    isSpawnMyPet = function(id) return pets[id] ~= nil end,
    spawnCleanName = function(id) return pets[id].name end,
    getAllMyPets = function() return living end,
    classToPetCmdScope = function(cls) return cls:lower() end,
    petClsForName = function(name)
        for cls, n in pairs(ctrl.pet_names) do if n:lower() == name:lower() then return cls end end
    end,
}, { __index = _G })
local chunks = {
    assert(source:match('(local function petTrackedCls.-\nend)')),
    assert(source:match('(local function prunePetTracking.-)\n\n%-%- Assigns')),
    assert(source:match('(local function trackPet.-)\n\n%-%- Collects')),
    assert(source:match('(function runtime%.detectPetClassFromSpawn.-)\n\n%-%- Maps every')),
    assert(source:match('(local function reconcilePets.-)\n\n%-%- One entry')),
    assert(source:match('(local function getMultiPetList.-)\n\n%-%- %-%-%-')),
    'runtime.testSlots = getMultiPetList',
}
assert(load(table.concat(chunks, '\n'), 'actualPetMapping', 't', env))()
local slots, extra = runtime.testSlots()
assert(slots[1].petId == 278 and slots[2].petId == 280 and slots[3].petId == 279)
assert(#extra == 0 and petState.myPets.Mag == 280 and petState.myPets.Nec == 278)
-- Completely unknown pets must not be assigned arbitrarily to class-scoped commands.
pets[278].race, pets[280].race = 'Unknown', 'Unknown'
petState.myPets = {}; now = 11
slots, extra = runtime.testSlots()
assert(#extra == 3 and slots[1].petId == nil and slots[2].petId == nil and slots[3].petId == nil)
-- Learned summon names resolve even with illusions/unknown races.
ctrl.pet_names = { Nec = 'Varndrim', Mag = 'Morer', Bst = 'Poisonsilk' }; now = 12
slots, extra = runtime.testSlots()
assert(slots[1].petId == 278 and slots[2].petId == 280 and slots[3].petId == 279 and #extra == 0)
-- Actual downtime threat predicate: selecting an owned NPC-type pet is harmless; a hostile NPC remains dangerous.
local own = true
local target = setmetatable({ ID = function() return 280 end, Dead = function() return false end,
    Type = function() return 'NPC' end, PctAggro = function() return 100 end,
    SecondaryPctAggro = function() return 0 end }, { __call = function() return true end })
local threatEnv = setmetatable({ runtime = { anyXtarAlive = function() return false end },
    mq = { TLO = { Target = target, Me = { Combat = function() return false end,
        CombatState = function() return 'RESTING' end, XTHaterCount = function() return 0 end,
        XTAggroCount = function() return 0 end } } },
    isSpawnMyPet = function() return own end }, { __index = _G })
local threat = assert(source:match('(function runtime%.hasDowntimeAggroThreat.-)\n\n%-%- Waiting for'))
assert(load(threat, 'actualPetThreat', 't', threatEnv))()
assert(not threatEnv.runtime.hasDowntimeAggroThreat()); own = false
assert(threatEnv.runtime.hasDowntimeAggroThreat())
print('PASS: reversed roster correction, unknown-class safety, learned names, own-pet snapshot threat exclusion')
-- Keep sending pet commands and invalidating telemetry, but suppress routine chat unless Debug is enabled.
local chat, sent, invalidated = 0, 0, 0
local commandEnv = setmetatable({ ctrl = {}, runtime = { petCamp = { noteCommand = function() invalidated = invalidated + 1 end } },
    petState = {}, print = function() chat = chat + 1 end,
    mq = { cmdf = function() sent = sent + 1 end } }, { __index = _G })
local command = assert(source:match('(local function sendPetCmd.-)\n\n%-%- Best guess'))
assert(load(command..'\nreturn sendPetCmd', 'quietPetCommands', 't', commandEnv))()('attack', 'mag')
assert(sent == 1 and invalidated == 1 and chat == 0)
commandEnv.ctrl.debug_mode = true
assert(load(command..'\nreturn sendPetCmd', 'debugPetCommands', 't', commandEnv))()('back', 'mag')
assert(sent == 2 and invalidated == 2 and chat == 1)
print('PASS: pet commands stay functional and quiet except Debug logging')
