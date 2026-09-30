-- Exercise the actual gem-casting function with MacroQuest calls isolated.
local f = assert(io.open('TAC/lua/triune.lua', 'r'))
local source = f:read('*a'); f:close()
assert(loadfile('TAC/lua/triune.lua'))
local cast = assert(source:match('(function runtime%.castGem.-\nend)\n\nfunction runtime%.fireAA'))
local function check(targetType, beneficial, recipient, original, heal, moving, bard)
    local targets, commands = {}, {}
    local sp = setmetatable({
        TargetType = function() return targetType end,
        Beneficial = function() return beneficial end,
        Mana = function() return 0 end,
        Duration = function() return 0 end,
        CastTime = function() return 1000 end,
    }, { __call = function() return true end })
    local tracker = { isLockedOut = function() return false end }
    local runtime = {
        lastCast = {},
        isHealAction = function() return heal end,
        isDetrimentalAction = function() return not beneficial end,
        isTargetInRange = function() return true end,
        setTarget = function(id) targets[#targets+1] = id; return true end,
        stopMovementForCast = function() end,
        recordPetBuff = function() end,
        abortPendingCast = function(orig, id, keep)
            tracker.activeSpell = nil
            if orig > 0 and orig ~= id and not keep then targets[#targets+1] = orig end
        end,
    }
    local mq = { cmd = function(cmd) commands[#commands+1] = cmd end,
        cmdf = function(fmt, ...) commands[#commands+1] = string.format(fmt, ...) end,
        delay = function() end,
        TLO = { Spell = function() return sp end,
            Target = { ID = function() return original end },
            Me = { ID = function() return 7 end, Combat = function() return false end,
                CurrentMana = function() return 100 end, PctMana = function() return 100 end,
                Moving = function() return moving end,
                SpellReady = function() return function() return true end end,
                Pet = { ID = function() return 8 end },
            },
        },
    }
    local env = setmetatable({ runtime = runtime, mq = mq, castTracker = tracker,
        ctrl = {}, os = { clock = function() return 100 end },
        isFeignDeathAbility = function() return false end,
        isSitting = function() return false end, isDucking = function() return false end,
        hasSpellReagents = function() return true end,
        isGemMatching = function() return true end,
        buffActive = function() return false end,
        bardKeepSinging = function() return false end,
        isHostileTarget = function(id) return id == 99 end,
        castThroughHostileTarget = function(self, hostile, isHeal)
            return self == true and hostile == true and isHeal == true
        end,
        isTargetRequiredSpell = function() return targetType == 'Single' end,
        clearCursor = function() end, isSpawnMyPet = function() return false end,
        isAnyPet = function() return false end,
    }, { __index = _G })
    assert(load(cast, 'castGem', 't', env))()
    local success = runtime.castGem(1, { spell = 'test', cls = bard and 'Brd' or 'Wiz', kind = 'buff' }, recipient)
    return targets, tracker, runtime, commands, success
end
for _, original in ipairs({99, 42, 0}) do
    for _, recipient in ipairs({7, 8}) do
        for _, bard in ipairs({false, true}) do
            local targets, tracker, runtime, commands, success = check('Self', true, recipient, original, false, false, bard)
            assert(success and #targets == 0 and tracker.targetRequired == false)
            assert(runtime.restoreTargetId == nil)
            for _, command in ipairs(commands) do assert(not command:find('/target', 1, true)) end
        end
    end
end
-- A moving aborted Self cast must not trigger a restoration target switch either.
local targets, _, _, _, success = check('Self', true, 7, 99, false, true, false)
assert(not success and #targets == 0)
-- Actual targeted buffs still select self or the pet and hold it during casting.
for _, recipient in ipairs({7, 8}) do
    local targets, tracker, runtime, _, success = check('Single', true, recipient, 99, false, false, false)
    assert(success and targets[1] == recipient and tracker.targetRequired == true and runtime.restoreTargetId == 99)
end
-- Preserve the existing hostile-target self-heal exception.
local targets, tracker = check('Single', true, 7, 99, true, false, false)
assert(#targets == 0 and tracker.targetRequired == false)
-- Missing metadata, group/PBAE, and detrimental Self effects do not gain the exception.
for _, kind in ipairs({'', 'NULL', 'Group v1', 'PB AE'}) do
    local targets = check(kind, true, 7, 99, false, false, false)
    assert(targets[1] == 7)
end
local targets = check('Self', false, 7, 99, false, false, false)
assert(targets[1] == 7)
print('PASS: Self spell target preservation, bard/abort paths, targeted buffs, and existing self-heals')
