# Created By: NeroMorte - Verify links, back up, and switch to the isolated water/air movement test branch.
# In EVERY running client, use /lua stop triune before executing this script.
param(
    [Parameter(Mandatory = $true)][string]$Revision,
    [string]$Dev = 'E:\MQ2Next\TriuneAutocombat',
    [string]$RuntimeLua = 'E:\MQ2Next\macroquest\build\bin\release\lua',
    [string]$BackupRoot = 'E:\MQ2Next\TriuneGUIBackups'
)
$ErrorActionPreference = 'Stop'
$Branch = 'nero/nav-integration-test'
if ($Revision -notmatch '^[0-9a-f]{40}$') { throw 'Supply the exact test commit SHA.' }
$Remote = git -C $Dev remote get-url origin
if ($LASTEXITCODE -ne 0 -or $Remote -notmatch '(?i)github\.com[:/]XxNeroMortexX/TriuneAutocombat(?:\.git)?/?$') {
    throw 'origin does not point to the expected Triune fork.'
}
git -C $Dev diff --quiet
if ($LASTEXITCODE -ne 0) { throw 'Tracked working files have changes; stopped. No stash or reset was used.' }
git -C $Dev diff --cached --quiet
if ($LASTEXITCODE -ne 0) { throw 'There are staged changes; stopped.' }
$BeforeBranch = git -C $Dev branch --show-current
if ($LASTEXITCODE -ne 0 -or $BeforeBranch -notin @('main', 'nero/trash-mode-test', 'nero/chase-water-test', $Branch)) { throw 'Start on main, the Trash Mode test branch, or the water/air movement test branch.' }
$BeforeCommit = git -C $Dev rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot read current HEAD.' }
git -C $Dev fetch origin $Branch
if ($LASTEXITCODE -ne 0) { throw 'Cannot fetch the test branch.' }
$Fetched = git -C $Dev rev-parse FETCH_HEAD
if ($LASTEXITCODE -ne 0 -or $Fetched -ne $Revision) { throw 'Remote test branch changed; get the current installation instructions.' }
git -C $Dev merge-base --is-ancestor $BeforeCommit $Revision
if ($LASTEXITCODE -ne 0) { throw 'Current checkout is not an ancestor of this test; stopped.' }

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
# Edited By: NeroMorte - Include updater support and the Nav completion adapter in link verification/backups.
$Files = @('TAC/lua/triune.lua', 'TAC/lua/tac/buffbot.lua', 'TAC/lua/tac/auto_aa.lua',
    'TAC/lua/tac/update_manager.lua', 'TAC/lua/TAC_support_modules/update_config.lua',
    'TAC/lua/TAC_support_modules/morte_version.lua', 'TAC/lua/TAC_support_modules/nav_xyz_completion.lua',
    'TAC/lua/TAC_support_modules/nav_update_policy.lua', 'TAC/lua/TAC_support_modules/nav_plugin_release.lua')
