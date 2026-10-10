-- Created By: NeroMorte - automatic setup and discovery state, independent of ImGui/MQ.
local M = {}
function M.new()
    local self = { enabled=true, host='', port=2113, protected=false,
        status='Looking for an EQBC server', nextScan=0, nextConnect=0, attempts=0,
        scanStarted=nil, pending=nil, manualPassword='', servers={} }
    function self:settings()
        return { enabled=self.enabled, host=self.host, port=self.port, protected=self.protected }
    end
    function self:load(s)
        if type(s) ~= 'table' then return end
        if s.enabled ~= nil then self.enabled=s.enabled==true end
        self.host=tostring(s.host or '')
        self.port=tonumber(s.port) or 2113
        self.protected=s.protected==true
    end
    function self:request(action, server, password)
        self.pending={action=action, server=server, password=password}
    end
    function self:connect(server, password, api, now)
        local host=tostring(server.host or '')
        local port=tonumber(server.port)
        if host=='' or #host>253 or host:find('[^%w%.%-]') or not port or port%1~=0 or port<1 or port>65535 then
            self.status='Enter a valid host and port'; return
        end
        if password and (password:find('[%s%c";]') or #password>39) then
            self.status='Password must be one token, at most 39 characters'; return
        end
        self.host, self.port, self.protected=host,port,server.password==true
        self.enabled=true; api.select(); api.save()
        api.command('/squelch /bccmd set control on')
        -- BoxNet owns reconnect pacing; do not race the native AutoConnect loop.
        api.command('/squelch /bccmd set autoconnect off')
        api.command('/squelch /bccmd set reconnect off')
        api.command('/squelch /bccmd stopreconnect')
        local suffix= self.protected and ((password and password~='') and (' '..password) or '') or ' NULL'
        api.command('/squelch /bccmd connect '..host..' '..port..suffix)
        self.manualPassword=''; self.nextConnect=now+15; self.attempts=self.attempts+1
        self.status='Connecting to '..host..':'..port
    end
    function self:tick(now, view, api)
        self.servers=view.servers or {}
        local pending=self.pending; self.pending=nil
        if pending and pending.action=='disconnect' then
            if view.connecting then self.pending=pending; self.status='Waiting to disconnect'; return end
            self.enabled=false; self.scanStarted=nil
            api.command('/squelch /bccmd set autoconnect off')
            api.command('/squelch /bccmd set reconnect off')
        api.command('/squelch /bccmd stopreconnect')
            api.command('/squelch /bccmd quit'); api.localMode(); api.save()
            self.status='Disconnected; local Actors enabled'; return
        end
        if not self.enabled then self.status='Local Actors selected'; return end
        if not view.loaded then
            if now>=self.nextScan then api.command('/squelch /plugin mq2eqbc load'); self.nextScan=now+15 end
            self.pending=pending; self.status='Loading MQ2EQBC'; return
        end
        if pending and pending.action=='connect' then
            if view.connecting then self.pending=pending; self.status='Waiting for current connection attempt'; return end
            if view.connected then api.command('/squelch /bccmd quit') end
            self:connect(pending.server,pending.password,api,now); return
        end
        if pending and pending.action=='scan' and view.discovery then
            api.command('/squelch /eqbcdiscover'); self.scanStarted=now; self.nextScan=now+10
        end
        if view.connected then
            self.attempts=0
            if self.host=='' and view.host and view.host~='OFFLINE' then
                self.host=tostring(view.host); self.port=tonumber(view.port) or 2113
                self.protected=true -- Reuse native saved password, without exposing it.
                api.save()
            end
            api.select()
            if not view.control and now>=self.nextConnect then
                api.command('/squelch /bccmd set control on'); self.nextConnect=now+2
            end
            self.status='Connected to '..tostring(view.host)..':'..tostring(view.port)
            if not view.discovery then self.status=self.status..' (update MQ2EQBC for discovery and quiet packets)' end
            return
        end
        if view.connecting then self.status='Connecting...'; return end
        if not view.discovery then self.status='Update MQ2EQBC to enable automatic discovery'; return end
        if self.host~='' and self.attempts<2 and now>=self.nextConnect then
            self:connect({host=self.host,port=self.port,password=self.protected},nil,api,now); return
        end
        if view.scanning then self.status='Searching this LAN...'; return end
        if self.scanStarted and now-self.scanStarted>=4 then
            self.scanStarted=nil
            if #self.servers==1 and now>=self.nextConnect then
                local server=self.servers[1]
                if server.password then
                    self.status='Server requires a password; select it and connect'
                else self:connect(server,nil,api,now); return end
            elseif #self.servers>1 then self.status='Several servers found; choose one below'
            else self.status='No server found. Start EQBCS-Go or enter an address below' end
        end
        if now>=self.nextScan then
            api.command('/squelch /eqbcdiscover'); self.scanStarted=now; self.nextScan=now+10
        end
    end
    return self
end
return M
