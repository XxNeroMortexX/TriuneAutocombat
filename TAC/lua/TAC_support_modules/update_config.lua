-- Created by: NeroMorte - Configurable deployment policy for MQ2WebUpdate.
--
-- This file contains CHANGEABLE POLICY and DEFAULTS.
-- MQ2WebUpdate.dll should provide generic deployment capabilities and should
-- not hard-code Triune repository layouts, branches, package locations, or
-- other values that can reasonably change in the future.
--
-- Keep this file Lua 5.1 compatible.
--
-- IMPORTANT:
--   * This file must not perform an update when it is loaded.
--   * User-specific overrides should eventually live outside this shipped
--     defaults file so normal updates do not erase user choices.
--   * Destructive cleanup must always be explicit.
--   * Remote paths are data. The deployment engine must validate all local
--     destinations and must never permit path traversal outside allowed roots.

local config = {}

---------------------------------------------------------------------------
-- CONFIGURATION SCHEMA
---------------------------------------------------------------------------

config.schema = {
    name = 'NeroMorte MQ2WebUpdate Configuration',
    version = 4,

    -- Future loaders may use these to reject a configuration that requires
    -- capabilities unavailable in an older updater engine.
    minimumEngineVersion = '4.0.0',
}

---------------------------------------------------------------------------
-- SOURCE PROFILES
--
-- A source describes WHERE an installation/update comes from.
-- Switching source must be treated as a planned source migration rather
-- than blindly overlaying one repository on another.
---------------------------------------------------------------------------

config.sources = {
    morte = {
        id = 'morte',
        name = 'NeroMorte',

        provider = 'github',
        owner = 'XxNeroMortexX',
        repository = 'TriuneAutocombat',

        -- ref may be a branch, tag, or commit understood by the provider.
        ref = 'main',

        -- Optional release/update channel information.
        channel = 'stable',

        -- Paths are intentionally configurable. Do not hard-code these into
        -- MQ2WebUpdate.dll.
        versionSource = {
            type = 'file',
            remote = 'TAC/lua/TAC_support_modules/morte_version.lua',
        },

        manifestSource = {
            type = 'file',
            remote = 'TAC/update_manifest.lua',
            optional = true,
        },
    },

    gennro = {
        id = 'gennro',
        name = 'Gennro Official',

        provider = 'github',
        owner = 'gennro',
        repository = 'TriuneAutocombat',
        ref = 'main',
        channel = 'stable',

        -- Exact upstream version discovery method may be changed later
        -- without requiring an MQ2WebUpdate.dll rebuild.
        versionSource = {
            type = 'lua_source',
            remote = 'TAC/lua/triune.lua',
            optional = false,
        },

        manifestSource = {
            type = 'file',
            remote = 'TAC/update_manifest.lua',
            optional = true,
        },
    },
}

---------------------------------------------------------------------------
-- DEFAULT SOURCE / SOURCE SWITCHING
---------------------------------------------------------------------------

config.sourceSelection = {
    defaultSource = 'morte',

    allowSwitching = true,

    -- MQ2WebUpdate 3.1 owns validation and atomic persistence. The GUI calls
    -- /webupdate profile <id>; users never need to edit the settings INI.
    backendManaged = true,
    trustedProfilesOnly = true,
    persistent = true,

    -- Always calculate/show the deployment plan before changing sources.
    requirePlanBeforeSwitch = true,

    -- Never infer deletion simply because a file does not exist in the
    -- newly selected source.
    deleteUnmanagedFilesOnSwitch = false,

    preserveUserOverrides = true,
}

---------------------------------------------------------------------------
-- LOCAL INSTALLATION ROOTS
--
-- These are symbolic roots. The engine/Lua controller will resolve them
-- from MacroQuest at runtime rather than assuming a drive letter.
---------------------------------------------------------------------------

config.roots = {
    mq = {
        type = 'macroquest_root',
    },

    lua = {
        type = 'mq_subdirectory',
        parent = 'mq',
        path = 'lua',
    },

    plugins = {
        type = 'mq_subdirectory',
        parent = 'mq',
        path = 'plugins',
    },

    config = {
        type = 'mq_subdirectory',
        parent = 'mq',
        path = 'config',
    },

    stage = {
        type = 'mq_subdirectory',
        parent = 'mq',
        path = 'webupdate_stage',
    },

    backup = {
        type = 'mq_subdirectory',
        parent = 'mq',
        path = 'webupdate_backup',
    },
}

