# Created By: NeroMorte - build the MQ-root updater and install the verified quiet Go server.
# Stop Triune and unload MQ2WebUpdate in EVERY EQ client; stop either EQBC server before installing.
param(
    [Parameter(Mandatory=$true)][string]$Revision,
    [string]$Dev='E:\MQ2Next\TriuneAutocombat',
    [string]$MQ='E:\MQ2Next\macroquest'
)
$ErrorActionPreference='Stop'
$Branch='nero/eqbc-server-updater-test'
$Runtime=Join-Path $MQ 'build\bin\release'
$Updater=Join-Path $MQ 'plugins\MQ2WebUpdate'
$GoSource=Join-Path $MQ 'plugins\MQ2EQBCS-Go'
$Before=git -C $Dev rev-parse HEAD
if ($LASTEXITCODE -or $Revision -notmatch '^[0-9a-f]{40}$') { throw 'Invalid revision or checkout.' }
$BeforeBranch=git -C $Dev branch --show-current
if (!$BeforeBranch) { throw 'Start from a named branch.' }
$Origin=git -C $Dev remote get-url origin
if ($LASTEXITCODE -or $Origin -notmatch '(?i)github\.com[:/]XxNeroMortexX/TriuneAutocombat(?:\.git)?/?$') { throw 'Unexpected Triune origin.' }
git -C $Dev diff --quiet
if ($LASTEXITCODE) { throw 'Tracked edits exist; stopped without stashing.' }
git -C $Dev diff --cached --quiet
if ($LASTEXITCODE) { throw 'Staged edits exist; stopped.' }
git -C $Dev fetch origin $Branch
if ($LASTEXITCODE -or (git -C $Dev rev-parse FETCH_HEAD) -ne $Revision) { throw 'Remote branch changed; get current instructions.' }
git -C $Dev merge-base --is-ancestor $Before $Revision
if ($LASTEXITCODE) { throw 'Current checkout is not an ancestor; stopped.' }
$Tag=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$Backup=Join-Path $MQ ('plugins\MQ2EQBC\Backup\server-updater-'+$Tag)
$GoBackup=Join-Path $GoSource ('Backup\server-updater-'+$Tag)
$Build=Join-Path $MQ ('build\artifacts\server-updater-'+$Tag)
foreach ($Dir in @($Backup,$GoBackup,$Build)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
$Package=Join-Path $Build 'package'
New-Item -ItemType Directory -Path $Package | Out-Null
git -c core.autocrlf=false -c core.eol=lf -C $Dev archive --format=zip "--output=$Build\source.zip" $Revision -- EQBCServers MQ2WebUpdate TAC/lua/tac/update_manager.lua TAC/lua/TAC_support_modules/update_config.lua TAC/lua/TAC_support_modules/eqbc_server_defaults.lua TAC/lua/TAC_support_modules/eqbc_server_release.lua TAC/lua/TAC_support_modules/eqbc_server_update_policy.lua
if ($LASTEXITCODE) { throw 'Source archive failed; live files unchanged.' }
Expand-Archive -LiteralPath "$Build\source.zip" -DestinationPath $Package
function Assert-Unloaded {
    foreach ($Process in @(Get-Process eqgame -ErrorAction SilentlyContinue)) {
        try { $Modules=@($Process.Modules) } catch { throw "Cannot inspect EQ process $($Process.Id); run elevated or close that client." }
        if (!$Modules.Count) { throw "Cannot inspect EQ process $($Process.Id)." }
        if (@($Modules | Where-Object { $_.ModuleName -ieq 'MQ2WebUpdate.dll' }).Count) {
            throw "Unload MQ2WebUpdate in EQ process $($Process.Id) first."
        }
    }
    Write-Host 'Verified: MQ2WebUpdate is unloaded in every running EQ client.'
}
function Assert-Writable([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        $Stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $Stream.Close()
    }
}
function Canonical-Hash([string]$Path) {
    $Text=[IO.File]::ReadAllText($Path).Replace("`r`n","`n")
    $Algorithm=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($Algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $Algorithm.Dispose() }
}
function Resolve-Link([string]$Path,[ref]$Linked,[int]$Depth=0) {
    if ($Depth -gt 40) { throw 'Link resolution limit.' }
    $Full=[IO.Path]::GetFullPath($Path); $Item=Get-Item -LiteralPath $Full -Force
    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        if ($Item.LinkType -notin @('SymbolicLink','Junction')) { throw "Unsupported link: $Full" }
        $Linked.Value=$true; $Target=[string](@($Item.Target)[0])
        if (!$Target) { throw "Unreadable link: $Full" }
        if (![IO.Path]::IsPathRooted($Target)) { $Target=Join-Path (Split-Path -Parent $Full) $Target }
        return Resolve-Link $Target $Linked ($Depth+1)
    }
    $Parent=Split-Path -Parent $Full
    if (!$Parent -or $Parent -eq $Full) { return $Full }
    return [IO.Path]::GetFullPath((Join-Path (Resolve-Link $Parent $Linked ($Depth+1)) (Split-Path -Leaf $Full)))
}
Assert-Unloaded
$LiveDll=Join-Path $Runtime 'plugins\MQ2WebUpdate.dll'
foreach ($Path in @($LiveDll,(Join-Path $Runtime 'EQBCS.exe'),(Join-Path $Runtime 'EQBCS-Go.exe'))) { Assert-Writable $Path }
$VsWhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$MSBuild=& $VsWhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (!$MSBuild -or !(Test-Path -LiteralPath $MSBuild)) { throw 'Visual Studio MSBuild not found.' }
$Layout=Get-Content -LiteralPath "$Package\EQBCServers\source-layout.json" -Raw | ConvertFrom-Json
$SourceRecords=@()
foreach ($Entry in $Layout.files) {
    $Root=if ($Entry.group -eq 'go') {$GoSource} else {$Updater}
    $SaveRoot=if ($Entry.group -eq 'go') {$GoBackup} else {$Backup}
    $Path=Join-Path $Root $Entry.path
    $Exists=Test-Path -LiteralPath $Path
    if ($Exists) {
        $Hash=Canonical-Hash $Path
        if ($Hash -ne $Entry.base -and $Hash -ne $Entry.updated) { throw "Unreviewed local source changes: $Path. No files replaced." }
    } elseif ($Entry.base) { throw "Required source missing: $Path" }
    $SourceRecords += [pscustomobject]@{Path=$Path;Save=(Join-Path $SaveRoot $Entry.path);Existed=$Exists;Entry=$Entry}
}
$LuaPaths=@('tac/update_manager.lua','TAC_support_modules/update_config.lua','TAC_support_modules/eqbc_server_defaults.lua','TAC_support_modules/eqbc_server_release.lua','TAC_support_modules/eqbc_server_update_policy.lua')
$Links=@();$Created=@()
foreach ($Relative in $LuaPaths) {
    $Source=Join-Path $Dev ('TAC\lua\'+$Relative);$Live=Join-Path $Runtime ('lua\'+$Relative)
    if (Test-Path -LiteralPath $Live) {
        $Linked=$false;$Resolved=Resolve-Link $Live ([ref]$Linked)
        if (!$Linked -or $Resolved -ine [IO.Path]::GetFullPath($Source)) { throw "Runtime must link to development: $Live" }
    } elseif ($Relative -in @('tac/update_manager.lua','TAC_support_modules/update_config.lua')) { throw "Existing Lua link missing: $Live" }
    $Links += [pscustomobject]@{Source=$Source;Live=$Live;Relative=('TAC/lua/'+$Relative)}
}
$Release=Get-Content -LiteralPath "$Package\EQBCServers\release.json" -Raw | ConvertFrom-Json
foreach ($Item in $Release.payloads) {
    $Payload=Join-Path $Package ('EQBCServers\'+$Item.name)
    if ((Get-FileHash -LiteralPath $Payload).Hash -ine $Item.sha256) { throw "Payload hash mismatch: $($Item.name)" }
}
$RuntimeRecords=@()
foreach ($Name in @('plugins\MQ2WebUpdate.dll','EQBCS.exe','EQBCS-Go.exe','config\MQ2WebUpdate.ini','config\MQ2WebUpdate.profiles.ini')) {
    $Path=Join-Path $Runtime $Name;$Save=Join-Path $Backup ('runtime\'+$Name)
    $Exists=Test-Path -LiteralPath $Path
    if ($Exists) { New-Item -ItemType Directory -Path (Split-Path -Parent $Save) -Force | Out-Null; Copy-Item -LiteralPath $Path -Destination $Save }
    $RuntimeRecords += [pscustomobject]@{Path=$Path;Save=$Save;Existed=$Exists}
}
foreach ($Record in $SourceRecords) {
    if ($Record.Existed) { New-Item -ItemType Directory -Path (Split-Path -Parent $Record.Save) -Force | Out-Null; Copy-Item -LiteralPath $Record.Path -Destination $Record.Save }
}
[pscustomobject]@{BeforeBranch=$BeforeBranch;BeforeCommit=$Before;Revision=$Revision;Sources=$SourceRecords;Runtime=$RuntimeRecords;GoBackup=$GoBackup;Build=$Build} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$Backup\restore-info.json" -Encoding UTF8
function Install-Atomic([string]$Source,[string]$Destination) {
    $Temp=$Destination+'.install-'+[guid]::NewGuid().ToString('N')
    $Previous=$Destination+'.replaced-'+[guid]::NewGuid().ToString('N')
    try {
        Copy-Item -LiteralPath $Source -Destination $Temp
        if (Test-Path -LiteralPath $Destination) { [IO.File]::Replace($Temp,$Destination,$Previous);Remove-Item -LiteralPath $Previous }
        else { [IO.File]::Move($Temp,$Destination) }
        if ((Get-FileHash -LiteralPath $Source).Hash -ne (Get-FileHash -LiteralPath $Destination).Hash) { throw "Installed hash mismatch: $Destination" }
    } finally { if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp } }
}
$Mutated=$false;$BranchChanged=$false
try {
    $Mutated=$true
    foreach ($Record in $SourceRecords) {
        $Remote=if ($Record.Entry.group -eq 'go') {Join-Path $Package ('EQBCServers\Go\'+$Record.Entry.path)} else {Join-Path $Package ('MQ2WebUpdate\'+$Record.Entry.path)}
        Copy-Item -LiteralPath $Remote -Destination $Record.Path
    }
    $DllOut=Join-Path $Build 'dll'
    New-Item -ItemType Directory -Path $DllOut -Force | Out-Null
    & $MSBuild (Join-Path $Updater 'MQ2WebUpdate.vcxproj') /t:Rebuild /m /p:Configuration=Release /p:Platform=Win32 "/p:OutDir=$DllOut\" "/p:IntDir=$Build\obj\" /p:BuildProjectReferences=false /verbosity:minimal
    if ($LASTEXITCODE) { throw 'Updater rebuild failed.' }
    $Built=Join-Path $DllOut 'MQ2WebUpdate.dll'
    if (!(Test-Path -LiteralPath $Built)) { throw 'Updater output missing.' }
    Assert-Unloaded
    foreach ($Record in $RuntimeRecords) { Assert-Writable $Record.Path }
    Install-Atomic $Built $LiveDll
    foreach ($Item in $Release.payloads) { Install-Atomic (Join-Path $Package ('EQBCServers\'+$Item.name)) (Join-Path $Runtime $Item.name) }
    & (Join-Path $Runtime 'EQBCS-Go.exe') --version
    if ($LASTEXITCODE) { throw 'Go version check failed.' }
    git -C $Dev show-ref --verify --quiet "refs/heads/$Branch"
    if ($LASTEXITCODE -eq 0) {
        git -C $Dev switch $Branch
        if ($LASTEXITCODE) { throw 'Branch switch failed.' }
        $BranchChanged=$true
        git -C $Dev merge --ff-only $Revision
    } else {
        git -C $Dev switch -c $Branch --track "origin/$Branch"
        $BranchChanged=($LASTEXITCODE -eq 0)
    }
    if ($LASTEXITCODE -or (git -C $Dev rev-parse HEAD) -ne $Revision) { throw 'Triune test revision verification failed.' }
    foreach ($Link in $Links) {
        if (!(Test-Path -LiteralPath $Link.Live)) { New-Item -ItemType SymbolicLink -Path $Link.Live -Target $Link.Source | Out-Null;$Created += $Link.Live }
        $Linked=$false;$Resolved=Resolve-Link $Link.Live ([ref]$Linked)
        if (!$Linked -or $Resolved -ine [IO.Path]::GetFullPath($Link.Source)) { throw "Link verification failed: $($Link.Live)" }
        $Expected=git -C $Dev rev-parse "$Revision`:$($Link.Relative)"
        $Actual=git -C $Dev hash-object "--path=$($Link.Relative)" $Link.Live
        if ($LASTEXITCODE -or $Expected -ne $Actual) { throw "Lua blob mismatch: $($Link.Live)" }
    }
} catch {
    $Reason=$_
    if ($Mutated) {
        Assert-Unloaded
        foreach ($Record in $RuntimeRecords) { if ($Record.Existed) { Install-Atomic $Record.Save $Record.Path } elseif (Test-Path -LiteralPath $Record.Path) { Remove-Item -LiteralPath $Record.Path } }
        foreach ($Record in $SourceRecords) { if ($Record.Existed) { Copy-Item -LiteralPath $Record.Save -Destination $Record.Path -Force } elseif (Test-Path -LiteralPath $Record.Path) { Remove-Item -LiteralPath $Record.Path } }
    }
    foreach ($Link in $Created) { Remove-Item -LiteralPath $Link -Force }
    if ($BranchChanged) {
        if ($BeforeBranch -eq $Branch -and (git -C $Dev rev-parse HEAD) -ne $Before) { git -C $Dev switch -c ('nero/server-updater-rollback-'+$Tag) $Before }
        else { git -C $Dev switch $BeforeBranch }
        if ($LASTEXITCODE) { throw "Rollback branch switch failed; keep Triune stopped. Backup: $Backup. $Reason" }
    }
    throw "Installation stopped; previous files restored. Backup: $Backup. $Reason"
}
[pscustomobject]@{BeforeBranch=$BeforeBranch;BeforeCommit=$Before;Revision=$Revision;Sources=$SourceRecords;Runtime=$RuntimeRecords;GoBackup=$GoBackup;Build=$Build;Dev=$Dev;CreatedLinks=$Created} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$Backup\restore-info.json" -Encoding UTF8
$DllHash=(Get-FileHash -LiteralPath $LiveDll).Hash.ToLowerInvariant()
[pscustomobject]@{version='4.1.7';sha256=$DllHash;revision=$Revision;runtime_dll=$LiveDll;built_dll=$Built} | ConvertTo-Json | Set-Content -LiteralPath "$Backup\built-updater.json" -Encoding UTF8
Write-Host "Installed EQBC server updater test: $Revision"
Write-Host "Native/updater backup: $Backup"
Write-Host "Go source backup: $GoBackup"
Write-Host "Build artifacts: $Build"
Write-Host 'No server INIs were overwritten; neither server was started. Main is unchanged.'
Write-Host "Rollback: stop Triune, unload WebUpdate, stop servers, then run $Dev\tools\restore_eqbc_server_update_test.ps1 -BackupPath '$Backup'"
Write-Host 'Load /plugin mq2webupdate load, then /lua run triune. Verify /echo ${WebUpdate.Version} is 4.1.7.'
Write-Host 'Start EQBCS-Go.exe when ready. Its banner identifies 1.0-NeroMorte.2; internal Triune packets are hidden by default.'
Write-Host 'Verify both server mappings point to MQ root. Existing INIs are preserved; missing defaults are created within 30 seconds.'
Write-Host "After game testing, send the result and $Backup\built-updater.json so the verified DLL can be published."
