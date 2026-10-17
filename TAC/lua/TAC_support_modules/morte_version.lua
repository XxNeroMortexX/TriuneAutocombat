-- Edited By: NeroMorte - Integrate Gennro 3.2 fixes while preserving this fork's behavior.
-- Created by: NeroMorte - NeroMorte/Triune release and updater version metadata.
--
-- This file identifies the installed NeroMorte release and the updater engine
-- generation expected by that release.
--
-- Keep Gennro, NeroMorte, and MQ2WebUpdate as separate version identities.
-- The Update Manager can compare these local values with their corresponding
-- remote GitHub values independently.
--
-- Keep this file Lua 5.1 compatible.

local version = {}

version.schema = 1

---------------------------------------------------------------------------
-- NEROMORTE RELEASE
---------------------------------------------------------------------------

version.morte = {
    -- Edited By: NeroMorte - Isolated Gennro 3.2 integration candidate; engine remains independent.
    version = 'Morte.11-test',

    -- Gennro Triune version this NeroMorte release was built/tested against.
    basedOnGennro = '3.2',

    channel = 'test',
}

---------------------------------------------------------------------------
-- MQ2WEBUPDATE ENGINE
--
-- This is intentionally independent from the NeroMorte release number.
-- Future engine updates can therefore occur without pretending that the
-- entire NeroMorte/Triune release has changed.
---------------------------------------------------------------------------

version.engine = {
    -- Edited By: NeroMorte - Publish the Windows-built MQ runtime root updater.
    expectedVersion = '4.1.8',
    minimumVersion = '4.0.0',
}

---------------------------------------------------------------------------
-- DISPLAY
---------------------------------------------------------------------------

version.display = {
    morteName = 'NeroMorte',
    gennroName = 'Gennro',
    engineName = 'MQ2WebUpdate',
}

return version
