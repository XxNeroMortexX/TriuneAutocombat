# Created By: NeroMorte - restore only an unchanged focused updater installation.
param([Parameter(Mandatory=$true)][string]$Backup)
$ErrorActionPreference='Stop'
$Info=Get-Content -LiteralPath (Join-Path $Backup 'restore-info.json') -Raw | ConvertFrom-Json
foreach($Process in @(Get-Process eqgame -ErrorAction SilentlyContinue)){
 try{$Modules=@($Process.Modules)}catch{throw "Cannot inspect EQ $($Process.Id); run elevated or close that client."}
 if(!$Modules.Count -or @($Modules | Where-Object {$_.ModuleName -ieq 'MQ2WebUpdate.dll'}).Count){throw "Unload MQ2WebUpdate in EQ $($Process.Id) first."}
}
foreach($Record in $Info.records){
 if(!$Record.installedHash -or !(Test-Path -LiteralPath $Record.path) -or (Get-FileHash -LiteralPath $Record.path).Hash -ne $Record.installedHash){throw "File changed since test install: $($Record.path). Stopped."}
 if($Record.existed -and !(Test-Path -LiteralPath $Record.backup)){throw "Backup missing: $($Record.backup)"}
 $Stream=[IO.File]::Open($Record.path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);$Stream.Close()
}
foreach($Record in $Info.records){
 if($Record.existed){Copy-Item -LiteralPath $Record.backup -Destination $Record.path -Force}
 else{Remove-Item -LiteralPath $Record.path}
}
Write-Host 'Previous updater DLL and native sources restored. Load MQ2WebUpdate when ready.'
