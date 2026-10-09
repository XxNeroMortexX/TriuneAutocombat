# Created By: NeroMorte - restore the updater, servers, source and pre-test profile format together.
param([Parameter(Mandatory=$true)][string]$BackupPath)
$ErrorActionPreference='Stop'
$Info=Get-Content -LiteralPath (Join-Path $BackupPath 'restore-info.json') -Raw | ConvertFrom-Json
if (!$Info.Dev -or !$Info.BeforeCommit -or !$Info.Runtime -or !$Info.Sources) { throw 'Incomplete completed-install rollback record.' }
foreach ($Process in @(Get-Process eqgame -ErrorAction SilentlyContinue)) {
    try { $Modules=@($Process.Modules) } catch { throw "Cannot inspect EQ $($Process.Id); run elevated or close it." }
    if (!$Modules.Count -or @($Modules | Where-Object {$_.ModuleName -ieq 'MQ2WebUpdate.dll'}).Count) { throw "Unload MQ2WebUpdate in EQ $($Process.Id) before rollback." }
}
$Current=git -C $Info.Dev rev-parse HEAD
if ($LASTEXITCODE -or $Current -ne $Info.Revision) { throw 'Triune checkout changed after installation; stopped.' }
git -C $Info.Dev diff --quiet
if ($LASTEXITCODE) { throw 'Tracked edits exist; stopped.' }
git -C $Info.Dev diff --cached --quiet
if ($LASTEXITCODE) { throw 'Staged edits exist; stopped.' }
foreach ($Record in $Info.Runtime) {
    if ($Record.Existed -and !(Test-Path -LiteralPath $Record.Save)) { throw "Backup missing: $($Record.Save)" }
    if (Test-Path -LiteralPath $Record.Path) { $Stream=[IO.File]::Open($Record.Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$Stream.Close() }
}
foreach ($Record in $Info.Sources) {
    if ($Record.Existed -and !(Test-Path -LiteralPath $Record.Save)) { throw "Source backup missing: $($Record.Save)" }
    $Text=[IO.File]::ReadAllText($Record.Path).Replace("`r`n","`n")
    $Alg=[Security.Cryptography.SHA256]::Create()
    try {$Hash=([BitConverter]::ToString($Alg.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()} finally {$Alg.Dispose()}
    if ($Hash -ne $Record.Entry.updated) { throw "Source changed after installation: $($Record.Path). Stopped." }
}
# Save settings edited during testing before restoring the old backend profile format.
$Saved=Join-Path $BackupPath ('before-restore-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Saved | Out-Null
foreach ($Record in $Info.Runtime) {
    if (Test-Path -LiteralPath $Record.Path) { Copy-Item -LiteralPath $Record.Path -Destination (Join-Path $Saved (Split-Path -Leaf $Record.Path)) }
    if ($Record.Existed) {
        $Temp=$Record.Path+'.restore-'+[guid]::NewGuid().ToString('N')
        $Previous=$Temp+'.previous'
        Copy-Item -LiteralPath $Record.Save -Destination $Temp
        if (Test-Path -LiteralPath $Record.Path) { [IO.File]::Replace($Temp,$Record.Path,$Previous);Remove-Item -LiteralPath $Previous }
        else { [IO.File]::Move($Temp,$Record.Path) }
        if ((Get-FileHash -LiteralPath $Record.Path).Hash -ne (Get-FileHash -LiteralPath $Record.Save).Hash) { throw 'Restored binary/settings hash mismatch.' }
    } elseif (Test-Path -LiteralPath $Record.Path) { Remove-Item -LiteralPath $Record.Path }
}
foreach ($Record in $Info.Sources) {
    if ($Record.Existed) { Copy-Item -LiteralPath $Record.Save -Destination $Record.Path -Force }
    elseif (Test-Path -LiteralPath $Record.Path) { Remove-Item -LiteralPath $Record.Path }
}
foreach ($Link in @($Info.CreatedLinks)) {
    if (Test-Path -LiteralPath $Link) {
        $Item=Get-Item -LiteralPath $Link -Force
        if ($Item.LinkType -ne 'SymbolicLink') { throw "Expected test link changed: $Link" }
        Remove-Item -LiteralPath $Link -Force
    }
}
$OldHead=git -C $Info.Dev rev-parse $Info.BeforeBranch
if ($LASTEXITCODE -eq 0 -and $OldHead -eq $Info.BeforeCommit) { git -C $Info.Dev switch $Info.BeforeBranch }
else { git -C $Info.Dev switch -c ('nero/server-updater-rollback-'+[guid]::NewGuid().ToString('N').Substring(0,8)) $Info.BeforeCommit }
if ($LASTEXITCODE) { throw 'Files restored, but checkout switch failed; keep Triune stopped.' }
Write-Host 'Restored previous server/updater binaries, development source and updater profile format. Server INIs were preserved.'
Write-Host "Settings from the test were retained in $Saved"
Write-Host 'Load MQ2WebUpdate, then start Triune when ready.'
