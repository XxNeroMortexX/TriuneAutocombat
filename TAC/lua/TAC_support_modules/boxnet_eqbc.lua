-- Created By: NeroMorte — EQBC adapter for Triune's existing Box Network protocol.
-- Frames contain bounded plain data, never executable Lua. Only one transport
-- is selected at a time. MQ2EQBC's normal remote-command control must be enabled.
local M = {}
local MAX_BYTES, CHUNK, MAX_PARTS, TTL = 32768, 1200, 64, 5

local function encode(value, depth)
    depth = depth or 0
    if depth > 12 then error('EQBC data nesting limit') end
    local kind = type(value)
    if kind == 'nil' then return 'z' end
    if kind == 'boolean' then return value and 't' or 'f' end
    if kind == 'string' or kind == 'number' then
        if kind == 'number' and (value ~= value or value == math.huge or value == -math.huge) then error('invalid number') end
        local text = tostring(value)
        return (kind == 'string' and 's' or 'n') .. #text .. ':' .. text
    end
    if kind ~= 'table' then error('unsupported EQBC value') end
    local parts, count = {}, 0
    for key, item in pairs(value) do
        if type(key) ~= 'number' and type(key) ~= 'string' then error('invalid EQBC key') end
        count = count + 1
        if count > 512 then error('EQBC table entry limit') end
        parts[#parts + 1] = encode(key, depth + 1) .. encode(item, depth + 1)
    end
    return 'o' .. count .. ':' .. table.concat(parts)
end

local function decode(text)
    if #text > MAX_BYTES then error('EQBC packet too large') end
    local cursor = 1
    local function read(depth)
        if depth > 12 then error('EQBC data nesting limit') end
        local tag = text:sub(cursor, cursor); cursor = cursor + 1
        if tag == 'z' then return nil end
        if tag == 't' then return true end
        if tag == 'f' then return false end
        if tag ~= 'o' and tag ~= 's' and tag ~= 'n' then error('invalid EQBC data tag') end
        local finish = text:find(':', cursor, true)
        if not finish or finish - cursor > 8 then error('invalid EQBC length') end
        local length = text:sub(cursor, finish - 1)
        if not length:match('^%d+$') then error('invalid EQBC length') end
        length = tonumber(length); cursor = finish + 1
        if tag == 'o' then
            if length > 512 then error('EQBC table entry limit') end
            local out = {}
            for _ = 1, length do
                local key, value = read(depth + 1), read(depth + 1)
                if type(key) ~= 'string' and type(key) ~= 'number' then error('invalid EQBC key') end
                if out[key] ~= nil then error('duplicate EQBC key') end
                out[key] = value
            end
            return out
        end
        if cursor + length - 1 > #text then error('truncated EQBC data') end
        local value = text:sub(cursor, cursor + length - 1); cursor = cursor + length
        if tag == 'n' then
            value = tonumber(value)
            if not value or value ~= value or value == math.huge or value == -math.huge then error('invalid EQBC number') end
        end
        return value
    end
    local result = read(0)
    if cursor ~= #text + 1 then error('trailing EQBC data') end
    return result
end

local function hex(text)
    return (text:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end
local function unhex(text)
    if #text % 2 ~= 0 or text:find('[^%x]') then error('invalid EQBC hex') end
    return (text:gsub('..', function(c) return string.char(tonumber(c, 16)) end))
end
local function validName(name)
    return type(name) == 'string' and name:match('^[A-Za-z][A-Za-z0-9_]*$') and #name <= 64
end

function M.new(opts)
    local endpoint = { fragments = {}, pending = {}, completed = {}, serial = 0, closed = false }
    -- Process IDs can collide across PCs; the name and per-instance session
    -- form the identity. Never treat a remote PID as proof it is our own box.
    local session = tostring(opts.clock()):gsub('[^%w]', '') .. tostring(endpoint):gsub('[^%w]', '')
    function endpoint:connected() return not self.closed and opts.connected() == true end
    function endpoint:packet(to, packet)
        if not self:connected() then error('MQ2EQBC is not connected') end
        if to and not validName(to) then error('invalid EQBC recipient name') end
        local me = opts.name()
        if not validName(me) then error('invalid EQBC character name') end
        packet.sender = { character = me, server = opts.server(), transport = 'eqbc' }
        packet.sentAt = opts.clock()
        local text = encode(packet)
        if #text > MAX_BYTES then error('EQBC packet too large') end
        self.serial = self.serial + 1
        local id = me .. '_' .. session .. '_' .. self.serial
        local data = hex(text)
        local count = math.ceil(#data / CHUNK)
        if count > MAX_PARTS then error('too many EQBC fragments') end
        for part = 1, count do
            local frame = id .. '.' .. part .. '.' .. count .. '.' .. data:sub((part - 1)*CHUNK + 1, part*CHUNK)
            local prefix = to and ('/bct ' .. to) or '/bca'
            opts.command(prefix .. ' //ac net _eqbc ' .. frame)
        end
        return id
    end
    function endpoint:send(a, b, c)
        local address, payload, callback
        if type(b) == 'table' then address, payload, callback = a, b, c
        else payload, callback = a, b end
        local to = address and address.character
        if callback and not to then error('EQBC RPC requires a named recipient') end
        local request
        if callback then
            request = opts.name() .. '_' .. session .. '_r' .. (self.serial + 1)
            self.pending[request] = { callback = callback, to = to:lower(), deadline = opts.clock() + TTL }
        end
        local ok, err = pcall(self.packet, self, to, { v = 1, payload = payload, request = request })
        if not ok then
            if request then self.pending[request] = nil end
            error(err)
        end
    end
    function endpoint:receive(frame)
        if not self:connected() then return false, 'MQ2EQBC is not connected' end
        if type(frame) ~= 'string' or #frame > CHUNK + 240 then return false, 'invalid EQBC frame size' end
        local id, part, count, data = frame:match('^([%w_]+)%.(%d+)%.(%d+)%.([%x]+)$')
        part, count = tonumber(part), tonumber(count)
        if not id or #id > 200 or not part or not count or count < 1 or count > MAX_PARTS or part < 1 or part > count or #data > CHUNK then return false, 'invalid EQBC fragment' end
        if self.completed[id] then return true end
        local item = self.fragments[id]
        if not item then
            local active = 0; for _ in pairs(self.fragments) do active = active + 1 end
            if active >= 128 then return false, 'EQBC fragment inbox full' end
            item = { count = count, parts = {}, received = 0, deadline = opts.clock() + TTL, bytes = 0 }
            self.fragments[id] = item
        end
        if item.count ~= count or (item.parts[part] and item.parts[part] ~= data) then
            self.fragments[id] = nil; return false, 'conflicting EQBC fragments'
        end
        if not item.parts[part] then
            item.parts[part] = data; item.received = item.received + 1; item.bytes = item.bytes + #data
        end
        if item.bytes > MAX_BYTES*2 then self.fragments[id] = nil; return false, 'EQBC packet too large' end
        if item.received ~= count then return true end
        self.fragments[id] = nil
        self.completed[id] = opts.clock() + TTL
        local ok, packet = pcall(function() return decode(unhex(table.concat(item.parts))) end)
        if not ok or type(packet) ~= 'table' or packet.v ~= 1 or type(packet.sender) ~= 'table' or not validName(packet.sender.character) then return false, 'invalid EQBC packet' end
        local sender = packet.sender
        sender.transport, sender.pid, sender.account = 'eqbc', nil, nil
        if opts.server() ~= '' and sender.server ~= opts.server() then return false, 'different EQ game server' end
        if type(packet.response) == 'string' then
            local pending = self.pending[packet.response]
            if not pending or pending.to ~= sender.character:lower() then return false, 'unexpected EQBC response' end
            self.pending[packet.response] = nil
            pending.callback(tonumber(packet.status) or -3, { sender = sender, content = packet.payload })
        else
            if type(packet.payload) ~= 'table' then return false, 'invalid EQBC payload' end
            if packet.payload.from ~= sender.character then return false, 'EQBC sender mismatch' end
            -- Heartbeat target times originate from each PC's uptime. Preserve
            -- target age in the receiver's clock instead of comparing boot times.
            local payload = packet.payload
            local target = payload.kind == 'heartbeat' and type(payload.data) == 'table' and payload.data.target
            if type(target) == 'table' and type(target.since) == 'number' then
                if type(packet.sentAt) == 'number' then
                    target.since = opts.clock() - math.max(0, packet.sentAt - target.since)
                else target.since = nil end
            end
            local message = { content = payload, sender = sender }
            if type(packet.request) == 'string' then
                function message:reply(status, payload)
                    endpoint:packet(sender.character, { v = 1, response = packet.request, status = status, payload = payload })
                end
            end
            opts.deliver(message)
        end
        return true
    end
    function endpoint:tick()
        local now = opts.clock()
        for id, item in pairs(self.fragments) do if item.deadline <= now then self.fragments[id] = nil end end
        for id, deadline in pairs(self.completed) do if deadline <= now then self.completed[id] = nil end end
        for id, item in pairs(self.pending) do
            if not self:connected() or item.deadline <= now then
                self.pending[id] = nil
                item.callback(self:connected() and -3 or -2, nil)
            end
        end
        if not self:connected() then self.fragments, self.completed = {}, {} end
    end
    function endpoint:close()
        self.closed = true
        self:tick()
    end
    return endpoint
end

M.encode, M.decode, M.hex, M.unhex = encode, decode, hex, unhex
return M
