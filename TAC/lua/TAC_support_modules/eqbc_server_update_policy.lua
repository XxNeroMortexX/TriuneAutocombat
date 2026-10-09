-- Created By: NeroMorte - add-only standalone server mappings after the MQ-root engine upgrade.
local M = {}
local function versionOK(version)
    local major, minor, patch = tostring(version or ''):match('^(%d+)%.(%d+)%.(%d+)$')
    major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch)
    return major and (major > 4 or (major == 4 and (minor > 1 or (minor == 1 and patch >= 7))))
end
local function valid(release)
    if type(release) ~= 'table' or release.enabled ~= true or type(release.payloads) ~= 'table' or #release.payloads ~= 2 then return false end
    local names = {['EQBCS.exe']=true, ['EQBCS-Go.exe']=true}
    for _, item in ipairs(release.payloads) do
        if type(item.id) ~= 'string' or not item.id:match('^[%w_-]+$') or #item.id > 64
            or not names[item.name] or item.remote ~= 'EQBCServers/'..item.name
            or type(item.sha256) ~= 'string' or #item.sha256 ~= 64 or item.sha256:find('[^%x]') then return false end
        names[item.name] = nil
    end
    return true
end
function M.new(release)
    local self = {done=not valid(release), release=release}
    function self:step(engine, prefs, command, encode, save, log)
        if self.done then return true end
        if not engine.available or engine.busy or engine.stageReady or (engine.profileStoreError or '') ~= '' then return false end
        if not versionOK(engine.version) then
            log('EQBC server registration waits for MQ2WebUpdate 4.1.7 or newer. Existing updates remain available.')
            self.done = true; return true
        end
        prefs.eqbc_server_update_policy = prefs.eqbc_server_update_policy or {}
        for _, profile in ipairs(engine.managedProfiles or {}) do
            if profile.enabled and profile.role == 'main' and tostring(profile.owner or ''):lower() == 'xxneromortexx'
                and profile.repository == 'TriuneAutocombat' and tostring(profile.id or ''):match('^[%w_-]+$') then
                local states = prefs.eqbc_server_update_policy[profile.id] or {}
                prefs.eqbc_server_update_policy[profile.id] = states
                for _, item in ipairs(release.payloads) do
                    local id = item.id
                    local marker = states[id]
                    if marker ~= 'done' then
                        local mapping, equivalent
                        for _, entry in ipairs(profile.mappings or {}) do
                            if entry.id == id then mapping = entry end
                            if tostring(entry.remotePath or ''):lower() == item.remote:lower()
                                and entry.destinationRoot == 'mq' then equivalent = true end
                        end
                        if marker == nil and (mapping or equivalent) then
                            states[id] = 'done'; save(); log('Preserved existing '..item.name..' update mapping.')
                        elseif not mapping then
                            states[id] = 'creating'; save()
                            command('/squelch /webupdate mappings create '..profile.id..' '..id, 'Registering '..item.name..' update mapping.')
                            return false
                        else
                            -- Disable first; set nonrecursive before selecting the flat MQ root.
                            local fields = {{'enabled','off'}, {'name',item.name..' server'}, {'remote',item.remote},
                                {'recursive','off'}, {'destination',''}, {'root','mq'}, {'required','off'},
                                {'restart','off'}, {'enabled','on'}}
                            local keys = {enabled='enabled',name='name',remote='remotePath',root='destinationRoot',
                                destination='destinationPath',recursive='recursive',required='required',restart='restartRequired'}
                            local index = type(marker) == 'number' and marker or 1
                            if index <= #fields then
                                local field, value = fields[index][1], fields[index][2]
                                local desired = value
                                if value == 'on' then desired = true elseif value == 'off' then desired = false end
                                if mapping[keys[field]] == desired then states[id] = index + 1; save()
                                else
                                    command(string.format('/squelch /webupdate mappings set %s %s %s %s',
                                        profile.id, id, field, encode(value)), 'Configuring '..item.name..' update mapping.')
                                end
                                return false
                            end
                            if mapping.enabled and mapping.remotePath == item.remote and mapping.destinationRoot == 'mq'
                                and mapping.destinationPath == '' and not mapping.recursive then
                                states[id] = 'done'; save(); log(item.name..' registered beside MacroQuest.exe.')
                            else
                                log('Could not verify '..item.name..' registration; existing profiles retained.')
                                self.done = true; return true
                            end
                        end
                    end
                end
            end
        end
        self.done = true; return true
    end
    return self
end
M.versionOK = versionOK
return M
