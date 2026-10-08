-- Created By: NeroMorte - Consume owned Nav completions without inferring success from an inactive path.
local M = {}
local function read(fn)
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end
local function enabled(value)
    value = tostring(value or ''):lower()
    return value == '1' or value == 'true' or value == 'on'
end
local function moved(a, b)
    return math.sqrt((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2)
end
function M.new(mq)
    local self = { mq = mq, sequence = 0 }
    function self:clear()
        self.pending, self.accepted, self.failed = nil, nil, nil
    end
    function self:isVertical()
        return read(function() return mq.TLO.Me.Underwater() end) == true
            or read(function() return mq.TLO.Me.Levitating() end) == true
    end
    function self:start(id, distance, kind)
        self.sequence = self.sequence + 1
        local tag = string.format('triune_%s_%d_%d', kind, id, self.sequence)
        self.pending = { id=id, distance=distance, kind=kind, tag=tag,
            serial=tonumber(read(function() return mq.TLO.Navigation.LastResultSerial() end)),
            zone=read(function() return mq.TLO.Zone.ID() end) }
        self.accepted, self.failed = nil, nil
        return tag
    end
    function self:arrived(id, distance, kind, geometry, los)
        if not geometry or not los or not self:isVertical()
            or not enabled(read(function() return mq.TLO.Navigation.Setting('XYZStallArrival') end)) then
            self.accepted = nil
            return false
        end
        local limit = tonumber(read(function() return mq.TLO.Navigation.Setting('XYZStallDistance') end)) or 5
        limit = math.max(1, math.min(25, limit))
        local zone = read(function() return mq.TLO.Zone.ID() end)
        local arrival = math.max(1, distance)
        local a = self.accepted
        if a and (read(function() return mq.TLO.Navigation.Active() end) ~= false
            or tonumber(read(function() return mq.TLO.Navigation.LastResultSerial() end)) ~= a.serial
            or a.id ~= id or a.distance ~= distance or a.kind ~= kind or a.zone ~= zone
            or moved(a, geometry) > 1 or geometry.horizontal > arrival or geometry.distance > limit) then
            self.accepted, a = nil, nil
        end
        if a then return true end
        local p = self.pending
        if not p or p.id ~= id or p.distance ~= distance or p.kind ~= kind or p.zone ~= zone
            or p.serial == nil or read(function() return mq.TLO.Navigation.Active() end) ~= false then return false end
        local serial = tonumber(read(function() return mq.TLO.Navigation.LastResultSerial() end))
        if not serial or serial == p.serial
            or tonumber(read(function() return mq.TLO.Navigation.LastTargetID() end)) ~= id
            or read(function() return mq.TLO.Navigation.LastTag() end) ~= p.tag then return false end
        if read(function() return mq.TLO.Navigation.LastResult() end) ~= 'Reached'
            or read(function() return mq.TLO.Navigation.LastXYZStallArrival() end) ~= true then return false end
        if geometry.horizontal > arrival or geometry.distance > limit then return false end
        self.accepted = {id=id, distance=distance, kind=kind, zone=zone, serial=serial,
            x=geometry.x, y=geometry.y, z=geometry.z}
        self.pending = nil
        return true
    end
    function self:canUseNav(id, distance, kind, geometry)
        if not geometry then return true end
        local p = self.pending
        if p and p.id == id and p.kind == kind and p.distance == distance
            and p.serial ~= nil and read(function() return mq.TLO.Navigation.Active() end) == false then
            local serial = tonumber(read(function() return mq.TLO.Navigation.LastResultSerial() end))
            if serial and serial ~= p.serial
                and tonumber(read(function() return mq.TLO.Navigation.LastTargetID() end)) == id
                and read(function() return mq.TLO.Navigation.LastTag() end) == p.tag
                and read(function() return mq.TLO.Navigation.LastResult() end) == 'Cancelled' then
                self.failed = {id=id, kind=kind, distance=distance, x=geometry.x, y=geometry.y, z=geometry.z,
                    mx=read(function() return mq.TLO.Me.X() end) or 0,
                    my=read(function() return mq.TLO.Me.Y() end) or 0,
                    mz=read(function() return mq.TLO.Me.Z() end) or 0, at=os.clock()}
                self.pending = nil
            end
        end
        local f = self.failed
        if not f then return true end
        local mx = read(function() return mq.TLO.Me.X() end) or f.mx
        local my = read(function() return mq.TLO.Me.Y() end) or f.my
        local mz = read(function() return mq.TLO.Me.Z() end) or f.mz
        local displaced = math.sqrt((mx-f.mx)^2 + (my-f.my)^2 + (mz-f.mz)^2)
        if f.id ~= id or f.kind ~= kind or f.distance ~= distance or moved(f, geometry) > 1
            or (displaced > 2 and os.clock()-f.at >= 1) then
            self.failed = nil
            return true
        end
        return false
    end
    function self:waitingNear(geometry, los)
        local p = self.pending
        return p and p.serial ~= nil and geometry and los and self:isVertical()
            and geometry.horizontal <= math.max(1, p.distance)
            and enabled(read(function() return mq.TLO.Navigation.Setting('XYZStallArrival') end))
            and read(function() return mq.TLO.Navigation.Active() end) == true
    end
    return self
end
return M
