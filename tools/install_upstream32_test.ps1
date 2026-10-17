# Created By: NeroMorte - Install the isolated Gennro 3.2 integration test without replacing settings or Lua links.
# In EVERY running client, use /lua stop triune before executing this script.
param(
    [Parameter(Mandatory = $true)][string]$Revision,
    [string]$Dev = 'E:\MQ2Next\TriuneAutocombat',
    [string]$RuntimeLua = 'E:\MQ2Next\macroquest\build\bin\release\lua',
    [string]$Config = 'E:\MQ2Next\macroquest\build\bin\release\config',
    [string]$BackupRoot = 'E:\MQ2Next\TriuneGUIBackups'
)
$ErrorActionPreference = 'Stop'
$Branch = 'nero/upstream-3.2-test'
$Base = 'c5fcdbd534452f0f160448b0b7e049bc5fe680cc'
if ($Revision -notmatch '^[0-9a-f]{40}$') { throw 'Supply the exact test commit SHA.' }
$Remote = git -C $Dev remote get-url origin
if ($LASTEXITCODE -ne 0 -or $Remote -notmatch '(?i)github\.com[:/]XxNeroMortexX/TriuneAutocombat(?:\.git)?/?$') {
    throw 'origin does not point to the expected Triune fork.'
}
# Edited By: NeroMorte - Preserve the runtime-edited config; block every other tracked modification.
$Changed = @(git -C $Dev diff --name-only)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect tracked working changes.' }
$Blocked = @($Changed | Where-Object { $_ -ne 'TAC/config/ingame.cfg' })
if ($Blocked.Count) { throw "Tracked source changes found: $($Blocked -join ', '). No stash or reset was used." }
$IngamePath = Join-Path $Dev 'TAC/config/ingame.cfg'
$IngameBefore = $null
if (Test-Path -LiteralPath $IngamePath -PathType Leaf) {
    $IngameBefore = (Get-FileHash -LiteralPath $IngamePath -Algorithm SHA256).Hash
}
git -C $Dev diff --cached --quiet
if ($LASTEXITCODE -ne 0) { throw 'There are staged changes; stopped.' }
$BeforeBranch = git -C $Dev branch --show-current
if ($LASTEXITCODE -ne 0 -or $BeforeBranch -notin @('main', 'nero/flag-tracker-hud-test', $Branch)) { throw 'Start on main, nero/flag-tracker-hud-test, or nero/upstream-3.2-test.' }
$BeforeCommit = git -C $Dev rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot read current HEAD.' }
git -C $Dev fetch origin $Branch
if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch the test branch.' }
$Fetched = git -C $Dev rev-parse FETCH_HEAD
if ($LASTEXITCODE -ne 0 -or $Fetched -ne $Revision) { throw 'Remote test branch changed; get the current installation instructions.' }
git -C $Dev merge-base --is-ancestor $Base $Revision
if ($LASTEXITCODE -ne 0) { throw 'Test revision does not include the reviewed main base; stopped.' }

