# Created By: NeroMorte - Publish only the verified Windows test build to the focused test branch.
param(
    [Parameter(Mandatory=$true)][string]$BuildBackup,
    [Parameter(Mandatory=$true)][string]$Revision,
    [string]$Dev='E:\MQ2Next\TriuneAutocombat'
)
$ErrorActionPreference='Stop'
$Branch='nero/chase-water-test'
if ($Revision -notmatch '^[0-9a-f]{40}$') { throw 'Supply the installed Triune test commit.' }
if ((git -C $Dev branch --show-current) -ne $Branch -or (git -C $Dev rev-parse HEAD) -ne $Revision) { throw 'Expected the exact installed test branch/revision.' }
$Remote=git -C $Dev remote get-url origin
if ($LASTEXITCODE -ne 0 -or $Remote -notmatch '(?i)github\.com[:/]XxNeroMortexX/TriuneAutocombat(?:\.git)?/?$') { throw 'Unexpected origin.' }
git -C $Dev diff --quiet
if ($LASTEXITCODE -ne 0) { throw 'Tracked files have changes; no files published.' }
git -C $Dev diff --cached --quiet
if ($LASTEXITCODE -ne 0) { throw 'Staged changes exist; no files published.' }
git -C $Dev fetch origin $Branch
if ($LASTEXITCODE -ne 0 -or (git -C $Dev rev-parse FETCH_HEAD) -ne $Revision) { throw 'Remote test branch changed; stopped.' }
$Record=Get-Content -LiteralPath (Join-Path $BuildBackup 'integration-install.json') -Raw | ConvertFrom-Json
if (!$Record.installed -or !$Record.new_dll_hash) { throw 'Expected a successfully installed integration build.' }
$Built=Join-Path $BuildBackup 'build\MQ2Nav.dll'
foreach ($Path in @($Built,$Record.runtime_dll)) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Record.new_dll_hash) { throw "Build verification failed: $Path" }
    $Info=[Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    if ($Info.FileVersion -ne '1.3.3.5' -or $Info.FileDescription -notlike '*NeroMorte XYZ Integration Test*') { throw 'Unexpected plugin version.' }
}
$Expected=Get-Content -LiteralPath (Join-Path $Dev 'MQ2Nav\integration-hashes.json') -Raw | ConvertFrom-Json
function Text-Hash([string]$Path) {
    $Hash=[Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($Hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($Path).Replace("`r`n","`n")))).Replace('-','') }
    finally { $Hash.Dispose() }
}
foreach ($Entry in $Expected.files) {
    foreach ($Path in @((Join-Path "$Dev\MQ2Nav\source" $Entry.name),(Join-Path "$($Record.nav)\plugin" $Entry.name))) {
        if ((Text-Hash $Path) -ne $Entry.after_sha256) { throw "Source provenance differs: $Path" }
    }
}
$MQRoot=Split-Path -Parent (Split-Path -Parent $Record.nav)
$MQCommit=git -C $MQRoot rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $MQCommit -ne '8d97fa3c78d549fc0849aec332f0e25413a74293') { throw 'MacroQuest ABI source commit changed; this distribution is for the verified RoF2 build only.' }
$Dest=Join-Path $Dev 'MQ2Nav\MQ2Nav.dll'
if (Test-Path -LiteralPath $Dest) { throw 'A published DLL already exists; retain it and use a separately reviewed version update.' }
Copy-Item -LiteralPath $Built -Destination $Dest
$Sha=$Record.new_dll_hash.ToLowerInvariant()
$Release=@"
-- Created By: NeroMorte - Verified Windows RoF2 build; enables automatic updater registration.
return { enabled=true, version='1.3.3.5', remote='MQ2Nav/MQ2Nav.dll', sha256='$Sha',
    client='RoF2', architecture='Win32', macroquestCommit='$MQCommit' }
"@
$Utf8=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $Dev 'TAC\lua\TAC_support_modules\nav_plugin_release.lua'),$Release.Replace("`r`n","`n")+"`n",$Utf8)
$Metadata=[ordered]@{ enabled=$true; version='1.3.3.5'; remote='MQ2Nav/MQ2Nav.dll'; sha256=$Sha; client='RoF2'; architecture='Win32'; macroquestCommit=$MQCommit; navBase=$Expected.base_commit; sourceRevision=$Revision }
[IO.File]::WriteAllText((Join-Path $Dev 'MQ2Nav\release.json'),($Metadata | ConvertTo-Json).Replace("`r`n","`n")+"`n",$Utf8)
git -C $Dev add -- 'MQ2Nav/MQ2Nav.dll' 'MQ2Nav/release.json' 'TAC/lua/TAC_support_modules/nav_plugin_release.lua'
if ($LASTEXITCODE -ne 0) { throw 'Staging failed; files retained for inspection.' }
git -C $Dev commit -m 'release: publish verified RoF2 Nav 1.3.3.5 test payload'
if ($LASTEXITCODE -ne 0) { throw 'Commit failed; staged payload retained. No main changes.' }
git -C $Dev push origin "HEAD:refs/heads/$Branch"
if ($LASTEXITCODE -ne 0) { throw 'Push failed; local test commit retained. Retry ordinary git push after inspecting origin.' }
Write-Host 'Verified Nav payload published to the test branch; main remains unchanged.'
Write-Host "Published commit: $(git -C $Dev rev-parse HEAD)"
Write-Host 'Restart Triune so its add-only updater registration can run. No repository/file mapping setup is needed.'