---------------------------------------------------------------------------
-- DEPLOYMENT MAPPINGS
--
-- These describe remote -> local deployment.
-- Future directory changes should normally require changing this table,
-- not recompiling MQ2WebUpdate.dll.
---------------------------------------------------------------------------

config.mappings = {
    {
        id = 'triune_lua',

        source = 'selected',
        type = 'tree',

        remote = 'TAC/lua',
        destinationRoot = 'lua',
        destination = '',

        recursive = true,
        required = true,

        include = {
            '**',
        },

        exclude = {
            -- User/generated data can be excluded here if future layouts
            -- place it inside a managed source tree.
        },
    },

    {
        id = 'triune_resources',

        source = 'selected',
        type = 'tree',

        remote = 'TAC/resources',
        destinationRoot = 'mq',
        destination = 'resources',

        recursive = true,
        required = false,

        include = {
            '**',
        },

        exclude = {},
    },
}

---------------------------------------------------------------------------
-- PAYLOADS / PACKAGES
--
-- Payload support is deliberately generic. A payload may be an individual
-- file, DLL/MQ plugin, ZIP/archive, or another supported package type.
---------------------------------------------------------------------------

config.payloads = {
    {
        id = 'mq2webupdate',

        source = 'morte',
        type = 'mq_plugin',

        remote = 'MQ2WebUpdate/MQ2WebUpdate.dll',

        destinationRoot = 'plugins',
        destination = 'MQ2WebUpdate.dll',

        pluginName = 'MQ2WebUpdate',

        required = true,
        selfUpdate = true,

        lifecycle = {
            stopDependents = true,
            unloadBeforeReplace = true,
            confirmUnloaded = true,

            backupBeforeReplace = true,

            loadAfterReplace = true,
            confirmLoaded = true,

            rollbackOnFailure = true,
        },

        verification = {
            requirePE = true,
            sha256 = 'remote_manifest',
        },
    },

    -- Example capability definition retained as disabled configuration.
    -- It demonstrates that ZIP/package deployment does not require a new
    -- C++ design when we need it later.
    {
        id = 'example_zip_package',

        enabled = false,

        source = 'morte',
        type = 'zip',

        remote = 'packages/example.zip',

        required = false,

        verification = {
            sha256 = 'remote_manifest',
        },

        extraction = {
            stageOnly = true,
            rejectPathTraversal = true,
            rejectAbsolutePaths = true,
            rejectUnsafeLinks = true,

            stripComponents = 0,

            source = '',
            destinationRoot = 'mq',
            destination = '',
        },
    },
}

---------------------------------------------------------------------------
-- PROTECTED / USER-OWNED PATHS
--
-- Protected paths must not be replaced or removed by ordinary repository
-- synchronization. More specific migration logic can be introduced later
-- when intentionally required.
---------------------------------------------------------------------------

config.protection = {
    enabled = true,

    paths = {
        'config/**',
    },

    -- Never follow a reparse point/symlink/junction outside an approved
    -- deployment root.
    rejectUnsafeReparseTargets = true,
}

---------------------------------------------------------------------------
-- CLEANUP / MIGRATIONS
--
-- NO implicit "remote disappeared, therefore delete local" behavior.
-- Every destructive cleanup operation must be explicitly listed.
---------------------------------------------------------------------------

config.cleanup = {
    implicitDelete = false,

    obsoleteFiles = {
    },

    obsoleteDirectories = {
    },

    renames = {
        -- Example:
        -- {
        --     fromRoot = 'lua',
        --     from = 'old_name.lua',
        --     toRoot = 'lua',
        --     to = 'new_name.lua',
        -- }
    },
}

---------------------------------------------------------------------------
-- DOWNLOAD / PROVIDER BEHAVIOR
---------------------------------------------------------------------------

config.download = {
    httpsOnly = true,

    connectTimeoutMs = 15000,
    transferTimeoutMs = 60000,

    retries = 3,
    retryDelayMs = 1000,

    github = {
        recursiveTree = true,

        -- Critical rule learned from the old updater:
        -- GitHub tree entries MUST be filtered by their explicit type.
        acceptedTreeTypes = {
            blob = true,
        },

        ignoredTreeTypes = {
            tree = true,
            commit = true,
        },
    },

    directHttps = {
        enabled = true,
    },

    githubReleaseAssets = {
        enabled = true,
    },
}

---------------------------------------------------------------------------
-- VERIFICATION
---------------------------------------------------------------------------

