-- Created By: NeroMorte - Drive the actual AA window trainer with MQ/UI doubles.
local function world()
    local w = { points = 100, combat = false, haters = 0, activeTab = 1, selected = 0,
        clicks = 0, nativeClicks = 0, commands = {}, rows = { 'Innate Run Speed', 'Run Speed', 'Run Speed Plus' } }
    local list = { Items = function() return #w.rows end,
        SelectedIndex = function() return w.selected end,
        Select = function(index) w.selected = index end,
        LeftMouseUp = function() end,
        List = function(row, col)
            if type(row) == 'string' then return 1 end -- Deliberately misleading partial lookup.
            if not w.rows[row] then return nil end
            if col == 2 then return tostring(w.rank or 0) .. '/5' end
            if col == 3 then return '1' end
            return w.rows[row]
        end }
    local tabs = { CurrentTabIndex = function() return w.activeTab end,
        SetCurrentTab = function(tab) w.activeTab = tab end }
    local button = { LeftMouseDown = function() end,
        LeftMouseUp = function() w.nativeClicks = w.nativeClicks + 1 end }
    local win = { Name = function() return 'AAWindow' end, Open = function() return true end,
        Child = function(name)
            if name == 'AAW_GeneralList' then return list end
            if name == 'AAW_Subwindows' then return tabs end
            if name == 'AAW_TrainButton' and not w.noButton then return button end
        end }
    local mq = { TLO = { Window = function() return win end, Me = {
        Combat = function() return w.combat end,
        CombatState = function() if w.brokenCombatState then error('Unavailable') end; return 'ACTIVE' end,
        AutoFire = function() return false end, Moving = function() return false end,
        XTHaterCount = function() return w.haters end,
        AAPoints = function() return w.points end, Level = function() return 65 end,
        AltAbility = function() return nil end,
    }, AltAbility = function() return nil end },
        cmdf = function(fmt, ...)
            local command = string.format(fmt, ...); w.commands[#w.commands + 1] = command
            local selected = command:match('listselect (%d+)')
            if selected then w.selected = tonumber(selected) end
            if command:find('AAW_TrainButton leftmouseup', 1, true) then
                w.clicks = w.clicks + 1; w.points = w.points - 1
            end
        end }
    w.ctrl = { auto_spend_aa = true, auto_aa_selection = 'priorities',
        auto_aa_priorities = { ['Run Speed'] = true }, auto_aa_ignored = {},
        auto_aa_target_ranks = {}, auto_spend_aa_name = 'Alternately Advanced Fireworks' }
    local plugin = dofile('TAC/lua/tac/auto_aa.lua')
    plugin.onInit({ ctrl = w.ctrl, mq = mq, runtime = {
        isCasting = function() return false end, cachedAAData = {},
        isCombat = function() return false end, anyXtarAlive = function() return false end,
    }, saveLoadout = function() end })
    w.aa = plugin.AA
    w.aa.purchaseInfo = function(name) return { name = name, rank = w.rank or 0, maxRank = 5,
        cost = 1, minLevel = 0, canTrain = true, isSpecial = w.aa.isSpecialTabAA(name) } end
    w.list = list
    function w.queue()
        assert(w.aa.startAATrainWorkflow('Run Speed', false, true))
        w.aa.pendingAATrain.step = 'select_item'; w.aa.pendingAATrain.nextStepAt = -1
        w.aa.processAATrainWorkflow()
        assert(w.selected == 2 and w.aa.pendingAATrain.step == 'click_train')
        w.aa.pendingAATrain.nextStepAt = -1
    end
    return w
end
local savedPrint = print; print = function() end
local w = world()
local _, row = w.aa.findAAInWindowLists('Run Speed', 1)
assert(row == 2) -- Reject wrong direct index; find exact row.
w.rows = { 'Innate Run Speed', 'Run Speed Plus' }
assert(w.aa.findAAInWindowLists('Run Speed', 1) == nil)
w.rows = { 'Summon Firework' }
assert(w.aa.findAAInWindowLists('Consume Experience', 4) == nil)
assert(w.aa.findAAInWindowLists('Alternately Advanced Fireworks', 4) ~= nil)
assert(not w.aa.rowMatches('Run Speed', 'Run Speed Plus'))
local callableList = { List = function() return setmetatable({}, { __call = function() return 801 end }) end }
assert(w.aa.listIndex(callableList, '=Run Speed') == 801)

w = world(); w.queue()
local scans = 0
w.aa.scanPlayerAAs = function() scans = scans + 1 end
w.aa.requestScan(0); w.aa.runPendingScan()
assert(scans == 0 and w.aa.scanRequestAt ~= nil)
w.aa.processAATrainWorkflow()
assert(w.clicks == 1 and w.nativeClicks == 0 and w.points == 99)
assert(w.aa.pendingAATrain.step == 'verify')
w.aa.processAATrainWorkflow(); assert(w.clicks == 1)
w.aa.pendingAATrain = nil; w.aa.runPendingScan(); assert(scans == 1)

for _, change in ipairs({ function(x) x.ctrl.auto_aa_priorities['Run Speed'] = nil end,
    function(x) x.ctrl.auto_spend_aa = false end,
    function(x) x.ctrl.auto_aa_ignored['Run Speed'] = true end,
    function(x) x.ctrl.auto_aa_target_ranks['Run Speed'] = 1; x.rank = 1 end,
    function(x) x.selected = 1 end, function(x) x.activeTab = 2 end,
    function(x) x.rows[2] = 'Run Speed Plus' end,
    function(x) x.combat = true end, function(x) x.haters = 1 end,
    function(x) x.brokenCombatState = true end, function(x) x.noButton = true end }) do
    w = world(); w.queue(); change(w); w.aa.processAATrainWorkflow()
    assert(w.clicks == 0 and w.nativeClicks == 0 and w.aa.pendingAATrain == nil)
end
w = world(); w.combat = true
assert(not w.aa.startAATrainWorkflow('Run Speed')) -- Explicit manual purchase also waits for safety.
w = world(); w.haters = 1
assert(not w.aa.checkAutoSpendAA(false) and w.clicks == 0)
w = world(); w.ctrl.auto_aa_priorities = {}; w.ctrl.auto_aa_selection = 'all'
w.aa.scannedAAMap = { ['Run Speed'] = {} }
assert(w.aa.automaticAllowed('Run Speed', false))
assert(not w.aa.automaticAllowed('Consume Experience', false))
w.ctrl.auto_aa_selection = 'priorities'
assert(w.aa.automaticAllowed('Alternately Advanced Fireworks', true))
w.ctrl.auto_aa_priorities['Run Speed'] = true
assert(not w.aa.automaticAllowed('Alternately Advanced Fireworks', true))
print = savedPrint
print('PASS: exact row identity, Fireworks aliases, one Train click, queued-selection/limits and combat guards, All mode and cap preservation')
