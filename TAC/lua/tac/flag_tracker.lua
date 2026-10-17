-- Created By: NeroMorte - Observe local progression messages and share a bot roster.
-- Standalone plugin: history is data-only TSV, never executable Lua.
local plugin = {
    id = 'flag_tracker', name = 'Flag Tracker', author = 'NeroMorte', version = '1.0.0',
    description = 'Shared latest flag, keyring, quest and hail messages for every bot.',
    defaultEnabled = true, tickInterval = 0.5, runOutOfCombatOnly = false,
    uses = { boxnet = 'Share observed progression events and replay each bot history' },
    window = { label = 'Flag Tracker', flag = 'show_flag_tracker', desc = 'All bots progression messages',
        tooltip = 'Latest flag/key/quest message per bot and saved history.', headerButton = true, order = 116 },
}
local core, mq, ctrl, imgui
local state = { bots = {}, seen = {}, outbound = {}, unsub = {}, dirty = false,
    lastSave = 0, lastSync = -100, counter = 0, selected = nil, search = '', category = 'All',
    customText = '', customKind = 'Flag', error = nil, pendingSync = false, requests = {} }
local MAX_BOTS, MAX_EVENTS, MAX_TEXT = 64, 100, 512
local categories = { 'All', 'Flag', 'Key', 'Quest', 'Hail', 'Dialogue' }
local function read(fn, fallback)
    local ok, value = pcall(fn)
    if ok and value ~= nil then return value end
    return fallback
end
local function clean(value, limit)
    if type(value) ~= 'string' then return nil end
    value = value:gsub('\a[%w%-]', ''):gsub('[%z\1-\8\11\12\14-\31]', '')
    return value:sub(1, limit or MAX_TEXT)
end
local function config()
    ctrl.flag_tracker = type(ctrl.flag_tracker) == 'table' and ctrl.flag_tracker or {}
    local c = ctrl.flag_tracker
    if c.listen == nil then c.listen = true end
    if c.dialogue == nil then c.dialogue = true end
    if c.notify == nil then c.notify = true end
    if type(c.rules) ~= 'table' then c.rules = {} end
    return c
end
local function identity()
    return clean(read(function() return mq.TLO.Me.CleanName() end, ''), 64) or '',
        clean(read(function() return mq.TLO.EverQuest.Server() end, ''), 64) or ''
end
local function timestamp() return os.time() end
local function key(name) return name:lower() end
local function bot(name)
    if type(name) ~= 'string' or name == '' or #name > 64 then return nil end
    local b = state.bots[key(name)]
    if b then return b end
    local n = 0; for _ in pairs(state.bots) do n = n + 1 end
    if n >= MAX_BOTS then return nil end
    b = { name = name, events = {} }; state.bots[key(name)] = b
    return b
end
local function validEvent(e)
    if type(e) ~= 'table' or type(e.id) ~= 'string' or #e.id < 1 or #e.id > 128 or
        not e.id:match('^[%w_%-]+$') or type(e.at) ~= 'number' or e.at ~= math.floor(e.at) or
        e.at < 0 or e.at > 4102444800 then return false end
    local validKind = false
    for _, k in ipairs(categories) do if k ~= 'All' and k == e.kind then validKind = true end end
    return validKind and type(e.text) == 'string' and #e.text > 0 and #e.text <= MAX_TEXT and
        type(e.zone) == 'string' and #e.zone <= 64 and type(e.npc) == 'string' and #e.npc <= 80
end
local function add(name, e)
    if type(name) ~= 'string' or name == '' or #name > 64 or not validEvent(e) then return false end
    local b = bot(name); if not b then return false end
    local id = key(name) .. ':' .. e.id
    if state.seen[id] then return false end
    local event = { id = e.id, at = e.at, kind = e.kind, text = clean(e.text),
        zone = clean(e.zone, 64), npc = clean(e.npc, 80) }
    state.seen[id] = true; b.events[#b.events + 1] = event
    table.sort(b.events, function(a, c) if a.at == c.at then return a.id > c.id end return a.at > c.at end)
    while #b.events > MAX_EVENTS do
        -- Keep the latest observation of each type even during a long NPC conversation.
        local latest = {}; for i, item in ipairs(b.events) do if not latest[item.kind] then latest[item.kind] = i end end
        local remove = #b.events
        while remove > 1 and latest[b.events[remove].kind] == remove do remove = remove - 1 end
        local old = table.remove(b.events, remove); state.seen[key(name) .. ':' .. old.id] = nil
    end
    state.dirty = true
    return true
end
local function classify(line, npcReply)
    local c = config()
    if type(line) ~= 'string' or #line > 4096 then return nil end
    local l = line:lower()
    -- Do not turn player tells, group chat, quotes or our own notifications into flags.
    if l:find('[flag tracker]', 1, true) or l:find(' tells ', 1, true) or
        l:find('tells you,', 1, true) or l:find(' tells the ', 1, true) then return nil end
    if l:match("^you say, ['\"]hail[,! ]") then return 'Hail' end
    if l:find(" says,", 1, true) or l:find(" says '", 1, true) then
        return c.dialogue and npcReply and 'Dialogue' or nil
    end
    if l:match('^you say') or l:match('^you tell') then return nil end
    if (l:find('key ring', 1, true) or l:find('keyring', 1, true)) and
        (l:find('added', 1, true) or l:find('add ', 1, true)) then return 'Key' end
    if l:match('^you ') and l:find('flag', 1, true) and
        (l:find('received', 1, true) or l:find('gained', 1, true) or l:find('been flagged', 1, true) or
         l:find('completed a part', 1, true) or l:find('unlocked', 1, true)) then return 'Flag' end
    if l:find('you have received a character flag', 1, true) or
        l:find('you have received a flag', 1, true) or l:find('you have been flagged', 1, true) or
        l:find('you have gained a character flag', 1, true) or
        l:find('you have already received this flag', 1, true) then return 'Flag' end
    if l:find('your task ', 1, true) and (l:find('updated', 1, true) or l:find('completed', 1, true)) or
        l:find('you have been assigned the task', 1, true) or
        l:find('you have completed the task', 1, true) or l:find('you have completed a task', 1, true) or
        l:find('you have completed the quest', 1, true) or l:find('you have received a quest', 1, true) then return 'Quest' end
    -- Custom server phrases are literal substrings, never Lua patterns or code.
    for i, rule in ipairs(c.rules) do
        if i > 20 then break end
        if type(rule) == 'table' and type(rule.text) == 'string' and #rule.text >= 4 and
            #rule.text <= 120 and l:find(rule.text:lower(), 1, true) then
            for _, k in ipairs(categories) do if k ~= 'All' and rule.kind == k then return k end end
        end
    end
end
local function npcContext()
    return read(function()
        local t = mq.TLO.Target
        return t.Type() == 'NPC' and t.CleanName() or ''
    end, '')
end
local function observe(line)
    if not config().listen then return end
    -- Reject ordinary combat/chat without any native TLO reads; only candidate events need context.
    local kind = classify(line, false)
    local npc = ''
    if not kind then
        if not config().dialogue or type(line) ~= 'string' or not line:find(' says,', 1, true) then return end
        npc = clean(npcContext(), 80) or ''
        local speaker = line:match('^(.-) says,')
        kind = classify(line, speaker and npc ~= '' and speaker:lower() == npc:lower())
    end
    if not kind then return end
    local name, server = identity()
    if name == '' or server == '' then return end
    if npc == '' then npc = clean(npcContext(), 80) or '' end
    local text = clean(line)
    local signature = kind .. ':' .. text
    local now = timestamp()
    if state.lastLine == signature and now - (state.lastLineAt or 0) < 2 then return end
    state.lastLine, state.lastLineAt = signature, now
    if kind == 'Flag' or kind == 'Key' or kind == 'Quest' then state.webRefreshDue = now + 15 end
    state.counter = state.counter + 1
    local e = { id = state.session .. '_' .. string.format('%08d', state.counter), at = now, kind = kind, text = text,
        zone = clean(read(function() return mq.TLO.Zone.ShortName() end, ''), 64), npc = npc }
    if add(name, e) then
        if #state.outbound < 120 then state.outbound[#state.outbound + 1] = { name = name, server = server, events = { e } } end
        if config().notify and (kind == 'Flag' or kind == 'Key') then
            print('[Flag Tracker] ' .. name .. ' | ' .. kind .. ': ' .. text)
        end
    end
end
local function escape(s) return (s:gsub('%%', '%%25'):gsub('\t', '%%09'):gsub('\r', '%%0D'):gsub('\n', '%%0A')) end
local function unescape(s) return (s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)) end
local function dataPath()
    local function safe(s) return (s:gsub('[^%w_%-]', function(c) return string.format('_%02x', c:byte()) end)) end
    local name, server = identity()
    if not name or name == '' or not server or server == '' then return nil end
    return (mq.configDir or 'config') .. '/triune_flag_tracker_' .. safe(server) .. '_' .. safe(name) .. '.tsv'
