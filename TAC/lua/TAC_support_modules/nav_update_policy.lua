-- Created By: NeroMorte - One-time add-only Nav mapping migration through the existing updater API.
local M = {}
local mappingID = 'plugin-mq2nav'
local fields = { {'enabled','off'}, {'name','MQ2Nav - NeroMorte XYZ'},
    {'remote','MQ2Nav/MQ2Nav.dll'}, {'root','plugins'}, {'recursive','off'},
    {'required','off'}, {'restart','off'}, {'enabled','on'} }
local function validRelease(release)
    return release and release.enabled == true and release.remote == 'MQ2Nav/MQ2Nav.dll'
        and type(release.sha256) == 'string' and #release.sha256 == 64
        and not release.sha256:find('[^%x]') and release.client == 'RoF2' and release.architecture == 'Win32'
end
function M.new(release)
    local self = { release=release, done=not validRelease(release) }
    function self:step(engine, prefs, command, encode, save, log)
        if self.done then return true end
        if not engine.available or engine.busy or engine.stageReady
            or (engine.profileStoreError or '') ~= '' then return false end
        if type(prefs.nav_plugin_update_policy) ~= 'table' then prefs.nav_plugin_update_policy = {} end
        local states = prefs.nav_plugin_update_policy
        for _, profile in ipairs(engine.managedProfiles or {}) do
            if tostring(profile.owner or ''):lower() == 'xxneromortexx'
                and profile.repository == 'TriuneAutocombat' and profile.enabled
                and tostring(profile.id or ''):match('^[%w_-]+$') then
                local marker = states[profile.id]
                if marker ~= 'done' then
                    local mapping, equivalent
                    for _, entry in ipairs(profile.mappings or {}) do
                        if entry.id == mappingID then mapping = entry end
                        if tostring(entry.remotePath or ''):lower() == 'mq2nav/mq2nav.dll'
                            and entry.destinationRoot == 'plugins' then equivalent = true end
                    end
                    if marker == nil and (mapping or equivalent) then
                        states[profile.id] = 'done'; save()
                        log('Preserved existing MQ2Nav mapping for '..profile.id..'.')
                    elseif marker == nil then
                        states[profile.id] = 'creating'; save()
                        command('/squelch /webupdate mappings create '..profile.id..' '..mappingID,
                            'Registering MQ2Nav update mapping.')
                        return false
                    elseif marker == 'creating' and not mapping then
                        command('/squelch /webupdate mappings create '..profile.id..' '..mappingID,
                            'Retrying MQ2Nav mapping registration after updater unlocks.')
                        return false
                    elseif mapping then
                        local index = type(marker) == 'number' and marker or 1
                        if index <= #fields then
                            local field, value = fields[index][1], fields[index][2]
                            -- Verify the prior step against the backend before advancing.
                            local keys = {enabled='enabled', name='name', remote='remotePath',
                                root='destinationRoot', recursive='recursive', required='required', restart='restartRequired'}
                            local actual = mapping[keys[field]]
                            local desired = (value == 'on' and true) or (value == 'off' and false) or value
                            if value == 'off' then desired = false end
                            if actual == desired then
                                states[profile.id] = index + 1; save()
                            else
                                command(string.format('/squelch /webupdate mappings set %s %s %s %s',
                                    profile.id, mappingID, field, encode(value)), 'Configuring MQ2Nav update mapping.')
                            end
                            return false
                        end
                        if mapping.enabled and mapping.remotePath == self.release.remote
                            and mapping.destinationRoot == 'plugins' and mapping.destinationPath == '' then
                            states[profile.id] = 'done'; save()
                            log('MQ2Nav updates registered automatically; use the existing verified DLL handoff.')
                        else
                            log('MQ2Nav mapping migration could not be verified; existing profiles retained.')
                            self.done = true
                            return true
                        end
                    end
                end
            end
        end
        self.done = true
        return true
    end
    return self
end
return M
