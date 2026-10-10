# Created By: NeroMorte - focused Windows build/install, preserving links and server/client INIs.
param([Parameter(Mandatory=$true)][string]$Revision,
 [string]$Dev='E:\MQ2Next\TriuneAutocombat', [string]$MQ='E:\MQ2Next\macroquest')
$ErrorActionPreference='Stop'
$Branch='nero/boxnet-connection-test'
$Runtime=Join-Path $MQ 'build\bin\release'
$Native=Join-Path $MQ 'plugins\MQ2EQBC'
$Go=Join-Path $MQ 'plugins\MQ2EQBCS-Go'
$Before=git -C $Dev rev-parse HEAD
$BeforeBranch=git -C $Dev branch --show-current
if ($LASTEXITCODE -or !$BeforeBranch -or $Revision -notmatch '^[0-9a-f]{40}$') { throw 'Start from a named branch and valid revision.' }
$Origin=git -C $Dev remote get-url origin
if ($LASTEXITCODE -or $Origin -notmatch '(?i)github\.com[:/]XxNeroMortexX/TriuneAutocombat(?:\.git)?/?$') { throw 'Unexpected Triune origin.' }
git -C $Dev diff --quiet
if ($LASTEXITCODE) { throw 'Tracked edits exist; stopped without stashing.' }
git -C $Dev diff --cached --quiet
if ($LASTEXITCODE) { throw 'Staged edits exist; stopped.' }
git -C $Dev fetch origin $Branch
if ($LASTEXITCODE -or (git -C $Dev rev-parse FETCH_HEAD) -ne $Revision) { throw 'Branch changed; get current instructions.' }
git -C $Dev merge-base --is-ancestor $Before $Revision
if ($LASTEXITCODE) { throw 'Current checkout is not an ancestor of this test.' }
function Assert-Unloaded {
 foreach ($Process in @(Get-Process eqgame -ErrorAction SilentlyContinue)) {
  try { $Modules=@($Process.Modules) } catch { throw "Cannot inspect EQ process $($Process.Id); run elevated or close it." }
  if (!$Modules.Count) { throw "Cannot inspect EQ process $($Process.Id)." }
  if (@($Modules | Where-Object { $_.ModuleName -ieq 'MQ2EQBC.dll' }).Count) { throw "Unload MQ2EQBC in EQ process $($Process.Id) first." }
 }
}
function Assert-Writable([string]$Path) {
 if (Test-Path -LiteralPath $Path) { $Stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $Stream.Close() }
}
function Canonical-Hash([string]$Path) {
 $Text=[IO.File]::ReadAllText($Path).Replace("`r`n","`n")
 $Algorithm=[Security.Cryptography.SHA256]::Create()
 try { return ([BitConverter]::ToString($Algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() } finally { $Algorithm.Dispose() }
}
Assert-Unloaded
foreach ($Path in @((Join-Path $Runtime 'plugins\MQ2EQBC.dll'),(Join-Path $Runtime 'EQBCS-Go.exe'))) { Assert-Writable $Path }
if (@(Get-Process 'EQBCS-Go' -ErrorAction SilentlyContinue).Count) { throw 'Stop EQBCS-Go before installing its replacement.' }
$Tag=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$Backup=Join-Path $Native ('Backup\connection-'+$Tag)
$Build=Join-Path $MQ ('build\artifacts\eqbc-connection-'+$Tag)
$Package=Join-Path $Build 'package'
New-Item -ItemType Directory -Path $Backup,$Package -Force | Out-Null
git -c core.autocrlf=false -c core.eol=lf -C $Dev archive --format=zip "--output=$Build\source.zip" $Revision -- MQ2EQBC EQBCServers/Go EQBCServers/EQBCS-Go.exe EQBCServers/release.json
if ($LASTEXITCODE) { throw 'Canonical source archive failed.' }
Expand-Archive -LiteralPath "$Build\source.zip" -DestinationPath $Package
$Layout=Get-Content (Join-Path $Package 'MQ2EQBC\source-layout.json') -Raw | ConvertFrom-Json
foreach ($Entry in $Layout.files) {
 $Path=Join-Path $Native $Entry.file
 if (Test-Path -LiteralPath $Path) {
  $Hash=Canonical-Hash $Path
  if ($Hash -ne $Entry.baseline -and $Hash -ne $Entry.updated) { throw "Unreviewed native source: $Path. Live files unchanged." }
 } elseif ($Entry.baseline) { throw "Required source missing: $Path" }
}
# Review Go source before making any mutation, including its uncommitted INI work.
$GoBefore=git -C $Go rev-parse HEAD
if ($LASTEXITCODE) { throw 'Go development checkout missing.' }
foreach ($Entry in $Layout.goFiles) {
 $Path=Join-Path $Go $Entry.file
 if (Test-Path -LiteralPath $Path) {
  $Hash=Canonical-Hash $Path
  if($Hash -ne $Entry.baseline -and $Hash -ne $Entry.updated){throw "Unreviewed Go source: $Path. Live files unchanged."}
 } elseif($Entry.baseline){throw "Required Go source missing: $Path"}
}
$VsWhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$MSBuild=& $VsWhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if (!$MSBuild -or !(Test-Path -LiteralPath $MSBuild)) { throw 'Visual Studio MSBuild not found.' }
$Records=@()
$Links=@()
function Save-File([string]$Path) {
 $Index=$script:Records.Count
 $Copy=Join-Path $Backup ('file-'+$Index)
 $Exists=Test-Path -LiteralPath $Path
 if ($Exists) { Copy-Item -LiteralPath $Path -Destination $Copy }
 $script:Records+=@([pscustomobject]@{path=$Path;backup=$Copy;existed=$Exists})
}
function Replace-File([string]$Source,[string]$Destination) {
 Assert-Writable $Destination
 New-Item -ItemType Directory -Path (Split-Path -Parent $Destination) -Force | Out-Null
 $Temp=$Destination+'.install-'+[guid]::NewGuid().ToString('N')
 Copy-Item -LiteralPath $Source -Destination $Temp
 try {
  if (Test-Path -LiteralPath $Destination) {
   $Old=$Destination+'.replace-'+[guid]::NewGuid().ToString('N')
   [IO.File]::Replace($Temp,$Destination,$Old)
   Remove-Item -LiteralPath $Old
  } else { [IO.File]::Move($Temp,$Destination) }
 } finally { if(Test-Path -LiteralPath $Temp){Remove-Item -LiteralPath $Temp} }
 if ((Get-FileHash -LiteralPath $Source).Hash -ne (Get-FileHash -LiteralPath $Destination).Hash) { throw "Copy verification failed: $Destination" }
}
$Switched=$false
try {
 foreach ($Entry in $Layout.files) {
  $Destination=Join-Path $Native $Entry.file
  Save-File $Destination
  Copy-Item -LiteralPath (Join-Path $Package ('MQ2EQBC\source\'+$Entry.file)) -Destination $Destination
 }
 $DllOut=Join-Path $Build 'dll'
 New-Item -ItemType Directory -Path $DllOut -Force | Out-Null
 & $MSBuild (Join-Path $Native 'MQ2EQBC.vcxproj') /t:Rebuild /m /p:Configuration=Release /p:Platform=Win32 "/p:OutDir=$DllOut\" "/p:IntDir=$Build\obj\" /p:BuildProjectReferences=false /verbosity:minimal
 if ($LASTEXITCODE) { throw 'MQ2EQBC rebuild failed.' }
 $Dll=Join-Path $DllOut 'MQ2EQBC.dll'
 if (!(Test-Path -LiteralPath $Dll)) { throw 'Rebuilt DLL missing.' }
 $Bytes=[IO.File]::ReadAllBytes($Dll)
 $Offset=[BitConverter]::ToInt32($Bytes,0x3c)
 if ($Bytes[0] -ne 77 -or $Bytes[1] -ne 90 -or [BitConverter]::ToUInt16($Bytes,$Offset+4) -ne 332) { throw 'Expected Win32 PE DLL.' }
 $Servers=Get-Content (Join-Path $Package 'EQBCServers\release.json') -Raw | ConvertFrom-Json
 $Payload=@($Servers.payloads | Where-Object { $_.name -eq 'EQBCS-Go.exe' })[0]
 $Server=Join-Path $Package 'EQBCServers\EQBCS-Go.exe'
 if ((Get-FileHash -LiteralPath $Server).Hash.ToLowerInvariant() -ne $Payload.sha256) { throw 'Go server hash mismatch.' }
 $Banner=& $Server --version
 if ($LASTEXITCODE -or $Banner -ne 'EQBCS-Go 1.0-NeroMorte.3') { throw 'Go server version mismatch.' }
 Assert-Unloaded
 $TargetDll=Join-Path $Runtime 'plugins\MQ2EQBC.dll'
 $TargetServer=Join-Path $Runtime 'EQBCS-Go.exe'
 Save-File $TargetDll
 Save-File $TargetServer
 Replace-File $Dll $TargetDll
 Replace-File $Server $TargetServer
 # Keep the Go development tree synchronized; its INI and uncommitted edits are preserved.
 $GoBefore=git -C $Go rev-parse HEAD
 if ($LASTEXITCODE) { throw 'Go development checkout missing.' }
 foreach ($Relative in @('eqbc.go','discovery.go','discovery_test.go','cmd\eqbc\config.go','cmd\eqbc\main.go')) {
  $Destination=Join-Path $Go $Relative
  Save-File $Destination
  Copy-Item -LiteralPath (Join-Path $Package ('EQBCServers\Go\'+$Relative)) -Destination $Destination -Force
 }
 git -C $Dev show-ref --verify --quiet ('refs/heads/'+$Branch)
 if ($LASTEXITCODE) { git -C $Dev switch -c $Branch ('origin/'+$Branch) } else { git -C $Dev switch $Branch }
 if ($LASTEXITCODE) { throw 'Triune branch switch failed.' }
 $Switched=$true
 git -C $Dev merge --ff-only $Revision
 if ($LASTEXITCODE -or (git -C $Dev rev-parse HEAD) -ne $Revision) { throw 'Triune fast-forward failed.' }
 foreach ($Relative in @('tac\boxnet.lua','tac\update_manager.lua','TAC_support_modules\boxnet_connection.lua','TAC_support_modules\eqbc_plugin_update_policy.lua','TAC_support_modules\eqbc_plugin_release.lua','TAC_support_modules\eqbc_server_release.lua','TAC_support_modules\update_config.lua')) {
  $Live=Join-Path $Runtime ('lua\'+$Relative)
  $Source=Join-Path $Dev ('TAC\lua\'+$Relative)
  if (!(Test-Path -LiteralPath $Live)) {
   if (Get-Item -LiteralPath $Live -ErrorAction SilentlyContinue) { throw "Broken existing link: $Live" }
   New-Item -ItemType Directory -Path (Split-Path -Parent $Live) -Force | Out-Null
   New-Item -ItemType SymbolicLink -Path $Live -Target $Source | Out-Null
   $Links+=@($Live)
  }
  if ((Get-FileHash -LiteralPath $Live).Hash -ne (Get-FileHash -LiteralPath $Source).Hash) { throw "Runtime Lua does not match development: $Live" }
 }
 foreach($Record in $Records){ $Record | Add-Member -NotePropertyName installedHash -NotePropertyValue (Get-FileHash -LiteralPath $Record.path).Hash }
 $Records | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Backup 'files.json') -Encoding UTF8
 [pscustomobject]@{revision=$Revision;before=$Before;beforeBranch=$BeforeBranch;dev=$Dev;links=$Links} | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Backup 'restore-info.json') -Encoding UTF8
 [pscustomobject]@{version='20.01-NeroMorte.1';revision=$Revision;sha256=(Get-FileHash -LiteralPath $Dll).Hash.ToLowerInvariant();bytes=(Get-Item -LiteralPath $Dll).Length;built_dll=$Dll;runtime_dll=$TargetDll} | ConvertTo-Json | Set-Content (Join-Path $Backup 'built-eqbc.json') -Encoding UTF8
 Write-Host "Installed focused BoxNet connection test: $Revision"
 Write-Host "Backup: $Backup"
 Write-Host 'Existing Lua links and all INIs preserved. Start the Go server, load MQ2EQBC in every client, then start Triune.'
 Write-Host 'No transport/control/silence commands are needed. Open BoxNet -> Connection.'
 Write-Host "After testing, upload $Backup\built-eqbc.json and the DLL it identifies for publication. Main is unchanged."
} catch {
 $Failure=$_
 foreach ($Record in $Records) {
  if ($Record.existed) { Copy-Item -LiteralPath $Record.backup -Destination $Record.path -Force }
  elseif(Test-Path -LiteralPath $Record.path) { Remove-Item -LiteralPath $Record.path }
 }
 foreach ($Link in $Links) { if(Get-Item -LiteralPath $Link -ErrorAction SilentlyContinue){Remove-Item -LiteralPath $Link} }
 if($Switched) { git -C $Dev switch $BeforeBranch }
 throw "Test stopped and backed-up files restored. Backup: $Backup. $Failure"
}