end
local function loadHistory()
    local path = dataPath(); if not path then return end
    state.path = path
    local f = io.open(path, 'rb') or io.open(path .. '.bak', 'rb')
    if not f then return end
    local header = f:read('*l')
    if header ~= 'TriuneFlagTracker\t1' then f:close(); state.error = 'Unrecognized history file; not loaded.'; return end
    local count = 0
    for line in f:lines() do
        count = count + 1; if count > MAX_BOTS * (MAX_EVENTS + 160) then break end
        if #line <= 4096 then
            local parts = {}; for part in (line .. '\t'):gmatch('(.-)\t') do parts[#parts + 1] = unescape(part) end
            if parts[1] == '@web' and #parts == 9 then
                local name, id, at = parts[2], parts[3], tonumber(parts[4])
                if plugin.websiteID(id) and at and at >= 0 and at <= 4102444800 and #parts[5] <= 400 then
                    local b = bot(name)
                    if b then
                        b.website = b.website or { id = id, at = at, summary = parts[5], accountWide = parts[6] == '1', rows = {} }
                        if #b.website.rows < 160 and #parts[7] <= 160 and #parts[9] <= 512 and (parts[8] == '1' or parts[8] == '0') then
                            b.website.rows[#b.website.rows + 1] = { name = parts[7], done = parts[8] == '1', detail = parts[9] }
                        end
                    end
                end
            elseif #parts == 7 or #parts == 8 then add(parts[1], { id = parts[2], at = tonumber(parts[3]), kind = parts[4],
                zone = parts[5], npc = parts[6], text = parts[7] }) end
        end
    end
    f:close(); state.dirty = false
end
local function saveHistory()
    local path = state.path or dataPath(); if not path or state.error == 'Unrecognized history file; not loaded.' then return false end
    local f = io.open(path .. '.tmp', 'wb')
    if not f then state.error = 'Cannot write tracker history: ' .. path; return false end
    local ok, err = pcall(function()
        assert(f:write('TriuneFlagTracker\t1\n'))
        for _, b in pairs(state.bots) do
            if b.website then
                local w = b.website
                for _, row in ipairs(w.rows) do
                    local parts = { '@web', b.name, w.id, tostring(w.at), w.summary, w.accountWide and '1' or '0',
                        row.name, row.done and '1' or '0', row.detail }
                    for i, v in ipairs(parts) do parts[i] = escape(v) end
                    assert(f:write(table.concat(parts, '\t'), '\n'))
                end
            end
            for _, e in ipairs(b.events) do
                local parts = { b.name, e.id, tostring(e.at), e.kind, e.zone, e.npc, e.text }
                for i, v in ipairs(parts) do parts[i] = escape(v) end
                assert(f:write(table.concat(parts, '\t'), '\n'))
            end
        end
        assert(f:flush())
    end)
    local closed = f:close()
    if not ok or not closed then state.error = 'History write failed: ' .. tostring(err); return false end
    -- Windows rename cannot replace an existing file; retain one previous snapshot.
    local old = io.open(path, 'rb')
    if old then
        old:close(); os.remove(path .. '.bak')
        if not os.rename(path, path .. '.bak') then state.error = 'Could not back up tracker history.'; return false end
    end
    if not os.rename(path .. '.tmp', path) then
        if old then os.rename(path .. '.bak', path) end
        state.error = 'Could not commit tracker history; previous snapshot retained.'; return false
    end
    state.error, state.dirty = nil, false
    return true
end
local function receive(data, sender)
    local _, server = identity()
    if type(data) ~= 'table' or data.server ~= server or type(sender) ~= 'table' or
        type(sender.character) ~= 'string' or key(sender.character) ~= key(tostring(data.name or '')) or
        (sender.server and sender.server ~= '' and sender.server ~= server) or type(data.events) ~= 'table' then return end
    local b = bot(sender.character); if b then b.trackerSeenAt = timestamp() end
    for i, e in ipairs(data.events) do
        if i > 5 then break end
        if add(sender.character, e) and config().notify and key(sender.character) ~= key(identity()) and
            e.at >= timestamp() - 10 and (e.kind == 'Flag' or e.kind == 'Key') then
            print('[Flag Tracker] ' .. sender.character .. ' | ' .. e.kind .. ': ' .. clean(e.text))
        end
    end
