-- Created By: NeroMorte - Exercise actual render dispatch and failure before AA Begin.
local file = assert(io.open('TAC/lua/triune.lua', 'r'))
local source = file:read('*a'); file:close()
local hooks = assert(source:match('(    function pm%.drawUI.-\n    end)')) .. '\n' ..
    assert(source:match('(    function pm%.drawPluginSettings.-\n    end)'))
local pm, drawn, reported = {}, {}, {}
pm.reportError = function(plugin, phase, err)
    plugin.status = 'Error'
    reported[#reported + 1] = { phase = phase, err = err }
end
local env = setmetatable({ pm = pm }, { __index = _G })
assert(load(hooks, 'actualPluginDrawDispatch', 't', env))()
pm.pluginOrder = { 'first', 'broken', 'later' }
pm.plugins = {
    first = { enabled = true, instance = { onDrawUI = function() drawn[#drawn + 1] = 'first' end } },
    broken = { enabled = true, instance = { onDrawUI = function() error('original render error') end } },
    later = { enabled = true, instance = { onDrawUI = function() drawn[#drawn + 1] = 'later' end } },
}
local ok, err = pcall(pm.drawUI)
assert(not ok and err:find('original render error', 1, true))
assert(#drawn == 1 and drawn[1] == 'first', 'No later plugin may render into a failed window stack')
assert(not pm.inDraw and pm.plugins.broken.status == 'Error')
assert(#reported == 1 and reported[1].phase == 'onDrawUI')
-- Ordinary success and previously disabled/error plugins retain their normal dispatch behavior.
pm.plugins.first.enabled = false; pm.drawUI()
assert(#drawn == 2 and drawn[2] == 'later' and not pm.inDraw)
for _, wasInDraw in ipairs({ false, true }) do
    pm.inDraw = wasInDraw
    pm.plugins.settings = { enabled = true, instance = {
        onDrawSettings = function() error('original settings error') end } }
    ok, err = pcall(pm.drawPluginSettings, 'settings')
    assert(not ok and err:find('original settings error', 1, true))
    assert(pm.inDraw == wasInDraw and pm.plugins.settings.status == 'Error')
end
pm.plugins.settings = { enabled = true, instance = { onDrawSettings = function() end } }
assert(pm.drawPluginSettings('settings') == true)
-- A bad AA sort must fail while no window or theme has been opened.
local opened, themed = 0, 0
local plugin = dofile('TAC/lua/tac/auto_aa.lua')
plugin.onInit({ ctrl = { show_auto_aa = true }, runtime = {}, mq = {},
    ImGui = { Begin = function() opened = opened + 1 end },
    pushTheme = function() themed = themed + 1 end,
})
plugin.AA.getFilteredSortedAAs = function() error('injected AA sort error') end
ok, err = pcall(plugin.onDrawUI)
assert(not ok and err:find('injected AA sort error', 1, true))
assert(opened == 0 and themed == 0, 'AA sorting must precede ImGui/theme scopes')
print('PASS: plugin render errors reach MQ, later draw hooks stop, original tracebacks survive, and AA sorts before Begin')