$NewLinks = @()
$CreatedLinks = @()
$Links = @()
foreach ($Relative in $Files) {
    $Dest = Join-Path $Dev $Relative
    $Live = Join-Path $RuntimeLua $Relative.Substring('TAC/lua/'.Length)
    $Linked = $false
    # Edited By: NeroMorte - A linked support directory exposes new files automatically.
    # Otherwise create only missing individual links after the branch switch.
    if (!(Test-Path -LiteralPath $Live)) {
        $Parent = Split-Path -Parent $Live
        $ResolvedParent = Resolve-LinkPath $Parent ([ref]$Linked)
        if ($Linked -and $ResolvedParent -ieq (Split-Path -Parent $Dest)) {
            $Resolved = [IO.Path]::GetFullPath($Dest)
        } elseif (!$Linked -and $Relative -match '/nav_(xyz_completion|update_policy|plugin_release)\.lua$') {
            if (Get-Item -LiteralPath $Live -Force -ErrorAction SilentlyContinue) { throw "Existing dangling link: $Live" }
            $NewLinks += [pscustomobject]@{ Live=$Live; Dest=$Dest }
            $Resolved = [IO.Path]::GetFullPath($Dest); $Linked = $true
        } else { throw "Missing runtime link: $Live" }
    } else { $Resolved = Resolve-LinkPath $Live ([ref]$Linked) }
    if (!$Linked -or $Resolved -ine [IO.Path]::GetFullPath($Dest)) {
        throw "Runtime does not link to the expected development file: $Live -> $Resolved"
    }
    $Links += [pscustomobject]@{ Relative = $Relative; Live = $Live; Resolved = $Resolved }
}
$LocalTest = $null
git -C $Dev show-ref --verify --quiet "refs/heads/$Branch"
if ($LASTEXITCODE -eq 0) { $LocalTest = git -C $Dev rev-parse "refs/heads/$Branch" }
if ($LocalTest) {
    git -C $Dev merge-base --is-ancestor $LocalTest $Revision
    if ($LASTEXITCODE -ne 0) { throw 'Existing test branch diverged; stopped without resetting it.' }
}
$Backup = Join-Path $BackupRoot ('water-chase-test-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $Backup -Force | Out-Null
foreach ($Relative in $Files) {
    $Copy = Join-Path $Backup $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $Copy) -Force | Out-Null
    if (Test-Path -LiteralPath (Join-Path $Dev $Relative)) { Copy-Item -LiteralPath (Join-Path $Dev $Relative) -Destination $Copy }
}
[pscustomobject]@{ BeforeBranch = $BeforeBranch; BeforeCommit = $BeforeCommit; TestCommit = $Revision; Links = $Links; NewLinks = $NewLinks } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Backup 'restore-info.json') -Encoding UTF8
# Save canonical source bytes for inspection even with Windows CRLF checkout conversion.
git -c core.autocrlf=false -c core.eol=lf -C $Dev archive --format=zip "--output=$(Join-Path $Backup 'test-source.zip')" $Revision -- @Files
if ($LASTEXITCODE -ne 0) { throw 'Could not save the test archive; live files remain unchanged.' }
try {
    if ($LocalTest) {
        git -C $Dev switch $Branch
        if ($LASTEXITCODE -ne 0) { throw 'Test branch switch failed.' }
        git -C $Dev merge --ff-only --no-edit $Revision
    }
    else { git -C $Dev switch -c $Branch --track "origin/$Branch" }
    if ($LASTEXITCODE -ne 0) { throw 'Test branch switch failed.' }
    if ((git -C $Dev rev-parse HEAD) -ne $Revision) { throw 'HEAD verification failed.' }
    # Edited By: NeroMorte - Preserve existing links; create only the missing support-module links.
    foreach ($Entry in $NewLinks) {
        New-Item -ItemType SymbolicLink -Path $Entry.Live -Target $Entry.Dest | Out-Null
        $CreatedLinks += $Entry.Live
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
    foreach ($Live in $CreatedLinks) { Remove-Item -LiteralPath $Live -Force }
    if ($BeforeBranch -eq $Branch -and (git -C $Dev rev-parse HEAD) -ne $BeforeCommit) {
        $RollbackBranch = 'nero/water-chase-rollback-' + [guid]::NewGuid().ToString('N').Substring(0,8)
        git -C $Dev switch -c $RollbackBranch $BeforeCommit
    } else { git -C $Dev switch $BeforeBranch }
    if ($LASTEXITCODE -ne 0) { throw "Install failed and rollback failed. Triune must stay stopped. Backup: $Backup. $Reason" }
    throw "Install failed; previous branch restored. Backup: $Backup. $Reason"
}
Write-Host "Verified water/air movement test: $Revision"
Write-Host "Backups: $Backup"
Write-Host 'Existing Lua links and untracked updater files were preserved. No stash was applied.'
Write-Host 'Now start Triune in game with /lua run triune. Trash Mode starts OFF.'
if ($BeforeBranch -eq $Branch -and $BeforeCommit -ne $Revision) {
    $RollbackBranch = 'nero/water-chase-rollback-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    Write-Host "To roll back: stop Triune in every client, then git -C '$Dev' switch -c '$RollbackBranch' '$BeforeCommit'"
} else { Write-Host "To roll back: stop Triune in every client, then git -C '$Dev' switch '$BeforeBranch'" }