# Resolve file OR parent-directory links. This supports individually linked Lua and linked tac directories.
function Resolve-LinkPath([string]$Path, [ref]$Linked, [int]$Depth = 0) {
    if ($Depth -gt 40) { throw 'Link resolution exceeded its safety limit.' }
    $Full = [IO.Path]::GetFullPath($Path)
    $Item = Get-Item -LiteralPath $Full -Force
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($Item.LinkType -notin @('SymbolicLink', 'Junction')) { throw "Unsupported link: $Full" }
        $Linked.Value = $true
        $Target = [string](@($Item.Target)[0])
        if (!$Target) { throw "Unreadable link target: $Full" }
        if (![IO.Path]::IsPathRooted($Target)) { $Target = Join-Path (Split-Path -Parent $Full) $Target }
        return Resolve-LinkPath $Target $Linked ($Depth + 1)
    }
    $Parent = Split-Path -Parent $Full
    if (!$Parent -or $Parent -eq $Full) { return $Full }
    $ResolvedParent = Resolve-LinkPath $Parent $Linked ($Depth + 1)
    return [IO.Path]::GetFullPath((Join-Path $ResolvedParent (Split-Path -Leaf $Full)))
}
# Edited By: NeroMorte - Verify every changed Lua file, not only the core.
$Files = @(git -C $Dev diff --name-only $Base $Revision -- TAC/lua)
if ($LASTEXITCODE -ne 0 -or !$Files.Count) { throw 'Cannot read changed Lua files.' }
$NewPlugin = 'TAC/lua/tac/gm_commands.lua'
$NewPluginLive = Join-Path $RuntimeLua 'tac/gm_commands.lua'
$NewPluginSource = Join-Path $Dev $NewPlugin
$Links = @()
foreach ($Relative in $Files) {
    $Dest = Join-Path $Dev $Relative
    $Live = Join-Path $RuntimeLua $Relative.Substring('TAC/lua/'.Length)
    # The new GM plugin may not exist on the previous branch.
    if ($Relative -eq $NewPlugin -and !(Test-Path -LiteralPath $Live)) { continue }
    $Linked = $false
    $Resolved = Resolve-LinkPath $Live ([ref]$Linked)
    if (!$Linked -or $Resolved -ine [IO.Path]::GetFullPath($Dest)) {
        throw "Runtime does not link to the expected development file: $Live -> $Resolved"
    }
    $Links += [pscustomobject]@{ Relative = $Relative; Live = $Live; Resolved = $Resolved }
}
$LocalTest = $null
git -C $Dev show-ref --verify --quiet "refs/heads/$Branch"
if ($LASTEXITCODE -eq 0) { $LocalTest = git -C $Dev rev-parse "refs/heads/$Branch" }
# Edited By: NeroMorte - Permit reviewed test revisions through fast-forward only.
if ($LocalTest -and $LocalTest -ne $Revision) {
    git -C $Dev merge-base --is-ancestor $LocalTest $Revision
    if ($LASTEXITCODE -ne 0) { throw 'Existing test branch diverges; stopped without resetting it.' }
}
$Backup = Join-Path $BackupRoot ('upstream-3.2-test-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $Backup -Force | Out-Null
# Edited By: NeroMorte - Back up the runtime config without replacing its local changes.
if ($IngameBefore) { Copy-Item -LiteralPath $IngamePath -Destination (Join-Path $Backup 'ingame.cfg.before') }
# Created By: NeroMorte - Preserve per-character settings before testing AA and radius controls.
if (Test-Path -LiteralPath $Config) {
    $ConfigBackup = Join-Path $Backup 'config'
    New-Item -ItemType Directory -Path $ConfigBackup -Force | Out-Null
    Get-ChildItem -LiteralPath $Config -Filter 'triune_loadout*.lua' -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $ConfigBackup
    }
}
[pscustomobject]@{ BeforeBranch = $BeforeBranch; BeforeCommit = $BeforeCommit; TestCommit = $Revision; Links = $Links } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Backup 'restore-info.json') -Encoding UTF8
try {
    if ($LocalTest) { git -C $Dev switch $Branch }
    else { git -C $Dev switch -c $Branch --track "origin/$Branch" }
    if ($LASTEXITCODE -ne 0) { throw 'Test branch switch failed.' }
    git -C $Dev merge --ff-only $Revision
    if ($LASTEXITCODE -ne 0) { throw 'Test branch fast-forward failed.' }
    if ((git -C $Dev rev-parse HEAD) -ne $Revision) { throw 'HEAD verification failed.' }
    # Existing directory links expose the new plugin automatically; otherwise add one file link.
    if (!(Test-Path -LiteralPath $NewPluginLive)) {
        $Existing = Get-Item -LiteralPath $NewPluginLive -Force -ErrorAction SilentlyContinue
        if ($Existing) { throw 'GM plugin path already exists but its target is unavailable.' }
        New-Item -ItemType SymbolicLink -Path $NewPluginLive -Target $NewPluginSource | Out-Null
    }
    if (!($Links | Where-Object { $_.Relative -eq $NewPlugin })) {
        $Links += [pscustomobject]@{ Relative = $NewPlugin; Live = $NewPluginLive; Resolved = [IO.Path]::GetFullPath($NewPluginSource) }
    }
    if ($IngameBefore -and (Get-FileHash -LiteralPath $IngamePath -Algorithm SHA256).Hash -ne $IngameBefore) {
        throw 'Runtime ingame.cfg changed during installation; stopped.'
    }
    foreach ($Entry in $Links) {
        $Linked = $false
        $Resolved = Resolve-LinkPath $Entry.Live ([ref]$Linked)
        if (!$Linked -or $Resolved -ine $Entry.Resolved) { throw "Link changed: $($Entry.Live)" }
        $Expected = git -C $Dev rev-parse "$Revision`:$($Entry.Relative)"
        if ($LASTEXITCODE -ne 0) { throw 'Cannot read expected blob.' }
        $Actual = git -C $Dev hash-object "--path=$($Entry.Relative)" $Entry.Live
        if ($LASTEXITCODE -ne 0 -or $Actual -ne $Expected) { throw "Live file verification failed: $($Entry.Live)" }
    }
} catch {
    $Reason = $_
    if ($BeforeBranch -eq $Branch) { git -C $Dev switch --detach $BeforeCommit }
    else { git -C $Dev switch $BeforeBranch }
    if ($LASTEXITCODE -ne 0) { throw "Install failed and rollback failed. Triune must stay stopped. Backup: $Backup. $Reason" }
    throw "Install failed; previous branch restored. Backup: $Backup. $Reason"
}
Write-Host "Verified Gennro 3.2 / Morte.11-test: $Revision"
Write-Host "Backups: $Backup"
Write-Host 'Existing Lua links, ingame.cfg and untracked updater files were preserved. No stash was applied.'
Write-Host 'Flag Tracker/HUD remain on their separate test branch; this checkout does not include them.'
Write-Host 'The strict MA Attack On option is not part of this integration yet.'
Write-Host 'Now start Triune with /lua run triune. Check the 3.2 / Morte.11-test title, zone lists, Assist, Camp/Hunt, healing and Auto AA.'
Write-Host "To roll back: stop Triune in every client, then git -C '$Dev' switch --detach '$BeforeCommit'"