config.verification = {
    hashAlgorithm = 'sha256',

    verifyDownloads = true,
    verifyStagedFiles = true,
    verifyInstalledFiles = true,

    rejectEmptyRequiredFiles = true,

    -- When an expected hash/size is supplied by trusted release metadata,
    -- require it to match.
    enforceExpectedHash = true,
    enforceExpectedSize = true,
}

---------------------------------------------------------------------------
-- TRANSACTION / STAGING / BACKUP / ROLLBACK
---------------------------------------------------------------------------

config.transaction = {
    enabled = true,

    uniqueTransactionDirectories = true,
    writeTransactionManifest = true,

    stageEverythingBeforeApply = true,
    verifyEverythingBeforeApply = true,

    backupBeforeModification = true,

    rollbackOnFailure = true,
    verifyRollback = true,

    detectInterruptedTransaction = true,
    recoverInterruptedTransaction = true,

    cleanupSuccessfulTransaction = true,

    staleTransactionAgeHours = 72,

    phases = {
        'plan',
        'download',
        'verify',
        'stage',
        'stop',
        'backup',
        'apply',
        'verify_live',
        'restart',
        'commit',
        'cleanup',
    },
}

---------------------------------------------------------------------------
-- LUA / SCRIPT LIFECYCLE
---------------------------------------------------------------------------

config.lua = {
    stopBeforeApply = {
        'triune',
    },

    startAfterApply = {
        'triune',
    },

    stopTimeoutMs = 10000,
    startTimeoutMs = 15000,

    -- Lua syntax checking may be performed when a compatible checker is
    -- available. The updater must not assume an external luac path exists
    -- on every user's machine.
    syntaxValidation = {
        enabled = true,
        required = false,
    },
}

---------------------------------------------------------------------------
-- MQ PLUGIN / DLL LIFECYCLE
---------------------------------------------------------------------------

config.plugins = {
    unloadTimeoutMs = 10000,
    loadTimeoutMs = 15000,

    verifyDiskAfterReplace = true,
    verifyLoadedAfterReplace = true,

    rollbackAndReloadPreviousOnFailure = true,
}

---------------------------------------------------------------------------
-- ARCHIVES
---------------------------------------------------------------------------

config.archives = {
    zip = {
        enabled = true,

        extractToStageOnly = true,

        rejectPathTraversal = true,
        rejectAbsolutePaths = true,
        rejectUnsafeLinks = true,

        maxEntries = 100000,

        -- 0 means no policy limit has been chosen yet. The implementation
        -- may still impose a safe hard ceiling.
        maxExpandedBytes = 0,
    },
}

---------------------------------------------------------------------------
-- VERSION STATUS
--
-- Keep Gennro, NeroMorte, and the updater engine as separate identities.
---------------------------------------------------------------------------

config.versions = {
    gennro = {
        displayName = 'Gennro',
        localMethod = 'triune_core',
        remoteSource = 'gennro',
    },

    morte = {
        displayName = 'NeroMorte',
        localMethod = 'morte_version_file',
        remoteSource = 'morte',
    },

    engine = {
        displayName = 'MQ2WebUpdate',
        localMethod = 'plugin_api',
        remoteSource = 'morte',
    },
}

---------------------------------------------------------------------------
-- UPDATE MANAGER UI POLICY
---------------------------------------------------------------------------

config.ui = {
    showGennro = true,
    showMorte = true,
    showEngine = true,

    showInstalledVersion = true,
    showRemoteVersion = true,
    showMorteBaseGennroVersion = true,

    showSource = true,
    showBranch = true,
    showCommit = true,

    allowCheckGennro = true,
    allowCheckMorte = true,

    allowSwitchToGennro = true,
    allowSwitchToMorte = true,

    showPlanBeforeUpdate = true,
    showPlanBeforeSourceSwitch = true,

    enableRepair = true,
    enableDryRun = true,
}

---------------------------------------------------------------------------
-- DIAGNOSTICS / LOGGING
---------------------------------------------------------------------------

config.diagnostics = {
    level = 1,

    logPlan = true,
    logDownloads = true,
    logVerification = true,
    logFileOperations = true,
    logRollback = true,

    retainLastPlan = true,
    retainLastError = true,
}

---------------------------------------------------------------------------
-- USER OVERRIDE
--
-- The shipped defaults above may be updated with NeroMorte releases.
-- A later loader will optionally merge a separate user-owned override file.
-- That override must not be overwritten during normal updates.
---------------------------------------------------------------------------

config.userOverride = {
    enabled = true,

    root = 'config',
    path = 'neromorte_update.lua',

    optional = true,
}

return config
