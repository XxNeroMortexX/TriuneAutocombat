# Created By: NeroMorte - focused 4.1.8 build/install with source review and rollback.
# Stop Triune and unload MQ2WebUpdate in every EQ client before running.
param([Parameter(Mandatory=$true)][string]$Revision,
 [string]$Dev='E:\MQ2Next\TriuneAutocombat', [string]$MQ='E:\MQ2Next\macroquest')
$ErrorActionPreference='Stop'
$Branch='nero/updater-rate-limit-test'
$Native=Join-Path $MQ 'plugins\MQ2WebUpdate'
$Runtime=Join-Path $MQ 'build\bin\release'
$Live=Join-Path $Runtime 'plugins\MQ2WebUpdate.dll'
if($Revision -notmatch '^[0-9a-f]{40}$'){throw 'Use the exact reviewed revision.'}
$Origin=git -C $Dev remote get-url origin
if($LASTEXITCODE -or $Origin -notmatch '(?i)github\.com[:/]XxNeroMortexX/TriuneAutocombat(?:\.git)?/?$'){throw 'Unexpected Triune origin.'}
git -C $Dev fetch origin $Branch
if($LASTEXITCODE -or (git -C $Dev rev-parse FETCH_HEAD) -ne $Revision){throw 'Test branch changed; get updated instructions.'}
function Assert-Unloaded {
 foreach($Process in @(Get-Process eqgame -ErrorAction SilentlyContinue)){
  try{$Modules=@($Process.Modules)}catch{throw "Cannot inspect EQ $($Process.Id); run elevated or close that client."}
  if(!$Modules.Count){throw "Cannot inspect EQ $($Process.Id)."}
  if(@($Modules | Where-Object {$_.ModuleName -ieq 'MQ2WebUpdate.dll'}).Count){throw "Unload MQ2WebUpdate in EQ $($Process.Id) first."}
 }
}
function Assert-Writable([string]$Path){
 if(Test-Path -LiteralPath $Path){$Stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$Stream.Close()}
}
function Canonical-Hash([string]$Path){
 $Text=[IO.File]::ReadAllText($Path).Replace("`r`n","`n")
 # Edited By: NeroMorte - the reviewed local project differs only by an EOF blank line.
 # Normalize trailing line breaks for project XML; all build settings still hash exactly.
 if([IO.Path]::GetExtension($Path) -ieq '.vcxproj'){$Text=$Text.TrimEnd([char[]]"`r`n")+"`n"}
 $Algorithm=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($Algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()}finally{$Algorithm.Dispose()}
}
function Install-Atomic([string]$Source,[string]$Destination){
 $Temp=$Destination+'.install-'+[guid]::NewGuid().ToString('N')
 $Old=$Destination+'.replace-'+[guid]::NewGuid().ToString('N')
 try{
  Copy-Item -LiteralPath $Source -Destination $Temp
  if(Test-Path -LiteralPath $Destination){[IO.File]::Replace($Temp,$Destination,$Old);Remove-Item -LiteralPath $Old}
  else{[IO.File]::Move($Temp,$Destination)}
  if((Get-FileHash -LiteralPath $Source).Hash -ne (Get-FileHash -LiteralPath $Destination).Hash){throw "Copy mismatch: $Destination"}
 }finally{if(Test-Path -LiteralPath $Temp){Remove-Item -LiteralPath $Temp}}
}
Assert-Unloaded
Assert-Writable $Live
if(!(Test-Path -LiteralPath (Join-Path $Native 'MQ2WebUpdate.vcxproj'))){throw 'Native updater project missing.'}
$VsWhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$MSBuild=& $VsWhere -latest -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1
if(!$MSBuild -or !(Test-Path -LiteralPath $MSBuild)){throw 'Visual Studio MSBuild not found.'}
$Tag=(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$Backup=Join-Path $Native ('Backup\rate-limit-'+$Tag)
$Build=Join-Path $MQ ('build\artifacts\webupdate-rate-limit-'+$Tag)
$Package=Join-Path $Build 'package'
$DllOut=Join-Path $Build 'dll'
New-Item -ItemType Directory -Path $Backup,$Package,$DllOut -Force | Out-Null
git -c core.autocrlf=false -c core.eol=lf -C $Dev archive --format=zip "--output=$Build\source.zip" $Revision -- MQ2WebUpdate
if($LASTEXITCODE){throw 'Canonical source archive failed.'}
Expand-Archive -LiteralPath "$Build\source.zip" -DestinationPath $Package
$Layout=Get-Content -LiteralPath "$Package\MQ2WebUpdate\rate-limit-source-layout.json" -Raw | ConvertFrom-Json
$Records=@()
foreach($Entry in $Layout.files){
 $Path=Join-Path $Native $Entry.file
 if(Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}){throw "Unexpected source link: $Path"}
 $Exists=Test-Path -LiteralPath $Path
 if($Exists){
  $Hash=Canonical-Hash $Path
  if($Hash -ne $Entry.baseline -and $Hash -ne $Entry.updated){throw "Unreviewed source: $Path. Nothing replaced."}
 }elseif($Entry.baseline){throw "Required source missing: $Path"}
 $Remote=Join-Path $Package ('MQ2WebUpdate\'+$Entry.file)
 if((Canonical-Hash $Remote) -ne $Entry.updated){throw "Source archive hash mismatch: $Remote"}
 $Records+=@([pscustomobject]@{path=$Path;backup=(Join-Path $Backup $Entry.file);existed=$Exists;source=$Remote})
}
$Records+=@([pscustomobject]@{path=$Live;backup=(Join-Path $Backup 'MQ2WebUpdate.dll');existed=(Test-Path -LiteralPath $Live);source=$null})
foreach($Record in $Records){if($Record.existed){Copy-Item -LiteralPath $Record.path -Destination $Record.backup}}
[pscustomobject]@{revision=$Revision;records=$Records;build=$Build} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$Backup\restore-info.json" -Encoding UTF8
$Mutated=$false
try{
 $Mutated=$true
 foreach($Record in $Records){if($Record.source){Copy-Item -LiteralPath $Record.source -Destination $Record.path -Force}}
 & $MSBuild (Join-Path $Native 'MQ2WebUpdate.vcxproj') /t:Rebuild /m /p:Configuration=Release /p:Platform=Win32 "/p:OutDir=$DllOut\" "/p:IntDir=$Build\obj\" /p:BuildProjectReferences=false /verbosity:minimal
 if($LASTEXITCODE){throw 'Updater rebuild failed.'}
 $Dll=Join-Path $DllOut 'MQ2WebUpdate.dll'
 if(!(Test-Path -LiteralPath $Dll)){throw 'Rebuilt DLL missing.'}
 $Bytes=[IO.File]::ReadAllBytes($Dll)
 if($Bytes.Length -lt 256){throw 'Invalid DLL size.'}
 $Offset=[BitConverter]::ToInt32($Bytes,0x3c)
 if($Offset -lt 0 -or $Offset+24 -ge $Bytes.Length -or $Bytes[0] -ne 77 -or $Bytes[1] -ne 90 -or [BitConverter]::ToUInt32($Bytes,$Offset) -ne 17744 -or [BitConverter]::ToUInt16($Bytes,$Offset+4) -ne 332){throw 'Expected Win32 PE DLL.'}
 Assert-Unloaded
 Assert-Writable $Live
 Install-Atomic $Dll $Live
 foreach($Record in $Records){$Record | Add-Member -NotePropertyName installedHash -NotePropertyValue (Get-FileHash -LiteralPath $Record.path).Hash}
 [pscustomobject]@{revision=$Revision;records=$Records;build=$Build} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$Backup\restore-info.json" -Encoding UTF8
 $Record=[pscustomobject]@{version='4.1.8';sourceRevision=$Revision;bytes=(Get-Item -LiteralPath $Dll).Length;sha256=(Get-FileHash -LiteralPath $Dll).Hash.ToLowerInvariant();built_dll=$Dll;runtime_dll=$Live}
 $Record | ConvertTo-Json | Set-Content -LiteralPath "$Backup\built-webupdate.json" -Encoding UTF8
 $Publish=Join-Path $Build 'publish'
 New-Item -ItemType Directory -Path $Publish | Out-Null
 Copy-Item -LiteralPath $Dll -Destination $Publish
 Copy-Item -LiteralPath "$Backup\built-webupdate.json" -Destination $Publish
 Compress-Archive -Path "$Publish\*" -DestinationPath "$Build\webupdate-4.1.8-test-publish.zip"
 Write-Host 'Installed MQ2WebUpdate 4.1.8 candidate. Lua links, settings, stashes and Triune checkout unchanged.'
 Write-Host "Backup: $Backup"
 Write-Host "Upload this build package: $Build\webupdate-4.1.8-test-publish.zip"
 Write-Host 'Load MQ2WebUpdate and confirm 4.1.8. Main still ships 4.1.7; defer Apply until the test DLL is published on the test branch.'
}catch{
 $Failure=$_
 if($Mutated){
  Assert-Unloaded
  foreach($Record in $Records){
   if($Record.existed){Install-Atomic $Record.backup $Record.path}
   elseif(Test-Path -LiteralPath $Record.path){Remove-Item -LiteralPath $Record.path}
  }
 }
 throw "Candidate install stopped; backed-up files restored. Backup: $Backup. $Failure"
}
