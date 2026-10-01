# Created By: NeroMorte - Back up and install only the pet-camp test Lua files through dev links.
# Stop Triune with /lua stop triune BEFORE running this script. No plugin/DLL changes.
param(
    [Parameter(Mandatory = $true)][string]$Revision,
    [string]$Dev = 'E:\MQ2Next\TriuneAutocombat',
    [string]$RuntimeLua = 'E:\MQ2Next\macroquest\build\bin\release\lua',
    [string]$BackupRoot = 'E:\MQ2Next\TriuneGUIBackups'
)
$ErrorActionPreference = 'Stop'
if (!(Test-Path -LiteralPath $Dev -PathType Container)) { throw "Missing dev folder: $Dev" }
if (!(Test-Path -LiteralPath $RuntimeLua -PathType Container)) { throw "Missing runtime Lua folder: $RuntimeLua" }
if ($Revision -notmatch '^[0-9a-f]{40}$') { throw 'Use the exact 40-character test commit SHA.' }
$Remote = git -C $Dev remote get-url origin
if ($LASTEXITCODE -ne 0 -or $Remote -notmatch '(?i)github\.com[:/]XxNeroMortexX/TriuneAutocombat(?:\.git)?/?$') {
    throw 'origin does not point to the expected Triune fork; stopped.'
}
git -C $Dev cat-file -e "$Revision`^{commit}"
if ($LASTEXITCODE -ne 0) { throw 'Fetch nero/pet-camp-controls first; the requested commit is unavailable.' }
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Backup = Join-Path $BackupRoot "pet-camp-test-$Stamp-$([guid]::NewGuid().ToString('N').Substring(0,6))"
New-Item -ItemType Directory -Path $Backup -Force | Out-Null
$Archive = Join-Path $Backup 'test-source.zip'
$Candidate = Join-Path $Backup 'candidate'
$Files = @('TAC/lua/TAC_support_modules/pet_camp_controller.lua', 'TAC/lua/triune.lua', 'TAC/lua/tac/auto_aa.lua')
# Preserve canonical blob bytes even when the Windows checkout uses core.autocrlf=true.
git -c core.autocrlf=false -c core.eol=lf -C $Dev archive --format=zip "--output=$Archive" $Revision -- @Files
if ($LASTEXITCODE -ne 0) { throw 'Could not extract the exact test files; live files were not changed.' }
Expand-Archive -LiteralPath $Archive -DestinationPath $Candidate
$Plan = @()
foreach ($Relative in $Files) {
    $Source = Join-Path $Candidate $Relative
    $Dest = Join-Path $Dev $Relative
    $RuntimeRelative = $Relative.Substring('TAC/lua/'.Length)
    $Link = Join-Path $RuntimeLua $RuntimeRelative
    $ExpectedBlob = git -C $Dev rev-parse "$Revision`:$Relative"
    if ($LASTEXITCODE -ne 0) { throw "Missing commit file: $Relative" }
    $ActualBlob = git -C $Dev hash-object --no-filters $Source
    if ($LASTEXITCODE -ne 0 -or $ActualBlob -ne $ExpectedBlob) { throw "Candidate verification failed: $Relative" }
    $ExistingDev = Get-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue
    if ($ExistingDev -and $ExistingDev.PSIsContainer) { throw "Dev file is a directory: $Dest" }
    if ($ExistingDev -and ($ExistingDev.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Dev file is a link; stopped before edits: $Dest"
    }
    $Existing = Get-Item -LiteralPath $Link -Force -ErrorAction SilentlyContinue
    $WasLink = $Existing -and ($Existing.Attributes -band [IO.FileAttributes]::ReparsePoint)
    if ($WasLink) {
        if ($Existing.LinkType -ne 'SymbolicLink') { throw "Unexpected link type: $Link" }
        $Target = [string](@($Existing.Target)[0])
        if (![IO.Path]::IsPathRooted($Target)) { $Target = Join-Path (Split-Path -Parent $Link) $Target }
        if ([IO.Path]::GetFullPath($Target) -ine [IO.Path]::GetFullPath($Dest)) {
            throw "Runtime link points elsewhere; stopped before edits: $Link -> $Target"
        }
    }
    $DevBackup = Join-Path (Join-Path $Backup 'before-dev') $Relative
    $RuntimeBackup = Join-Path (Join-Path $Backup 'before-runtime') $RuntimeRelative
    if ($ExistingDev) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $DevBackup) -Force | Out-Null
        Copy-Item -LiteralPath $Dest -Destination $DevBackup
    }
    if ($Existing -and !$WasLink) {
        if ($Existing.PSIsContainer) { throw "Runtime file is a directory: $Link" }
        New-Item -ItemType Directory -Path (Split-Path -Parent $RuntimeBackup) -Force | Out-Null
        Copy-Item -LiteralPath $Link -Destination $RuntimeBackup
    }
    $Plan += [pscustomobject]@{ Relative = $Relative; Source = $Source; Dest = $Dest; Link = $Link;
        HadDev = [bool]$ExistingDev; HadRuntime = [bool]$Existing; WasLink = [bool]$WasLink;
        DevBackup = $DevBackup; RuntimeBackup = $RuntimeBackup }
}
$Plan | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $Backup 'restore-plan.json') -Encoding UTF8
try {
    foreach ($Entry in $Plan) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $Entry.Dest) -Force | Out-Null
        Copy-Item -LiteralPath $Entry.Source -Destination $Entry.Dest -Force
        if (!$Entry.WasLink) {
            if ($Entry.HadRuntime) { Remove-Item -LiteralPath $Entry.Link -Force }
            New-Item -ItemType Directory -Path (Split-Path -Parent $Entry.Link) -Force | Out-Null
            New-Item -ItemType SymbolicLink -Path $Entry.Link -Target $Entry.Dest | Out-Null
        }
        $ExpectedHash = (Get-FileHash -LiteralPath $Entry.Source -Algorithm SHA256).Hash
        if ((Get-FileHash -LiteralPath $Entry.Link -Algorithm SHA256).Hash -ne $ExpectedHash) {
            throw "Runtime verification failed: $($Entry.Link)"
        }
        Write-Host "INSTALLED THROUGH LINK: $($Entry.Relative)"
    }
} catch {
    $Failure = $_
    foreach ($Entry in $Plan) {
        if ($Entry.HadDev) { Copy-Item -LiteralPath $Entry.DevBackup -Destination $Entry.Dest -Force }
        elseif (Test-Path -LiteralPath $Entry.Dest) { Remove-Item -LiteralPath $Entry.Dest -Force }
        if (!$Entry.WasLink) {
            $Current = Get-Item -LiteralPath $Entry.Link -Force -ErrorAction SilentlyContinue
            if ($Current) { Remove-Item -LiteralPath $Entry.Link -Force }
            if ($Entry.HadRuntime) { Copy-Item -LiteralPath $Entry.RuntimeBackup -Destination $Entry.Link -Force }
        }
    }
    throw "Install failed; restored previous Lua files. Backup: $Backup. Reason: $Failure"
}
Write-Host "PET CAMP TEST READY: $Revision"
Write-Host "Backup: $Backup"
Write-Host 'Run /lua run triune in game. Open Pets while safely idle to capture states.'
Write-Host 'Then use Puller > Camp > Pet: Pets Pull - Player Stay in Camp, Player Assist Radius, and optional Pet Pull Back to Camp.'
