-- Created By: NeroMorte - create server settings once, without managing users' INIs as update payloads.
local M = {}
local sep = package.config:sub(1, 1)
local function read(path)
    local file = io.open(path, 'rb')
    if not file then return nil end
    local contents = file:read('*a'); file:close()
    return contents
end
local function exists(path)
    local file = io.open(path, 'rb')
    if not file then return false end
    file:close(); return true
end
local native = '; Created By: NeroMorte - initial EQBC server settings; existing settings are preserved.\r\n[Settings]\r\nPort=2112\r\nPassword=\r\n'
local go = '; Created By: NeroMorte - initial Go server settings; existing settings are preserved.\r\n[Settings]\r\nPort=2113\r\nPassword=\r\nHost=0.0.0.0\r\nVerbose=false\r\nNoTimestamp=false\r\nNoColor=false\r\nShowInternalPackets=false\r\n'
function M.ensure(root, log)
    if type(root) ~= 'string' or root == '' then return false end
    local prefix = root:gsub('[\\/]+$', '') .. sep
    -- Snapshot before creating the native default: old shared INIs retain the
    -- same Go password/port/flags when migrating to a separate Go INI.
    local legacy = read(prefix .. 'EQBCS.ini')
    local ok = true
    for _, entry in ipairs({
        {exe='EQBCS.exe', ini='EQBCS.ini', contents=native},
        {exe='EQBCS-Go.exe', ini='EQBCS-Go.ini', contents=legacy or go},
    }) do
        local path = prefix .. entry.ini
        if exists(prefix .. entry.exe) and not exists(path) then
            -- Exclusive creation prevents two clients from overwriting each
            -- other or an INI created between the existence check and open.
            local file, err = io.open(path, 'wx')
            if file then
                local written, writeErr = file:write(entry.contents)
                local closed, closeErr = file:close()
                if written and closed then
                    log('Created missing '..entry.ini..'; the server was not started.')
                else
                    ok = false; log('Could not finish '..entry.ini..': '..tostring(writeErr or closeErr))
                end
            elseif not exists(path) then
                ok = false; log('Could not create '..entry.ini..': '..tostring(err))
            end
        end
    end
    return ok
end
return M
