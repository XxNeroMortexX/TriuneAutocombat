-- Created By: NeroMorte - Local capture, multi-bot replay, data-only persistence and website parsing.
local source = assert(io.open('TAC/lua/tac/flag_tracker.lua')):read('*a')
local callbacks, packets, now = {}, {}, 1792267200
local realTime = os.time
local function instance(name)
    local p = assert(loadfile('TAC/lua/tac/flag_tracker.lua'))()
    local c = { flag_tracker = { listen = true, dialogue = true, notify = false } }
    local event, network = nil, {}
    local subscribers = {}
    network.available = function() return true end
    network.peers = function() return { { name = 'Mortefreddo' }, { name = 'BotTwo' }, { name = 'EmptyBot' } } end
    network.peer = function() return nil end
    network.subscribe = function(topic, fn) subscribers[topic] = fn; return function() subscribers[topic] = nil end end
    network.broadcast = function(topic, data) packets[#packets + 1] = { topic = topic, data = data, from = name }; return true end
    network.send = function(to, topic, data) packets[#packets + 1] = { to = to, topic = topic, data = data, from = name }; return true end
    local mq = { configDir = '/tmp/triune-flags-test', gettime = function() return 1000 end,
        event = function(_, pattern, fn) assert(pattern == '#*#'); event = fn end, unevent = function() end,
        TLO = { Me = { CleanName = function() return name end }, EverQuest = {
            Server = function() return 'NMS' end, PID = function() return name == 'Mortefreddo' and 1 or 2 end },
            Zone = { ShortName = function() return 'potranquility' end },
            Target = { Type = function() return 'NPC' end, CleanName = function() return 'Adler Fuirstel' end },
        } }
    p.onInit({ mq = mq, ctrl = c, boxnet = network, saveLoadout = function() end })
    p.onTick(); callbacks[name] = subscribers
    p.testCore = { mq = mq, ctrl = c, boxnet = network, saveLoadout = function() end }
    return p, c, event
end
os.time = function() return now end
os.execute('mkdir -p /tmp/triune-flags-test')
for _, name in ipairs({ 'Mortefreddo', 'BotTwo', 'EmptyBot' }) do
    local path = '/tmp/triune-flags-test/triune_flag_tracker_NMS_' .. name .. '.tsv'
    os.remove(path); os.remove(path .. '.bak'); os.remove(path .. '.tmp')
end
local a, config, event = instance('Mortefreddo')
local aCallbacks = callbacks.Mortefreddo
assert(a.classify('You have received a character flag!') == 'Flag')
assert(a.classify('You have completed a part of your character flag!') == 'Flag')
assert(a.classify('The key has been added to your key ring.') == 'Key')
assert(a.classify("Your task 'A Quest' has been updated.") == 'Quest')
assert(a.classify("You say, 'Hail, Adler Fuirstel'") == 'Hail')
assert(a.classify("Adler Fuirstel says, 'You have received a flag!'", true) == 'Dialogue')
assert(not a.classify("Other says, 'You have received a flag!'", false))
assert(not a.classify("Other tells you, 'You have received a character flag!'"))
assert(not a.classify('[Flag Tracker] Mortefreddo | Flag: You have received a character flag!'))
assert(not a.classify('You hit a rat for 20 points of damage.'))
config.flag_tracker.rules = { { text = 'custom unlock %s', kind = 'Flag' } }
assert(a.classify('custom unlock %s recorded') == 'Flag' and not a.classify('custom unlock abc recorded'))
event('You have received a character flag!'); event('You have received a character flag!')
assert(#a.state.bots.mortefreddo.events == 1, 'same chat line was duplicated')
now = now + 3; event('The key has been added to your key ring.')
assert(#a.state.bots.mortefreddo.events == 2)
local b = instance('BotTwo')
local own = a.state.bots.mortefreddo.events[1]
b.receive({ name = 'Fake', server = 'NMS', events = { own } }, { character = 'Mortefreddo', server = 'NMS' })
assert(not b.state.bots.fake)
b.receive({ name = 'Mortefreddo', server = 'OtherServer', events = { own } }, { character = 'Mortefreddo' })
assert(not b.state.bots.mortefreddo)
b.receive({ name = 'Mortefreddo', server = 'NMS', events = { own } }, { character = 'Mortefreddo', server = 'NMS' })
b.receive({ name = 'Mortefreddo', server = 'NMS', events = { own } }, { character = 'Mortefreddo', server = 'NMS' })
assert(#b.state.bots.mortefreddo.events == 1)
assert(#b.roster() == 3, 'roster omitted a bot with no observed events')
assert(a.saveHistory())
local saved = assert(io.open(a.state.path)):read('*a'); assert(saved:find('TriuneFlagTracker\t1', 1, true))
local reloaded = instance('Mortefreddo')
assert(#reloaded.state.bots.mortefreddo.events == 2 and reloaded.state.bots.mortefreddo.events[1].kind == 'Key')
assert(not a.websiteID('https://evil.example/character/182133/progression'))
assert(not a.websiteID('182133;calc.exe'))
assert(a.websiteID('https://nms.bestemu.com/character/182133/progression') == '182133')
local html = [[<h1>Mortefreddo</h1> shared account-wide
<div class="n">1<small>/2</small></div><div class="l">Time Flags</div>
<div class="st on"><div class="nm">Adler Fuirstel</div><div class="ds">Hail Adler.</div></div>
<div class="st next-up"><div class="nm">Grummus<span class="stage">2 stages</span></div><div class="ds">Kill <b>Grummus</b>.</div></div>]]
local w = assert(a.parseWebsite(html, 'Mortefreddo', '182133'))
assert(w.accountWide and #w.rows == 2 and w.rows[1].done and not w.rows[2].done)
assert(w.rows[2].name == 'Grummus' and w.rows[2].detail == 'Kill Grummus.')
assert(not a.parseWebsite(html, 'BotTwo', '182133'))
assert(not a.parseWebsite('<h1>Mortefreddo</h1> Login', 'Mortefreddo', '182133'))
a.state.bots.mortefreddo.website = w
assert(a.saveHistory())
local webReload = instance('Mortefreddo')
assert(webReload.state.bots.mortefreddo.website.rows[2].name == 'Grummus')
a.state.outbound = {}; a.queueWebsite('BotTwo')
assert(#a.state.outbound == 1)
local packet = a.state.outbound[1]
b.receiveWebsite(packet, { character = 'Fake', server = 'NMS' }); assert(not b.state.bots.mortefreddo.website)
b.receiveWebsite(packet, { character = 'Mortefreddo', server = 'NMS' })
assert(b.state.bots.mortefreddo.website.rows[1].done)
-- History replay: an offline bot catches events without rebroadcast loops.
a.state.outbound = {}; aCallbacks['flags:request']({ server = 'NMS' }, { character = 'BotTwo', server = 'NMS' })
assert(#a.state.outbound >= 1)
for _, p in ipairs(a.state.outbound) do
    if not p.website then b.receive(p, { character = 'Mortefreddo', server = 'NMS' }) end
end
assert(#b.state.bots.mortefreddo.events == 2)
local queued = #a.state.outbound
aCallbacks['flags:request']({ server = 'NMS' }, { character = 'BotTwo', server = 'NMS' })
assert(#a.state.outbound == queued, 'history requests ignored their throttle')
-- Latest flags survive a long conversation; all storage remains bounded.
for i = 1, 150 do now = now + 3; event("You say, 'Hail, NPC " .. i .. "'") end
assert(#a.state.bots.mortefreddo.events == 100)
local flag, key = false, false
for _, e in ipairs(a.state.bots.mortefreddo.events) do flag = flag or e.kind == 'Flag'; key = key or e.kind == 'Key' end
assert(flag and key)
assert(source:find("'flag_tracker'", 1, true))
assert(source:find('FlagTrackerMatrix', 1, true) and source:find('FlagTrackerBots', 1, true))
assert(not source:find('bladesofdiscord', 1, true), 'reference database must never be imported')
-- Render real plugin UI through clipped-child and formatter-sensitive ImGui doubles.
local roots, children, themes, tables = 0, 0, 0, 0
ImGuiCond = { FirstUseEver = 1 }; ImGuiTableFlags = { Borders=1, RowBg=2, Resizable=4, ScrollY=8, ScrollX=16 }
ImGuiTableColumnFlags = { WidthFixed = 1 }; ImVec2 = function(x,y) return {x,y} end
bit = bit or { bor = function(...) local n=0; for _,v in ipairs({...}) do n=n+v end return n end }
local gui = setmetatable({
    Begin=function() roots=roots+1; return true,true end, End=function() roots=roots-1 end,
    BeginChild=function() children=children+1; return false end, EndChild=function() children=children-1 end,
    BeginTable=function() tables=tables+1; return true end, EndTable=function() tables=tables-1 end,
    BeginTabBar=function() return true end, BeginTabItem=function() return true end,
    BeginCombo=function() return false end, Button=function() return false end,
    Selectable=function() return false end, IsItemHovered=function() return false end,
    Checkbox=function(_,v) return v,false end, InputText=function(_,v) return v end,
    TextUnformatted=function(v) assert(type(v)=='string') end,
    TextColored=function(_,_,_,_,fmt,value) assert(fmt=='%s' and type(value)=='string') end,
}, { __index=function() return function() end end })
local api = webReload.testCore
api.ImGui=gui; api.px=function(v) return v end
api.pushTheme=function() themes=themes+1 end; api.popTheme=function() themes=themes-1 end
api.preBeginWindow=function() end; api.postBeginWindow=function() end; api.preEndWindow=function() end
api.windowFlags=function(_,f) return f end
webReload.onInit(api); api.ctrl.show_flag_tracker=true; webReload.state.selected='mortefreddo'
webReload.onDrawUI()
assert(roots==0 and children==0 and tables==0 and themes==0, 'ImGui scopes were not balanced')
local settings = a.onSaveSettings(); assert(settings.listen and settings.rules[1].text=='custom unlock %s')
a.onLoadSettings({ websiteID='https://evil.example/', rules={false,{text='valid phrase',kind='Flag'}} })
assert(not a.onSaveSettings().websiteID and #a.onSaveSettings().rules==1)
a.onDestroy(); b.onDestroy(); reloaded.onDestroy(); webReload.onDestroy()
os.time = realTime
print('PASS: progression capture, own identity, bot replay, persistence, latest-kind retention, NMS website parsing and matrix')
