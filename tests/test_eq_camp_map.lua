-- Exercise actual native-map helper functions with an isolated MQ2Map command sink.
local f = assert(io.open('TAC/lua/triune.lua', 'r'))
local source = f:read('*a'); f:close()
assert(loadfile('TAC/lua/triune.lua'))
local helpers = assert(source:match('(function runtime%.eqCampMapLoaded.-)\nfunction UI%.startEngine'))
local commands, loaded, zone, character = {}, true, 'testzone', 'Tester'
local plugin = setmetatable({ IsLoaded = function() return loaded end }, { __call = function() return 'mq2map' end })
local runtime = {}
local ctrl = { camp_loc = { x = 200.9, y = -100.8, z = 3.5 }, camp_radius = 100 }
local mq = { cmd = function(command) commands[#commands+1] = command end,
    TLO = { Plugin = function() return plugin end,
        Zone = { ShortName = function() return zone end },
        Me = { CleanName = function() return character end },
    },
}
local env = setmetatable({ runtime = runtime, ctrl = ctrl, mq = mq }, { __index = _G })
assert(load(helpers, 'eqCampMap', 't', env))()
runtime.updateEqCampMap()
assert(#commands == 1)
assert(commands[1]:find('/maploc -100 200 3 size 50 width 2 radius 100', 1, true))
assert(commands[1]:find('label Triune Camp', 1, true))
runtime.updateEqCampMap(); assert(#commands == 1) -- no per-tick commands
ctrl.camp_radius = 10000
runtime.updateEqCampMap()
assert(#commands == 3 and commands[2] == '/squelch /maploc remove -100 200 3')
assert(commands[3]:find('radius 10000', 1, true))
-- Clear stays hidden even if the puller automatically recreates its camp.
runtime.clearEqCampMap(true)
assert(#commands == 4 and runtime.eqCampMapMarker == nil)
ctrl.camp_loc = { x = 300, y = 400, z = 0 }
runtime.updateEqCampMap(); assert(#commands == 4)
-- Set Here or START re-enables the marker.
runtime.eqCampMapSuppressed = false
runtime.updateEqCampMap(); assert(#commands == 5)
ctrl.show_eq_camp_radius = false
runtime.updateEqCampMap(); assert(#commands == 6)
runtime.updateEqCampMap(); assert(#commands == 6)
ctrl.show_eq_camp_radius = true
runtime.updateEqCampMap(); assert(#commands == 7)
-- Missing MQ2Map does not dispatch commands; reload refreshes unchanged state.
loaded = false
runtime.updateEqCampMap(); assert(#commands == 7)
loaded = true
runtime.updateEqCampMap(); assert(#commands == 9)
-- Camp removal and invalid coordinates clear only the camp location.
ctrl.camp_loc = nil
runtime.updateEqCampMap(); assert(#commands == 10)
ctrl.camp_loc = { x = 1, y = 2, z = 3 }
runtime.updateEqCampMap(); assert(#commands == 11)
ctrl.camp_loc = { x = 'bad', y = 2, z = 3 }
runtime.updateEqCampMap(); assert(#commands == 12)
-- Every clear control is wired; START and Set Here re-enable the display.
local _, count = source:gsub('runtime%.clearEqCampMap%(true%)', '')
assert(count == 4)
assert(source:match('function UI%.startEngine%(%)%s+%-%-[^\n]+\n%s+runtime%.eqCampMapSuppressed = false'))
for _, command in ipairs(commands) do
    assert(command ~= '/squelch /maploc remove' and command ~= '/maploc remove')
    assert(not command:find('/mapfilter', 1, true))
end
print('PASS: native camp marker, radius refresh, Clear suppression, re-enable, MQ2Map reload, and scoped removal')
