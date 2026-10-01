-- Edited By: NeroMorte - Quiet AA messages must not change priority bookkeeping or silence failures/status.
local f = assert(io.open('TAC/lua/tac/auto_aa.lua')); local source = f:read('*a'); f:close()
assert(loadfile('TAC/lua/tac/auto_aa.lua'))
local messages = {}
local AA = { BLOCKER_TEXT = { target = 'target rank reached' } }
local ctrl = { auto_aa_priorities = { TestAA = true } }
local env = setmetatable({ AA = AA, ctrl = ctrl, print = function(text) messages[#messages + 1] = text end }, { __index = _G })
local routine = assert(source:match('(function AA%.routineMessage.-\nend)'))
local priority = assert(source:match('(function AA%.notePriorityStatus.-)\n\n%-%- Edited By: NeroMorte'))
assert(load(routine..'\n'..priority, 'actualAAQuietMessages', 't', env))()
local info = { name = 'TestAA', cost = 10, rank = 3, maxRank = 18, canTrain = true }
AA.notePriorityStatus(info, 'target', 100); assert(#messages == 1)
ctrl.auto_aa_suppress_messages = true; AA.prioStatus = nil
AA.notePriorityStatus(info, 'target', 100)
assert(#messages == 1 and AA.prioStatus.TestAA.why == 'target')
AA.routineMessage('Bought a rank'); assert(#messages == 1)
ctrl.auto_aa_suppress_messages = false; AA.routineMessage('Bought a rank'); assert(#messages == 2)
-- Genuine training failures and explicitly requested status retain their original print calls.
assert(source:find("print(string.format('\\ar[Triune]\\ax Failed to open AA Window", 1, true))
assert(source:find("print(string.format('\\ay[Triune]\\ax AA purchase of", 1, true))
assert(source:find("print(string.format('\\ag[Triune]\\ax Auto AA: %s | Unspent", 1, true))
print('PASS: AA quiet opt-in, unsuppressed default, unchanged priority verdicts and visible errors/status')
