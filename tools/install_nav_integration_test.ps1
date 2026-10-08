# Created By: NeroMorte - Build Nav first, then install matching Triune through existing links.
param(
    [Parameter(Mandatory=$true)][string]$Revision,
    [string]$Dev='E:\MQ2Next\TriuneAutocombat',
    [string]$RuntimeLua='E:\MQ2Next\macroquest\build\bin\release\lua',
    [string]$BackupRoot='E:\MQ2Next\TriuneGUIBackups'
)
$ErrorActionPreference='Stop'
if ($Revision -notmatch '^[0-9a-f]{40}$') { throw 'Supply the exact test commit.' }
$Remote=git -C $Dev remote get-url origin
if ($LASTEXITCODE -ne 0 -or $Remote -notmatch '(?i)github\.com[:/]XxNeroMortexX/TriuneAutocombat(?:\.git)?/?$') { throw 'Unexpected origin.' }
git -C $Dev diff --quiet
if ($LASTEXITCODE -ne 0) { throw 'Tracked changes exist; stopped without stashing.' }
git -C $Dev diff --cached --quiet
if ($LASTEXITCODE -ne 0) { throw 'Staged changes exist; stopped.' }
git -C $Dev fetch origin nero/nav-integration-test
if ($LASTEXITCODE -ne 0 -or (git -C $Dev rev-parse FETCH_HEAD) -ne $Revision) { throw 'Remote test revision changed; stopped.' }
$Package=Join-Path $BackupRoot ('triune-nav-package-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Package | Out-Null
$Zip=Join-Path $Package 'source.zip'
git -c core.autocrlf=false -c core.eol=lf -C $Dev archive "--format=zip" "--output=$Zip" $Revision -- 'MQ2Nav' 'tools/install_water_chase_test.ps1' 'tools/publish_nav_test.ps1'
if ($LASTEXITCODE -ne 0) { throw 'Exact source archive failed; live files unchanged.' }
Expand-Archive -LiteralPath $Zip -DestinationPath $Package
Write-Host 'Triune must be stopped in every client; MQ2Nav must be unloaded everywhere.'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Package\MQ2Nav\Install.ps1"
if ($LASTEXITCODE -ne 0) { throw 'Nav build/install failed; Triune checkout was not switched.' }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$Package\tools\install_water_chase_test.ps1" -Revision $Revision -Dev $Dev -RuntimeLua $RuntimeLua -BackupRoot $BackupRoot
if ($LASTEXITCODE -ne 0) { throw "Triune install failed; leave Triune stopped. Nav's printed RestoreWorking command restores its previous DLL/source. Package: $Package" }
Write-Host 'Load MQ2Nav in every client: /plugin mq2nav load'
Write-Host 'Enable Auto XYZ in Nav settings, then start Triune: /lua run triune'
Write-Host 'Test Chase underwater/levitating at distance 2, stationary close-stall arrival, moving leader, dry-land Chase and permitted combat approaches.'
Write-Host "After the game test, publish the verified DLL with '$Dev\tools\publish_nav_test.ps1' -Revision '$Revision' -BuildBackup '<the XYZ integration backup printed above>'."
