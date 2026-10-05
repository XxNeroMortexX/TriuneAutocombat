-- Created By: NeroMorte - Exercise actual dispatch, healing, movement and plugin gates.
local function read(path)
    local f = assert(io.open(path)); local text = f:read('*a'); f:close(); return text
end
local source = read('TAC/lua/triune.lua')
local function functionCode(signature)
    local first = assert(source:find(signature, 1, true))
    local last = assert(source:find('\nend', first, true))
    return source:sub(first, last + 3)
end
local runtime = { trashMode = true }
local ctrl = { combat_style = 'Spell', pull_style = 'Spell', mode = 'Puller' }
local loadout = { gems = { { spell = 'Heal', pct = 100 } }, aas = { Heal = { enabled = true } },
    clickies = { { name = 'Healing Wand' } }, actions = { Mend = { enabled = true, pct = 100 } }, discs = {} }
local env = setmetatable({ runtime = runtime, ctrl = ctrl, loadout = loadout,
    print = function() end, mq = { TLO = { Me = { ID = function() return 1 end } } },
    isCasting = function() return false end, isCastingOrStarting = function() return false end,
    isSitting = function() return false end, isDucking = function() return false end,
    isSpawnAlive = function() return true end, pctHP = function() return 20 end,
}, { __index = _G })
for _, signature in ipairs({ 'function runtime.castGem(i, g, id)', 'function runtime.fireAA(name, a, id)',
    'runtime.useClickie = function(c, id)', 'function runtime.castPullSpell(tid)',
    'function runtime.processDowntimeBuffing()' }) do
    assert(load(functionCode(signature), signature, 't', env))()
end
-- No MQ reads, commands, target changes or loadout mutation are allowed past these guards.
assert(not runtime.castGem(1, loadout.gems[1], 1))
assert(not runtime.fireAA('Heal', loadout.aas.Heal, 1))
assert(not runtime.useClickie(loadout.clickies[1], 1))
assert(not runtime.castPullSpell(99))
assert(not runtime.processDowntimeBuffing())
assert(load(functionCode('function runtime.setTrashMode(enabled)'), 'toggle', 't', env))()
runtime.setTrashMode(false)
assert(runtime.trashMode == false and ctrl.combat_style == 'Spell' and ctrl.pull_style == 'Spell')
assert(loadout.aas.Heal.enabled and loadout.gems[1].pct == 100)
runtime.setTrashMode(true)

-- A blocked high-priority healing spell/AA/clickie must not starve allowed Mend.
runtime.isHealAction = function(name) assert(name == 'Mend'); return true end
runtime.resolveTargetId = function() return 1 end
runtime.isTargetInRange = function() return true end
runtime.conditionMet = function() return true end
runtime.isSkillReady = function() return true end
runtime.stopMovementForCast = function() end
local mend = 0
runtime.fireSkill = function(name) assert(name == 'Mend'); mend = mend + 1; return true end
assert(load(functionCode('function runtime.processHealPriority()'), 'heals', 't', env))()
assert(runtime.processHealPriority() and mend == 1)

-- Actual position policy: Spell pulls approach melee during trash and restore their saved reach afterward.
env.meleeDesiredRange = function() return 12 end
env.rangedApproachDist = function(n) return n end
env.maxMeleeDistance = function() return 15 end
ctrl.pull_stand_back = true; ctrl.pull_engage_dist = 100; ctrl.ranged_dist = 40
local rangeCode = functionCode('local function desiredRange(id)')
local getRange = assert(load(rangeCode .. '\nreturn desiredRange', 'range', 't', env))()
assert(getRange(99) == 12)
runtime.setTrashMode(false); assert(getRange(99) == 100)
ctrl.pull_stand_back = false; assert(getRange(99) == 40)
runtime.setTrashMode(true); assert(getRange(99) == 12)
assert(ctrl.combat_style == 'Spell' and ctrl.pull_style == 'Spell')

-- Execute independent AA activation entrypoints: pending work remains queued with its retries intact.
local plugin = dofile('TAC/lua/tac/auto_aa.lua')
plugin.onInit({ runtime = runtime, ctrl = {}, mq = {} })
plugin.AA.pendingConsumeExperience = { tries = 2, at = 1 }
plugin.AA.pendingFireworksSummon = { tries = 3, at = 1 }
assert(not plugin.AA.activateFireworks(17788))
assert(not plugin.AA.processConsumeExperience())
assert(not plugin.AA.processPendingFireworksSummon())
assert(not plugin.AA.checkAutoSummonFireworks())
assert(plugin.AA.pendingConsumeExperience.tries == 2 and plugin.AA.pendingFireworksSummon.tries == 3)

-- Buffbot's shared gate releases combat without clearing its queue/configuration.
local buffSource = read('TAC/lua/tac/buffbot.lua')
local buffEnv = { plugin = {}, core = { runtime = runtime }, cfg = { enabled = true }, rt = { currentJob = {} } }
local hold = assert(buffSource:match('(function plugin%.wantsCombatHold%(%).-\nend)'))
assert(load(hold, 'buffHold', 't', buffEnv))()
assert(not buffEnv.plugin.wantsCombatHold())
runtime.setTrashMode(false); assert(buffEnv.plugin.wantsCombatHold())
assert(buffEnv.cfg.enabled and buffEnv.rt.currentJob)
print('PASS: Trash Mode dispatch, saved selections, Mend priority, spell-pull melee range, queued AA activations and Buffbot hold')
