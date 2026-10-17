-- Created By: NeroMorte - Standalone ImGui conversion of James's MQ2HUD.ini [Main].
-- No MQ2HUD or Triune dependency. Does not read unrelated INI sections or execute macro commands.
local HUD = {}
HUD.colors = {
    GREY={0.5,0.5,0.5,1}, GREEN={0.2,0.8,0.2,1}, ['LIGHT BLUE']={0.43,0.63,1,1},
    BLUE={0.25,0.5,1,1}, WHITE={1,1,1,1}, YELLOW={1,1,0.2,1}, RED={1,0.25,0.25,1},
}
function HUD.read(mq, expression, fallback)
    local ok, value = pcall(mq.parse, expression)
    if not ok or value == nil then return fallback or 'N/A' end
    value = tostring(value)
    if value == '' or value == 'NULL' or value:find('${', 1, true) then return fallback or 'N/A' end
    return value
end
function HUD.capture(mq)
    local function get(expr, fallback) return HUD.read(mq, expr, fallback) end
    local function number(expr) return tonumber(get(expr, '0')) or 0 end
    local s = {
        name = get('${Me.CleanName}'),
        idle = get('${If[${Defined[idle]},${idle},N/A]}'),
        macro = get('${If[${Bool[${Macro.Name}]},${Macro.Name},No macro running]}'),
        xp = get('${Me.PctExp}'), rawXP = get('${Me.Exp}'),
        aa = get('${Me.PctAAExp}'), rawAA = get('${Me.AAExp}'),
        players = number('${SpawnCount[PC]}'), npcs = number('${SpawnCount[NPC]}'),
        namedCount = number('${SpawnCount[Named]}'), nearNPCs = number('${SpawnCount[NPC Radius 150 LOS]}'),
        targetID = number('${Target.ID}'), gms = {}, named = {}, spells = {},
        location = get('Y: ${Me.Y}  X: ${Me.X}  Z: ${Me.Z}'), heading = get('${Me.Heading}'),
        combatID = get('${If[${Defined[CombatTargetID]},${CombatTargetID},N/A]}'),
    }
    for i=1,4 do
        local gm = get('${NearestSpawn['..i..',gm].CleanName}', '')
        if gm ~= '' then s.gms[#s.gms+1] = gm end
    end
    for i=1,7 do
        local prefix = '${NearestSpawn['..i..',Named]'
        local id = number(prefix..'.ID}')
        if id > 0 then
            s.named[#s.named+1] = get(prefix..'.CleanName}') .. ' | L' .. get(prefix..'.Level}') .. ' | ID ' .. id
        end
    end
    local canCast = get('${Me.Class.CanCast}', 'FALSE')
    s.canCast = canCast == 'TRUE' or canCast == '1'
    for i=1,9 do
        local prefix = '${Me.Gem['..i..']'
        local name = get(prefix..'.Name}', '')
        local range = number(prefix..'.MyRange}')
        s.spells[#s.spells+1] = {slot=i, name=name, range=range}
    end
    if s.targetID > 0 then
        s.target = get('${Target.CleanName}')
        s.class = get('${Target.Class.ShortName}')
        s.level = get('${Target.Level}')
        s.guild = get('${Target.Guild}', '')
        s.race, s.type = get('${Target.Race}'), get('${Target.Type}')
        s.con = get('${Target.ConColor}', 'WHITE'):upper()
        s.hp, s.targetState = get('${Target.PctHPs}'), get('${Target.State}')
        s.distance = number('${Target.Distance}')
        s.distance3D = get('${Target.Distance3D}')
        s.los = get('${LineOfSight[${Me.Y},${Me.X},${Me.Z}:${Target.Y},${Target.X},${Target.Z}]}')
        s.direction = get('${Target.HeadingTo}')
        s.maxRange = get('${Target.MaxRangeTo}')
        s.targetLocation = get('Y: ${Target.Y}  X: ${Target.X}  Z: ${Target.Z}')
        s.status = {}
        for _, field in ipairs({'Tashed','Slowed','Crippled','Rooted','Snared'}) do
            local value = get('${Bool[${Target.'..field..'}]}', 'FALSE')
            s.status[field] = value == 'TRUE' or value == '1'
        end
        s.totID = number('${Me.TargetOfTarget.ID}')
        if s.totID > 0 then
            s.tot = get('${Me.TargetOfTarget.CleanName}') .. ' | ' .. get('${Me.TargetOfTarget.Class.ShortName}') ..
                ' L' .. get('${Me.TargetOfTarget.Level}') .. ' | ID ' .. s.totID
            s.totCon = get('${Me.TargetOfTarget.ConColor}', 'WHITE'):upper()
        end
    end
    return s
end
function HUD.defaults()
    return { open=true, running=true, locked=false, showNamed=true, showSpells=true, alpha=0.9,
        cache={}, lastPoll=0, dirty=false }
end
function HUD.draw(gui, state)
    if not state.open then return end
    local s = state.cache
    local function text(value) gui.TextUnformatted(tostring(value or 'N/A')) end
    local function color(value, c) gui.TextColored(c[1],c[2],c[3],c[4], '%s', tostring(value)) end
    local function heading(value) gui.Separator(); color(value,{0.95,0.7,0.35,1}) end
    gui.SetNextWindowSize(720,650,ImGuiCond.FirstUseEver)
    gui.SetNextWindowBgAlpha(state.alpha)
    local flags = state.locked and bit.bor(ImGuiWindowFlags.NoMove,ImGuiWindowFlags.NoResize) or 0
    local open, show = gui.Begin('Zenith Main HUD###NeroMorteZenithMainHUD',state.open,flags)
    if not open then state.open=false;state.dirty=true end
    if show then
        local value, changed=gui.Checkbox('Lock##zenHUDLock',state.locked)
        if changed then state.locked=value;state.dirty=true end
        gui.SameLine(); value,changed=gui.Checkbox('Named NPCs##zenHUDNamed',state.showNamed)
        if changed then state.showNamed=value;state.dirty=true end
        gui.SameLine(); value,changed=gui.Checkbox('Spell Ranges##zenHUDSpells',state.showSpells)
        if changed then state.showSpells=value;state.dirty=true end
        text((s.name or 'Waiting for character') .. ' | Macro: ' .. (s.macro or 'N/A') .. ' | Idle: ' .. (s.idle or 'N/A'))
        text('XP: '..(s.xp or 'N/A')..'% | Raw '..(s.rawXP or 'N/A')..'/330    AA XP: '..(s.aa or 'N/A')..'% | Raw '..(s.rawAA or 'N/A')..'/330')
        text(string.format('Zone: Players %d | NPCs %d | Named %d | Nearby NPCs (150, LOS) %d',s.players or 0,s.npcs or 0,s.namedCount or 0,s.nearNPCs or 0))
        if s.gms and #s.gms > 0 then color('GM: '..table.concat(s.gms,' | '),{1,0.3,0.3,1}) end
        heading('Current Target')
        if (s.targetID or 0) > 0 then
            color((s.target or '?')..' | '..(s.class or '?')..' L'..(s.level or '?')..' | '..(s.type or '?')..' / '..(s.race or '?'),HUD.colors[s.con] or HUD.colors.WHITE)
            if s.guild and s.guild~='' then text('Guild: '..s.guild) end
            text('HP: '..(s.targetState=='DEAD' and 'DEAD' or (s.hp or '?')..'%')..' | ID '..s.targetID..' | Combat ID '..(s.combatID or 'N/A'))
            color('Target of Target: '..(s.tot or 'None'),HUD.colors[s.totCon] or HUD.colors.YELLOW)
            if gui.BeginTable('ZenithHudTargetEffects',5,ImGuiTableFlags.Borders) then
                for _,effect in ipairs({'Tashed','Slowed','Crippled','Rooted','Snared'}) do
                    gui.TableNextColumn()
                    local on=s.status and s.status[effect]
                    color(effect..': '..(on and 'YES' or 'NO'),on and {0.2,1,0.3,1} or {1,0.3,0.3,1})
                end
                gui.EndTable()
            end
            text('LOS: '..(s.los or '?')..' | XY: '..string.format('%.1f',s.distance or 0)..' | XYZ: '..(s.distance3D or '?')..' | Direction: '..(s.direction or '?'))
            text('MaxRangeTo: '..(s.maxRange or '?'))
            text('Target location: '..(s.targetLocation or '?'))
        else text('No target selected') end
        text('My location: '..(s.location or '?')..' | Heading: '..(s.heading or '?'))
        if state.showNamed then
            heading('Named NPCs (up to 7)')
            if not s.named or #s.named==0 then text('None found')
            else for i,line in ipairs(s.named) do text(i..'. '..line) end end
        end
        if state.showSpells then
            heading('Spell Gem Ranges (1-9)')
            if s.canCast==false then text('Class reports no spell casting') end
            if gui.BeginTable('ZenithHudSpellRanges',4,ImGuiTableFlags.Borders) then
                for _,column in ipairs({'Gem','Spell','MyRange','Target range'}) do gui.TableSetupColumn(column) end
                gui.TableHeadersRow()
                for _,spell in ipairs(s.spells or {}) do
                    gui.TableNextRow();gui.TableNextColumn();text(spell.slot)
                    gui.TableNextColumn();text(spell.name~='' and spell.name or '(empty)')
                    gui.TableNextColumn();text(spell.range>0 and spell.range or '-')
                    gui.TableNextColumn()
                    if s.targetID and s.targetID>0 and spell.range>0 then
                        local inRange=(s.distance or math.huge)<=spell.range
                        color(inRange and 'IN RANGE' or 'OUT OF RANGE',inRange and {0.2,1,0.3,1} or {1,0.3,0.3,1})
                    else text('-') end
                end
                gui.EndTable()
            end
        end
    end
    gui.End()
end
function HUD.run()
    local mq = require('mq')
    local gui = require('ImGui')
    local state = HUD.defaults()
    local ini = 'Zenith_ImGuiHUD.ini'
    local function setting(k, fallback)
        local ok,v=pcall(function() return mq.TLO.Ini(ini,'Main',k,tostring(fallback))() end)
        return ok and v or tostring(fallback)
    end
    state.locked=setting('Locked',0)=='1'
    state.showNamed=setting('ShowNamed',1)~='0';state.showSpells=setting('ShowSpells',1)~='0'
    mq.bind('/zenithhud',function(argument)
        if argument=='quit' then state.running=false
        else state.open=not state.open end
    end)
    mq.imgui.init('NeroMorteZenithMainHUD',function() HUD.draw(gui,state) end)
    print('[Zenith HUD] ImGui [Main] HUD loaded. /zenithhud toggles; /zenithhud quit stops.')
    while state.running do
        if mq.TLO.MacroQuest.GameState()=='INGAME' then
            state.cache=HUD.capture(mq)
        else state.cache={} end
        if state.dirty then
            mq.cmdf('/ini %s Main Locked %d',ini,state.locked and 1 or 0)
            mq.cmdf('/ini %s Main ShowNamed %d',ini,state.showNamed and 1 or 0)
            mq.cmdf('/ini %s Main ShowSpells %d',ini,state.showSpells and 1 or 0)
            state.dirty=false
        end
        mq.delay(500)
    end
    mq.imgui.destroy('NeroMorteZenithMainHUD')
    mq.unbind('/zenithhud')
end
if ... == 'test' then return HUD end
HUD.run()
