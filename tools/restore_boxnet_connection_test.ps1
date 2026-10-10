# Created By: NeroMorte - restore the focused client/server test without touching user INIs.
param([Parameter(Mandatory=$true)][string]$BackupPath)
$ErrorActionPreference='Stop'
$Info=Get-Content (Join-Path $BackupPath 'restore-info.json') -Raw | ConvertFrom-Json
$Records=@(Get-Content (Join-Path $BackupPath 'files.json') -Raw | ConvertFrom-Json)
foreach($Process in @(Get-Process eqgame -ErrorAction SilentlyContinue)) {
 try{$Modules=@($Process.Modules)}catch{throw "Cannot inspect EQ process $($Process.Id)."}
 if(!$Modules.Count -or @($Modules|Where-Object{$_.ModuleName -ieq 'MQ2EQBC.dll'}).Count){throw 'Unload MQ2EQBC in every client first.'}
}
if(@(Get-Process 'EQBCS-Go' -ErrorAction SilentlyContinue).Count){throw 'Stop EQBCS-Go first.'}
git -C $Info.dev diff --quiet
if($LASTEXITCODE){throw 'Tracked Triune edits exist; stopped.'}
git -C $Info.dev diff --cached --quiet
if($LASTEXITCODE){throw 'Staged Triune edits exist; stopped.'}
foreach($Record in $Records){
 if(!(Test-Path -LiteralPath $Record.path) -or (Get-FileHash -LiteralPath $Record.path).Hash -ne $Record.installedHash){throw "File changed after installation: $($Record.path); stopped."}
 if($Record.existed -and !(Test-Path -LiteralPath $Record.backup)){throw "Backup missing: $($Record.backup)"}
 $Stream=[IO.File]::Open($Record.path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$Stream.Close()
}
foreach($Record in $Records){
 if($Record.existed){Copy-Item -LiteralPath $Record.backup -Destination $Record.path -Force}
 else{Remove-Item -LiteralPath $Record.path}
}
foreach($Link in @($Info.links)){
 $Item=Get-Item -LiteralPath $Link -ErrorAction SilentlyContinue
 if($Item -and $Item.LinkType -eq 'SymbolicLink'){Remove-Item -LiteralPath $Link}
}
$Rollback='nero/connection-rollback-'+[guid]::NewGuid().ToString('N').Substring(0,8)
git -C $Info.dev switch -c $Rollback $Info.before
if($LASTEXITCODE){throw 'Files restored; checkout rollback failed. Stop Triune until checkout is resolved.'}
Write-Host 'Restored original client DLL, Go server and development source. INIs preserved. Load MQ2EQBC and restart Triune.'