end
local function queueHistory(data, sender)
    local name, server = identity()
    if type(data) ~= 'table' or data.server ~= server or type(sender) ~= 'table' or
        type(sender.character) ~= 'string' or sender.character == '' or key(sender.character) == key(name) or
        (sender.server and sender.server ~= '' and sender.server ~= server) then return end
    local now = timestamp(); local who = key(sender.character)
    if now - (state.requests[who] or 0) < 30 then return end
    local count = 0; for _ in pairs(state.requests) do count = count + 1 end
    if not state.requests[who] and count >= MAX_BOTS then return end
    state.requests[who] = now
    local b = bot(name); if not b then return end
    if #b.events == 0 and #state.outbound < 120 then state.outbound[#state.outbound + 1] = { to = sender.character, name = name, server = server, events = {} } end
    for offset = 1, #b.events, 5 do
        if #state.outbound >= 120 then break end
        local batch = {}; for i = offset, math.min(offset + 4, #b.events) do batch[#batch + 1] = b.events[i] end
        state.outbound[#state.outbound + 1] = { to = sender.character, name = name, server = server, events = batch }
    end
    return true
end
local function attach()
    local network = core.boxnet
    if network == state.network then return end
    for _, unsub in ipairs(state.unsub) do pcall(unsub) end
    state.unsub, state.network, state.lastSync = {}, network, -100
    if network and network.subscribe then
        state.unsub[1] = network.subscribe('flags:events', receive)
        state.unsub[2] = network.subscribe('flags:request', function(data, sender)
            if queueHistory(data, sender) then plugin.queueWebsite(sender.character) end
        end)
        state.unsub[3] = network.subscribe('flags:web', function(data, sender) plugin.receiveWebsite(data, sender) end)
        state.unsub[4] = network.subscribe('flags:lookup', function(data, sender) plugin.requestWebsite(data, sender) end)
        state.unsub[6] = network.subscribe('flags:status', function(data, sender)
            if type(data) == 'table' and data.server == select(2, identity()) and type(sender) == 'table' and
                type(sender.character) == 'string' and type(data.text) == 'string' and #data.text <= 250 then
                local b = bot(sender.character); if b then b.webStatus = clean(data.text, 250) end
            end
        end)
        state.unsub[5] = network.subscribe('flags:refresh', function(data)
            if type(data) == 'table' and data.server == select(2, identity()) and
                timestamp() - (state.lastWebFetch or 0) >= 60 then state.webPending = config().websiteID end
        end)
    end
end
local function roster()
    local rows, present = {}, {}
    local name = identity()
    local b = bot(name); if b then present[key(name)] = true; rows[#rows + 1] = b end
    local network = core.boxnet
    for _, peer in ipairs(network and network.peers and network.peers() or {}) do
        if type(peer.name) == 'string' and peer.name ~= '' and (not peer.server or peer.server == '' or peer.server == select(2, identity())) then
            local row = bot(peer.name)
            if row and not present[key(peer.name)] then present[key(peer.name)] = true; rows[#rows + 1] = row end
        end
    end
    for k, row in pairs(state.bots) do if not present[k] then rows[#rows + 1] = row end end
    table.sort(rows, function(a, c) return a.name:lower() < c.name:lower() end)
    return rows
end
-- Created By: NeroMorte - Same non-blocking WinHTTP COM pattern as Update Checker.
-- Intentionally duplicated so this plugin remains independently loadable.
local USER_AGENT, REQUEST_TIMEOUT_S = 'TriuneAutoCombat-FlagTracker', 20
local function nowMs() return read(function() return mq.gettime() end, os.clock() * 1000) end
local http = {
    ffi      = nil,
    ole32    = nil,
    oleaut32 = nil,
    kernel32 = nil,
    iid      = nil,
    ready    = false,
    err      = nil,
    -- live request
    req      = nil,      -- IWinHttpRequest*
    bstrs    = nil,      -- BSTRs allocated for the live request
    t0       = 0,
    deadline = 0,
    polls    = 0,
    headers  = false,
    code     = nil,
}

local CDEF = [[
typedef long            HRESULT;
typedef long            LONG;
typedef unsigned long   ULONG;
typedef unsigned long   DWORD;
typedef unsigned short  WORD;
typedef unsigned int    UINT;
typedef unsigned short  VARTYPE;
typedef short           VARIANT_BOOL;
typedef wchar_t*        BSTR;
typedef DWORD           LCID;
typedef long            DISPID;

typedef struct { DWORD Data1; WORD Data2; WORD Data3; unsigned char Data4[8]; } GUID;

typedef struct {
    VARTYPE vt;
    WORD    wReserved1, wReserved2, wReserved3;
    union {
        LONG          lVal;
        DWORD         ulVal;
        VARIANT_BOOL  boolVal;
        BSTR          bstrVal;
        void*         byref;
        double        dblVal;
        long long     llVal;
    };
} VARIANT;

typedef struct IWinHttpRequest IWinHttpRequest;
typedef struct {
    HRESULT (__stdcall *QueryInterface)(IWinHttpRequest*, const GUID*, void**);
    ULONG   (__stdcall *AddRef)(IWinHttpRequest*);
    ULONG   (__stdcall *Release)(IWinHttpRequest*);
    HRESULT (__stdcall *GetTypeInfoCount)(IWinHttpRequest*, UINT*);
    HRESULT (__stdcall *GetTypeInfo)(IWinHttpRequest*, UINT, LCID, void**);
    HRESULT (__stdcall *GetIDsOfNames)(IWinHttpRequest*, const GUID*, wchar_t**, UINT, LCID, DISPID*);
    HRESULT (__stdcall *Invoke)(IWinHttpRequest*, DISPID, const GUID*, LCID, WORD, void*, VARIANT*, void*, UINT*);
    HRESULT (__stdcall *SetProxy)(IWinHttpRequest*, DWORD, VARIANT, VARIANT);
    HRESULT (__stdcall *SetCredentials)(IWinHttpRequest*, BSTR, BSTR, DWORD);
    HRESULT (__stdcall *Open)(IWinHttpRequest*, BSTR, BSTR, VARIANT);
    HRESULT (__stdcall *SetRequestHeader)(IWinHttpRequest*, BSTR, BSTR);
    HRESULT (__stdcall *GetResponseHeader)(IWinHttpRequest*, BSTR, BSTR*);
    HRESULT (__stdcall *GetAllResponseHeaders)(IWinHttpRequest*, BSTR*);
    HRESULT (__stdcall *Send)(IWinHttpRequest*, VARIANT);
    HRESULT (__stdcall *get_Status)(IWinHttpRequest*, LONG*);
    HRESULT (__stdcall *get_StatusText)(IWinHttpRequest*, BSTR*);
    HRESULT (__stdcall *get_ResponseText)(IWinHttpRequest*, BSTR*);
    HRESULT (__stdcall *get_ResponseBody)(IWinHttpRequest*, VARIANT*);
    HRESULT (__stdcall *get_ResponseStream)(IWinHttpRequest*, VARIANT*);
    HRESULT (__stdcall *get_Option)(IWinHttpRequest*, DWORD, VARIANT*);
    HRESULT (__stdcall *put_Option)(IWinHttpRequest*, DWORD, VARIANT);
    HRESULT (__stdcall *WaitForResponse)(IWinHttpRequest*, VARIANT, VARIANT_BOOL*);
    HRESULT (__stdcall *Abort)(IWinHttpRequest*);
    HRESULT (__stdcall *SetTimeouts)(IWinHttpRequest*, LONG, LONG, LONG, LONG);
    HRESULT (__stdcall *SetClientCertificate)(IWinHttpRequest*, BSTR);
    HRESULT (__stdcall *SetAutoLogonPolicy)(IWinHttpRequest*, DWORD);
} IWinHttpRequestVtbl;
struct IWinHttpRequest { const IWinHttpRequestVtbl* lpVtbl; };

HRESULT __stdcall CoInitializeEx(void* reserved, DWORD coinit);
HRESULT __stdcall CLSIDFromProgID(const wchar_t* progId, GUID* clsid);
HRESULT __stdcall CoCreateInstance(const GUID* clsid, void* outer, DWORD ctx, const GUID* iid, void** out);
BSTR    __stdcall SysAllocString(const wchar_t* s);
void    __stdcall SysFreeString(BSTR s);
UINT    __stdcall SysStringLen(BSTR s);
int     __stdcall WideCharToMultiByte(UINT cp, DWORD flags, const wchar_t* src, int srcLen,
                                      char* dst, int dstLen, const char* defChar, int* usedDef);
]]

local VT_EMPTY, VT_I4, VT_BOOL          = 0, 3, 11
local CLSCTX_INPROC_SERVER              = 0x1
local COINIT_APARTMENTTHREADED          = 0x2
local CP_UTF8                           = 65001
local S_OK, S_FALSE                     = 0, 1
local RPC_E_CHANGED_MODE                = -2147417850  -- 0x80010106
local WinHttpRequestOption_SecureProtocols = 9
local SECURE_TLS12_13                   = 0x0800 + 0x2000

local function hex(hr) return string.format('0x%08X', (tonumber(hr) or 0) % 4294967296) end
local function failed(hr) return (tonumber(hr) or -1) < 0 end

-- One-time ffi setup. Returns true, or false + reason. The cdef is guarded so
-- a plugin reload in the same Lua state does not trip "attempt to redefine".
local function httpSetup()
    if http.ready then return true end
    if http.err then return false, http.err end
    local ok, res = pcall(function()
        local okFfi, ffi = pcall(require, 'ffi')
        if not okFfi then error('LuaJIT ffi is not available in this MacroQuest build') end
        if ffi.os ~= 'Windows' then error('needs the Windows COM runtime (ffi.os = ' .. tostring(ffi.os) .. ')') end
        if not pcall(ffi.typeof, 'IWinHttpRequest') then ffi.cdef(CDEF) end
        if ffi.sizeof('VARIANT') ~= 16 or ffi.sizeof('GUID') ~= 16 then error('unexpected VARIANT/GUID layout') end
        http.ffi      = ffi
        http.ole32    = ffi.load('ole32')
        http.oleaut32 = ffi.load('oleaut32')
        http.kernel32 = ffi.load('kernel32')
        http.iid      = ffi.new('GUID', 0x016fe2ec, 0xb2c8, 0x45f8,
            { 0xb2, 0x3b, 0x39, 0xe5, 0x3a, 0x75, 0x39, 0x6b })   -- IID_IWinHttpRequest
        -- S_OK / S_FALSE / RPC_E_CHANGED_MODE all mean COM is usable on this thread.
        local hr = tonumber(http.ole32.CoInitializeEx(nil, COINIT_APARTMENTTHREADED))
        if hr ~= S_OK and hr ~= S_FALSE and hr ~= RPC_E_CHANGED_MODE then
            error('CoInitializeEx returned ' .. hex(hr))
        end
    end)
    if not ok then
        http.err = tostring(res):gsub('^.-:%d+: ', '')
        return false, http.err
    end
    http.ready = true
    return true
end

local function wide(s)
    local buf = http.ffi.new('wchar_t[?]', #s + 1)
    for i = 1, #s do buf[i - 1] = s:byte(i) end
    buf[#s] = 0
    return buf
end

local function bstr(s)
    local b = http.oleaut32.SysAllocString(wide(s))
    if b == nil then error('SysAllocString failed') end
    http.bstrs[#http.bstrs + 1] = b
    return b
end

local function bstrToLua(b)
    if b == nil then return nil end
    local wlen = http.oleaut32.SysStringLen(b)
    if wlen == 0 then return '' end
    local n = http.kernel32.WideCharToMultiByte(CP_UTF8, 0, b, wlen, nil, 0, nil, nil)
    if n <= 0 then return nil end
    local buf = http.ffi.new('char[?]', n)
    http.kernel32.WideCharToMultiByte(CP_UTF8, 0, b, wlen, buf, n, nil, nil)
    return http.ffi.string(buf, n)
end

local function variant(vt, field, val)
    local v = http.ffi.new('VARIANT')
    v.vt = vt
    if field then v[field] = val end
    return v
end

-- Drop the live request: Abort if still in flight, Release, free BSTRs.
local function httpClose(abort)
    if http.req ~= nil then
        local req = http.req
        http.req = nil
        pcall(function()
            if abort then req.lpVtbl.Abort(req) end
            req.lpVtbl.Release(req)
        end)
    end
    if http.bstrs then
        for _, b in ipairs(http.bstrs) do pcall(http.oleaut32.SysFreeString, b) end
    end
    http.bstrs = nil
end

-- Start an async GET. Returns true, or false + reason. Never waits.
local function httpBegin(url)
    local ok, why = httpSetup()
    if not ok then return false, why end
    httpClose(true)
    http.bstrs = {}
    local okRun, res = pcall(function()
        local ffi = http.ffi
        local clsid = ffi.new('GUID')
        local hr = http.ole32.CLSIDFromProgID(wide('WinHttp.WinHttpRequest.5.1'), clsid)
        if failed(hr) then error('WinHttp.WinHttpRequest.5.1 is not registered (' .. hex(hr) .. ')') end
        local out = ffi.new('void*[1]')
        hr = http.ole32.CoCreateInstance(clsid, nil, CLSCTX_INPROC_SERVER, http.iid, out)
        if failed(hr) or out[0] == nil then error('CoCreateInstance failed (' .. hex(hr) .. ')') end
        http.req = ffi.cast('IWinHttpRequest*', out[0])
        local req, vt = http.req, http.req.lpVtbl
        -- resolve / connect / send / receive (ms): bounds the worker, not us
        hr = vt.SetTimeouts(req, 5000, 5000, 5000, 10000)
        if failed(hr) then error('SetTimeouts failed (' .. hex(hr) .. ')') end
        hr = vt.Open(req, bstr('GET'), bstr(url), variant(VT_BOOL, 'boolVal', -1))
        if failed(hr) then error('Open failed (' .. hex(hr) .. ')') end
        -- GitHub's API refuses requests without a User-Agent.
        hr = vt.SetRequestHeader(req, bstr('User-Agent'), bstr(USER_AGENT))
        if failed(hr) then error('SetRequestHeader failed (' .. hex(hr) .. ')') end
        vt.SetRequestHeader(req, bstr('Accept'), bstr('text/html'))
        -- TLS 1.2/1.3 explicitly (older Windows defaults exclude 1.2; GitHub
        -- requires it). Wine does not implement the option: ignore the result.
        vt.put_Option(req, WinHttpRequestOption_SecureProtocols, variant(VT_I4, 'lVal', SECURE_TLS12_13))
        hr = vt.Send(req, variant(VT_EMPTY))
        if failed(hr) then error('Send failed (' .. hex(hr) .. ')') end
    end)
    if not okRun then
        httpClose(true)
        return false, tostring(res):gsub('^.-:%d+: ', '')
    end
    http.t0       = nowMs()
    http.deadline = http.t0 + REQUEST_TIMEOUT_S * 1000
    http.polls    = 0
    http.headers  = false
    http.code     = nil
    return true
end

-- One non-blocking poll. Returns 'pending' | 'done', code, body | 'error', reason.
local function httpPoll()
    if http.req == nil then return 'error', 'no request in flight' end
    local ffi = http.ffi
    local req, vt = http.req, http.req.lpVtbl
    http.polls = http.polls + 1
    local status, body = nil, nil
    local okRun, res = pcall(function()
        if not http.headers then
            local s = ffi.new('LONG[1]')
            if not failed(vt.get_Status(req, s)) then
                http.headers = true
                http.code = tonumber(s[0])
            end
        end
        if http.headers then
            local succeeded = ffi.new('VARIANT_BOOL[1]')
            succeeded[0] = -1
            local hr = vt.WaitForResponse(req, variant(VT_I4, 'lVal', 0), succeeded)
            if not failed(hr) and succeeded[0] ~= 0 then
                local pb = ffi.new('BSTR[1]')
                hr = vt.get_ResponseText(req, pb)
                if failed(hr) then error('ResponseText failed (' .. hex(hr) .. ')') end
                body = bstrToLua(pb[0]) or ''
                http.oleaut32.SysFreeString(pb[0])
                status = 'done'
            end
        end
    end)
    if not okRun then
        httpClose(true)
        return 'error', tostring(res):gsub('^.-:%d+: ', '')
    end
    if status == 'done' then
        local code = http.code
        httpClose(false)
        return 'done', code, body
    end
    if nowMs() >= http.deadline then
        local why = http.headers
            and string.format('HTTP %s headers arrived but the body never completed', tostring(http.code))
            or 'no response (offline, firewalled, or TLS could not be negotiated)'
        httpClose(true)
        return 'error', why
    end
    return 'pending'
end

local function htmlText(s)
    s = s:gsub('<[^>]*>', ''):gsub('&nbsp;', ' '):gsub('&amp;', '&'):gsub('&lt;', '<'):gsub('&gt;', '>')
    s = s:gsub('&quot;', '"'):gsub('&#39;', "'"):gsub('&#(%d+);', function(n)
        n = tonumber(n); return n and n >= 32 and n <= 126 and string.char(n) or ''
    end)
    return s:gsub('%s+', ' '):match('^%s*(.-)%s*$')
end
local function websiteID(value)
    if type(value) ~= 'string' then return nil end
    local id = value:match('^%s*(%d+)%s*$') or value:match('^https://nms%.bestemu%.com/character/(%d+)/progression/?$')
    return id and #id <= 12 and tonumber(id) > 0 and id or nil
end
local function parseWebsite(body, expected, id)
    if type(body) ~= 'string' or #body > 2 * 1024 * 1024 then return nil, 'Invalid or oversized website response.' end
    local name = body:match('<h1[^>]*>(.-)</h1>')
    if not name or htmlText(name):lower() ~= expected:lower() then return nil, 'Page character does not match ' .. expected .. '.' end
    local summary = {}
    for amount, label in body:gmatch('<div class="n">(.-)</div><div class="l">(.-)</div>') do
        if #summary < 4 then summary[#summary + 1] = htmlText(label) .. ': ' .. htmlText(amount) end
    end
    local rows = {}
    local pos = 1
    while #rows < 160 do
        local first, last, classes = body:find('<div class="(st[^"<>]*)">', pos)
        if not first then break end
        pos = last + 1
        if classes:match('^st[%s]') or classes == 'st' then
            local nextCard = body:find('<div class="st', pos, true) or #body
            local chunk = body:sub(pos, nextCard - 1)
            local title = chunk:match('<div class="nm">(.-)</div>')
            if title then
                local done = (' ' .. classes .. ' '):find(' on ', 1, true) ~= nil
                local nameOnly = title:gsub('<span class="stage">.-</span>', '')
                local section = ''
                for heading in body:sub(1, first):gmatch('<div class="tt">(.-)</div>') do section = htmlText(heading) end
                if section ~= '' then nameOnly = section .. ' / ' .. nameOnly end
                local detail = chunk:match('<div class="ds">(.-)</div>') or ''
                rows[#rows + 1] = { name = htmlText(nameOnly):sub(1, 160), done = done,
                    detail = htmlText(detail):sub(1, 512) }
            end
        end
    end
    if #summary == 0 or #rows == 0 then return nil, 'Progression layout not recognized; previous snapshot retained.' end
    return { id = id, at = timestamp(), summary = table.concat(summary, ' | '), rows = rows,
        accountWide = body:find('shared account%-wide') ~= nil }
end
local function validWebsite(w)
    if type(w) ~= 'table' or not websiteID(w.id) or type(w.at) ~= 'number' or w.at ~= math.floor(w.at) or w.at < 0 or
        w.at > 4102444800 or type(w.summary) ~= 'string' or #w.summary > 400 or
        type(w.rows) ~= 'table' or #w.rows > 160 then return false end
    for _, row in ipairs(w.rows) do
        if type(row) ~= 'table' or type(row.name) ~= 'string' or #row.name > 160 or
            type(row.done) ~= 'boolean' or type(row.detail) ~= 'string' or #row.detail > 512 then return false end
    end
    return true
end
local function receiveWebsite(data, sender)
    local _, server = identity()
    if type(data) ~= 'table' or data.server ~= server or type(sender) ~= 'table' or
        type(sender.character) ~= 'string' or key(sender.character) ~= key(tostring(data.name or '')) or
        (sender.server and sender.server ~= '' and sender.server ~= server) or
        not validWebsite(data.website) or #data.website.rows > 5 or type(data.part) ~= 'number' or
        type(data.parts) ~= 'number' or data.parts ~= math.floor(data.parts) or data.parts < 1 or data.parts > 32 or
        data.part < 1 or data.part > data.parts or data.part ~= math.floor(data.part) then return end
    local b = bot(sender.character); if not b then return end
    if b.website and b.website.at >= data.website.at then return end
    local pending = b.webParts
    if not pending or pending.at ~= data.website.at or pending.id ~= data.website.id then
        pending = { id = data.website.id, at = data.website.at, parts = data.parts, chunks = {} }; b.webParts = pending
    end
    if pending.parts ~= data.parts then return end
    pending.chunks[data.part] = data.website.rows
    local rows = {}
    for i = 1, pending.parts do
        if not pending.chunks[i] then return end
        for _, row in ipairs(pending.chunks[i]) do rows[#rows + 1] = row end
    end
    local w = data.website
    b.website = { id = w.id, at = w.at, summary = w.summary, accountWide = w.accountWide == true, rows = rows }
    b.webParts, state.dirty = nil, true
end
local function queueWebsite(to)
    local name, server = identity(); local b = state.bots[key(name)]
    local w = b and b.website; if not w then return end
    local parts = math.ceil(#w.rows / 5)
    for part = 1, parts do
        if #state.outbound >= 120 then break end
        local rows = {}; for i = (part - 1) * 5 + 1, math.min(part * 5, #w.rows) do rows[#rows + 1] = w.rows[i] end
        state.outbound[#state.outbound + 1] = { to = to, topic = 'flags:web', name = name, server = server,
            part = part, parts = parts, website = { id = w.id, at = w.at, summary = w.summary, accountWide = w.accountWide, rows = rows } }
    end
end
local function requestWebsite(data, sender)
    local _, server = identity()
    if type(data) ~= 'table' or data.server ~= server or type(sender) ~= 'table' or
        not websiteID(data.id) or timestamp() - (state.lastWebRequest or 0) < 60 then return end
    -- Read-only fixed-host request; a mismatched page is rejected before publication.
    if config().websiteID and config().websiteID ~= data.id then return end
    state.webPending = data.id; state.lastWebRequest = timestamp()
end
local function websiteTick()
    if state.webActive then
        local status, code, body = httpPoll()
        if status == 'pending' then return end
        local name = identity()
        if status == 'done' and code == 200 then
            local result, err = parseWebsite(body, name, state.webActive)
            if result then
                local b = bot(name); if b then b.website = result; state.dirty = true end
                config().websiteID = result.id; core.saveLoadout(true)
                state.webError = nil
                -- Split website details into bounded five-card network messages.
                state.webPublish = true
            else state.webError = err end
        else state.webError = status == 'error' and tostring(code) or ('Website returned HTTP ' .. tostring(code)) end
        state.webActive = nil
        local b = bot(identity()); if b then b.webStatus = state.webError or 'Website updated' end
        if core.boxnet and core.boxnet.broadcast then
            core.boxnet.broadcast('flags:status', { server = select(2, identity()), text = (state.webError or 'Website updated'):sub(1, 250) })
        end
    end
    if state.webPending and not state.webActive then
        local id = websiteID(state.webPending); state.webPending = nil
        if not id then state.webError = 'Invalid NMS website character ID.'; return end
        state.lastWebFetch = timestamp()
        local ok, why = httpBegin('https://nms.bestemu.com/character/' .. id .. '/progression')
        if ok then state.webActive = id else
            state.webError = tostring(why)
            if core.boxnet and core.boxnet.broadcast then
                core.boxnet.broadcast('flags:status', { server = select(2, identity()), text = state.webError:sub(1, 250) })
            end
        end
    end
end

local function text(s)
    imgui.PushTextWrapPos(0); imgui.TextUnformatted(tostring(s or '')); imgui.PopTextWrapPos()
end
local function cell(value)
    local full = tostring(value or '')
    imgui.TextUnformatted(#full > 72 and full:sub(1, 69) .. '...' or full)
    if imgui.IsItemHovered() and core.setTooltip then core.setTooltip(full) end
end
local function drawRecent()
    local rows = roster()
    local network = core.boxnet
    text('Observed messages, not a server-verified flag checklist. Latest event per bot; select a bot for history.')
    text(network and network.available and network.available() and 'Box Net sharing connected' or 'Local history available; Box Net sharing disconnected')
    if imgui.Button('Sync Bot Histories##flagSync') then state.pendingSync = true end
    imgui.SameLine(); imgui.SetNextItemWidth(core.px(200))
    state.search = imgui.InputText('Find message##flagSearch', state.search)
    imgui.SameLine(); imgui.SetNextItemWidth(core.px(110))
    if imgui.BeginCombo('Type##flagType', state.category) then
        for _, kind in ipairs(categories) do if imgui.Selectable(kind, state.category == kind) then state.category = kind end end
        imgui.EndCombo()
    end
    if state.error then text(state.error) end
    local flags = bit.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.Resizable, ImGuiTableFlags.ScrollY, ImGuiTableFlags.ScrollX)
    if imgui.BeginTable('FlagTrackerBots', 8, flags, ImVec2(0, core.px(220))) then
        local widths = {100,120,200,200,180,200,200,125}
        for i, label in ipairs({ 'Bot', 'Status', 'Website flags', 'Last Flag', 'Last Key', 'Last Quest', 'Latest activity', 'Time' }) do
            imgui.TableSetupColumn(label, ImGuiTableColumnFlags.WidthFixed, core.px(widths[i]))
        end
        if imgui.TableSetupScrollFreeze then imgui.TableSetupScrollFreeze(1, 1) end
        imgui.TableHeadersRow()
        for _, row in ipairs(rows) do
            local e = row.events[1]
            imgui.TableNextRow(); imgui.TableNextColumn()
            if imgui.Selectable(row.name .. '##flagBot', state.selected == key(row.name)) then state.selected = key(row.name); state.webInput = row.website and row.website.id or (key(row.name) == key(identity()) and config().websiteID or '') end
            imgui.TableNextColumn()
            local peer = network and network.peer and network.peer(row.name)
            local online = row.name == identity() or peer and peer.seenAt and nowMs() / 1000 - peer.seenAt < 15
            cell(online and (row.name == identity() or row.trackerSeenAt and timestamp() - row.trackerSeenAt < 90) and 'Tracking' or online and 'Online / no sync' or 'Saved')
            imgui.TableNextColumn(); cell(row.website and row.website.summary or 'Not checked')
            local recent = {}; for _, item in ipairs(row.events) do if not recent[item.kind] then recent[item.kind] = item end end
            for _, kind in ipairs({ 'Flag', 'Key', 'Quest' }) do
                imgui.TableNextColumn(); cell(recent[kind] and recent[kind].text or '-')
            end
            imgui.TableNextColumn(); cell(e and (e.kind .. ': ' .. e.text) or 'No messages recorded yet')
            imgui.TableNextColumn(); cell(e and os.date('%m/%d %H:%M:%S', e.at) or '')
        end
        imgui.EndTable()
    end
    local selected = state.selected and state.bots[state.selected]
    if selected then
        text('Website: ' .. selected.name .. ' (public NMS progression page)')
        state.webInput = imgui.InputText('Character ID or progression URL##flagWebID', state.webInput or '')
        if imgui.Button('Check Website##flagWebCheck') then
            local id = websiteID(state.webInput)
            if not id then state.webError = 'Enter a character ID or https://nms.bestemu.com/character/ID/progression.'
            elseif key(selected.name) == key(identity()) then state.webPending = id
            elseif network and network.send then
                if network.send(selected.name, 'flags:lookup', { id = id, server = select(2, identity()) }) then selected.webStatus = 'Website check requested; bot must have Flag Tracker enabled.' end
            end
        end
        if state.webActive then text('Checking website asynchronously...') end
        if state.webError then text(state.webError) end
        if selected.webStatus then text(selected.webStatus) end
        local w = selected.website
        if w then
            text('Website snapshot ' .. os.date('%m/%d %H:%M:%S', w.at) .. (w.accountWide and ' | Shared account-wide progression' or ''))
            imgui.BeginChild('FlagTrackerWebsite', 0, core.px(130), true)
            for _, row in ipairs(w.rows) do
                text((row.done and '[DONE] ' or '[MISSING] ') .. row.name)
                if not row.done and row.detail ~= '' then text(row.detail) end
            end
            imgui.EndChild()
        end
    end
    text(state.selected and ('History: ' .. (state.bots[state.selected] and state.bots[state.selected].name or '')) or 'History: all bots')
    if imgui.Button('All Bots##flagAll') then state.selected = nil end
    local history = {}
    for _, row in ipairs(rows) do
        if not state.selected or key(row.name) == state.selected then
            for _, e in ipairs(row.events) do
                if (state.category == 'All' or state.category == e.kind) and
                    (state.search == '' or (row.name .. ' ' .. e.text .. ' ' .. e.zone):lower():find(state.search:lower(), 1, true)) then
                    history[#history + 1] = { name = row.name, e = e }
                end
            end
        end
    end
    table.sort(history, function(a, c) if a.e.at == c.e.at then return a.e.id > c.e.id end return a.e.at > c.e.at end)
    imgui.BeginChild('FlagTrackerHistory', 0, core.px(180), true)
    for i, item in ipairs(history) do
        if i > 300 then text('Showing newest 300 matching events. Select a bot or narrow the filter.'); break end
        text(os.date('%m/%d %H:%M:%S', item.e.at) .. ' | ' .. item.name .. ' | ' .. item.e.kind .. ' | ' .. item.e.zone)
        text(item.e.text); imgui.Separator()
    end
    imgui.EndChild()
end
-- Created By: NeroMorte - Comparison matrix: flags down rows, every known bot across columns.
local function drawMatrix()
    local rows = roster()
    text('Live NMS website snapshots only. DONE / MISSING are website results; ? means not checked. The reference PEQ site uses another database and is never imported.')
    if imgui.Button('Refresh Configured Bots##flagRefreshAll') then
        state.webPending = config().websiteID
        local network = core.boxnet
        if network and network.broadcast then network.broadcast('flags:refresh', { server = select(2, identity()) }) end
    end
    imgui.SameLine()
    state.missingOnly = imgui.Checkbox('Show steps missing on any bot##flagMissing', state.missingOnly == true)
    local names, byBot = {}, {}
    for _, b in ipairs(rows) do
        local lookup = {}; byBot[key(b.name)] = lookup
        if b.website then
            local occurrence = {}
            for _, row in ipairs(b.website.rows) do
                occurrence[row.name] = (occurrence[row.name] or 0) + 1
                local id = row.name .. '##' .. occurrence[row.name]
                lookup[id] = row
                if not names[id] then names[id] = row.name end
            end
        end
    end
    local ordered = {}; for id in pairs(names) do ordered[#ordered + 1] = id end; table.sort(ordered)
    if #ordered == 0 then text('Select each bot in Recent Messages and enter its NMS progression page ID. Website results will appear here.'); return end
    local tableFlags = bit.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollX,
        ImGuiTableFlags.ScrollY, ImGuiTableFlags.Resizable)
    -- Dear ImGui tables have a 64-column limit. Keep each horizontal page to 12 bots.
    local pages = math.max(1, math.ceil(#rows / 12)); state.matrixPage = math.min(state.matrixPage or 1, pages)
    if imgui.Button('Previous Bots##flagPrev') then state.matrixPage = math.max(1, state.matrixPage - 1) end
    imgui.SameLine(); text('Bots page ' .. state.matrixPage .. '/' .. pages)
    imgui.SameLine(); if imgui.Button('Next Bots##flagNext') then state.matrixPage = math.min(pages, state.matrixPage + 1) end
    local first, last = (state.matrixPage - 1) * 12 + 1, math.min(state.matrixPage * 12, #rows)
    if imgui.BeginTable('FlagTrackerMatrix', last - first + 2, tableFlags, ImVec2(0, core.px(380))) then
        imgui.TableSetupColumn('Progression Step', ImGuiTableColumnFlags.WidthFixed, core.px(240))
        for i = first, last do imgui.TableSetupColumn(rows[i].name, ImGuiTableColumnFlags.WidthFixed, core.px(110)) end
        if imgui.TableSetupScrollFreeze then imgui.TableSetupScrollFreeze(1, 1) end
        imgui.TableHeadersRow()
        for _, id in ipairs(ordered) do
            local missing = false
            for _, b in ipairs(rows) do local r = byBot[key(b.name)][id]; if not r or not r.done then missing = true end end
            if not state.missingOnly or missing then
                imgui.TableNextRow(); imgui.TableNextColumn(); text(names[id])
                for i = first, last do
                    local b = rows[i]; local r = byBot[key(b.name)][id]
                    imgui.TableNextColumn()
                    local label = r and (r.done and 'DONE' or 'MISSING') or '?'
                    imgui.TextColored(r and (r.done and 0.3 or 1.0) or 0.7, r and (r.done and 0.9 or 0.65) or 0.7, 0.35, 1.0, '%s', label)
                    if imgui.IsItemHovered() and core.setTooltip then
                        core.setTooltip(b.name .. (b.website and (' | ' .. os.date('%m/%d %H:%M', b.website.at) ..
                            (b.website.accountWide and ' | Account-wide' or '')) or ' | No website snapshot') ..
                            (r and r.detail ~= '' and ('\n' .. r.detail) or ''))
                    end
                end
            end
        end
        imgui.EndTable()
    end
end
local function draw()
    if imgui.BeginTabBar('FlagTrackerTabs') then
        if imgui.BeginTabItem('Bots / Recent Messages') then drawRecent(); imgui.EndTabItem() end
        if imgui.BeginTabItem('Flag Matrix') then drawMatrix(); imgui.EndTabItem() end
        imgui.EndTabBar()
    end
end
function plugin.onInit(api)
    core, mq, ctrl, imgui = api, api.mq, api.ctrl, api.ImGui
    state.bots, state.seen, state.outbound, state.unsub, state.requests = {}, {}, {}, {}, {}
    state.network, state.lastSync, state.dirty, state.path, state.error = nil, -100, false, nil, nil
    state.session = tostring(timestamp()) .. '_' .. tostring(read(function() return mq.TLO.EverQuest.PID() end, 0)) ..
        '_' .. tostring(read(function() return mq.gettime() end, 0))
    config(); bot(identity()); loadHistory(); state.pendingSync = true
    if ctrl.show_flag_tracker == nil then ctrl.show_flag_tracker = false end
    mq.event('TriuneFlagTrackerMessages', '#*#', observe)
end
function plugin.onTick()
    attach()
    local c = config()
    if c.websiteID and not state.webActive and timestamp() - (state.lastWebFetch or 0) >= 60 and
        ((state.webRefreshDue and timestamp() >= state.webRefreshDue) or timestamp() - (state.lastWebFetch or 0) >= 600) then
        state.webPending, state.webRefreshDue = c.websiteID, nil
    end
    websiteTick()
    if state.webPublish then queueWebsite(); state.webPublish = false end
    local network = state.network
    local _, server = identity()
    if network and network.available and network.available() then
        if state.pendingSync or timestamp() - state.lastSync >= 60 then
            network.broadcast('flags:request', { server = server })
            state.lastSync, state.pendingSync = timestamp(), false
        end
        local packet = state.outbound[1]
        if packet then
            local ok
            if packet.to then ok = network.send(packet.to, packet.topic or 'flags:events', packet)
            else ok = network.broadcast(packet.topic or 'flags:events', packet) end
            if ok then table.remove(state.outbound, 1) end
        end
    end
    if state.dirty and timestamp() - state.lastSave >= 2 then saveHistory(); state.lastSave = timestamp() end
end
function plugin.onDestroy()
    httpClose(true)
    if mq and mq.unevent then mq.unevent('TriuneFlagTrackerMessages') end
    for _, unsub in ipairs(state.unsub) do pcall(unsub) end
    if state.dirty then saveHistory() end
end
function plugin.onDrawUI()
    if not ctrl or not ctrl.show_flag_tracker then return end
    core.pushTheme()
    imgui.SetNextWindowSize(core.px(1050), core.px(600), ImGuiCond.FirstUseEver)
    core.preBeginWindow('flag_tracker')
    local open, show = imgui.Begin('Triune Flag Tracker###triuneFlagTracker', ctrl.show_flag_tracker,
        core.windowFlags and core.windowFlags('flag_tracker', 0) or 0)
    if not open then ctrl.show_flag_tracker = false; core.saveLoadout(true) end
    if show then core.postBeginWindow('flag_tracker'); draw() end
    if core.preEndWindow then core.preEndWindow('flag_tracker', false) end
    imgui.End(); core.popTheme()
end
function plugin.onDrawSettings()
    local c = config()
    local value, changed = imgui.Checkbox('Listen for progression messages##flagListen', c.listen)
    if changed then c.listen = value; core.saveLoadout(true) end
    value, changed = imgui.Checkbox('Include targeted NPC dialogue##flagDialogue', c.dialogue)
    if changed then c.dialogue = value; core.saveLoadout(true) end
    value, changed = imgui.Checkbox('Print own flag/key notices##flagNotify', c.notify)
    if changed then c.notify = value; core.saveLoadout(true) end
    text('Add literal server phrases when a quest uses a different success message. These record observations, not verified unlocks.')
    state.customText = imgui.InputText('Server phrase##flagPhrase', state.customText)
    if imgui.BeginCombo('Record as##flagCustomKind', state.customKind) then
        for _, k in ipairs(categories) do if k ~= 'All' and imgui.Selectable(k, state.customKind == k) then state.customKind = k end end
        imgui.EndCombo()
    end
    if imgui.Button('Add Phrase##flagAddPhrase') and #state.customText >= 4 and #c.rules < 20 then
        c.rules[#c.rules + 1] = { text = state.customText:sub(1, 120), kind = state.customKind }
        state.customText = ''; core.saveLoadout(true)
    end
    local remove
    for i, rule in ipairs(c.rules) do
        rule = type(rule) == 'table' and rule or {}
        text(tostring(rule.kind) .. ': ' .. tostring(rule.text))
        imgui.SameLine(); if imgui.SmallButton('Remove##flagRule' .. i) then remove = i end
    end
    if remove then table.remove(c.rules, remove); core.saveLoadout(true) end
    text('History: ' .. tostring(state.path or dataPath() or 'waiting for character'))
end
function plugin.onSaveSettings()
    local c = config()
    return { listen = c.listen, dialogue = c.dialogue, notify = c.notify, rules = c.rules, websiteID = c.websiteID }
end
function plugin.onLoadSettings(saved)
    if type(saved) ~= 'table' then return end
    local c = config()
    for _, k in ipairs({ 'listen', 'dialogue', 'notify' }) do if type(saved[k]) == 'boolean' then c[k] = saved[k] end end
    c.websiteID = websiteID(saved.websiteID)
    c.rules = {}
    if type(saved.rules) == 'table' then
        for i, rule in ipairs(saved.rules) do
            if i > 20 then break end
            if type(rule) == 'table' and type(rule.text) == 'string' and #rule.text >= 4 and #rule.text <= 120 then
                for _, kind in ipairs(categories) do
                    if kind ~= 'All' and kind == rule.kind then c.rules[#c.rules + 1] = { text = rule.text, kind = kind } end
                end
            end
        end
    end
end
function plugin.onCommand(cmd)
    if cmd ~= 'flags' and cmd ~= 'flagtracker' then return false end
    ctrl.show_flag_tracker = not ctrl.show_flag_tracker; core.saveLoadout(true); return true
end
plugin.help = { '  /ac flags | flagtracker - Toggle shared Flag Tracker' }
-- Created By: NeroMorte - Narrow pure hooks for actual-source regression fixtures.
plugin.queueWebsite, plugin.receiveWebsite, plugin.requestWebsite = queueWebsite, receiveWebsite, requestWebsite
plugin.parseWebsite, plugin.websiteID = parseWebsite, websiteID
plugin.classify, plugin.observe, plugin.receive, plugin.roster = classify, observe, receive, roster
plugin.state, plugin.saveHistory, plugin.loadHistory = state, saveHistory, loadHistory
return plugin
