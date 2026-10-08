# Created By: NeroMorte - Triune XYZ completion integration test; isolated build and verified restore.
param(
    [ValidateSet('BuildInstall','RestoreWorking')][string]$Action = 'BuildInstall',
    [string]$UpgradePath,
    [string]$Nav = 'E:\MQ2Next\macroquest\plugins\MQ2Nav',
    [string]$RuntimeDll = 'E:\MQ2Next\macroquest\build\bin\release\plugins\MQ2Nav.dll',
    [string]$BackupRoot = 'E:\MQ2Next\TriuneGUIBackups'
)
$ErrorActionPreference = 'Stop'
if ([Environment]::Is64BitProcess) {
    $Arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,'-Action',$Action,'-Nav',$Nav,'-RuntimeDll',$RuntimeDll,'-BackupRoot',$BackupRoot)
    if ($UpgradePath) { $Arguments += @('-UpgradePath',$UpgradePath) }
    & "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'XYZ integration installation stopped; review the output.' }
    exit
}
function File-Hash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Text-Hash([string]$Path) {
    $Bytes = [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($Path).Replace("`r`n", "`n"))
    $Hasher = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($Hasher.ComputeHash($Bytes))).Replace('-', '') }
    finally { $Hasher.Dispose() }
}
function Write-Text([string]$Path, [string]$Value) {
    [IO.File]::WriteAllText($Path, $Value, (New-Object System.Text.UTF8Encoding($false)))
}
function Check-Unloaded {
    foreach ($Client in @(Get-Process -Name eqgame -ErrorAction SilentlyContinue)) {
        try {
            $Modules = @($Client.Modules)
            if ($Modules.Count -eq 0) {
                if ($Client.HasExited) { continue }
                throw 'No process module information returned.'
            }
            $NavLoaded = @($Modules | Where-Object { $_.ModuleName -ieq 'MQ2Nav.dll' }).Count -gt 0
        } catch { throw "Cannot inspect EQ client $($Client.Id). Run PowerShell as Administrator; stopped." }
        if ($NavLoaded) { throw "Unload MQ2Nav in EQ client $($Client.Id) before running this script." }
    }
    Write-Host 'Verified: MQ2Nav.dll is unloaded in every running EQ client.'
}
function Check-X86([string]$Path) {
    $Bytes = [IO.File]::ReadAllBytes($Path)
    if ($Bytes.Length -lt 64 -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) { throw 'Expected a PE DLL.' }
    $Offset = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($Offset -lt 0 -or $Offset + 6 -gt $Bytes.Length -or [BitConverter]::ToUInt32($Bytes, $Offset) -ne 0x4550) { throw 'Invalid PE header.' }
    if ([BitConverter]::ToUInt16($Bytes, $Offset + 4) -ne 0x14C) { throw 'Expected the Win32/x86 DLL.' }
}

# Created By: NeroMorte - Read the exported plugin float from PE bytes without loading the DLL.
function Read-NavPluginVersion([string]$Path) {
    Check-X86 $Path
    $Bytes = [IO.File]::ReadAllBytes($Path)
    $Pe = [BitConverter]::ToInt32($Bytes, 0x3C)
    $Optional = $Pe + 24
    if ([BitConverter]::ToUInt16($Bytes, $Optional) -ne 0x10B) { throw 'Expected PE32 optional header.' }
    $Sections = [BitConverter]::ToUInt16($Bytes, $Pe + 6)
    $Table = $Optional + [BitConverter]::ToUInt16($Bytes, $Pe + 20)
    function Rva-Offset([uint32]$Rva, [int]$Count) {
        for ($Index = 0; $Index -lt $Sections; $Index++) {
            $Section = $Table + $Index * 40
            $Virtual = [BitConverter]::ToUInt32($Bytes, $Section + 12)
            $RawSize = [BitConverter]::ToUInt32($Bytes, $Section + 16)
            $Raw = [BitConverter]::ToUInt32($Bytes, $Section + 20)
            if ($Rva -ge $Virtual -and ([long]$Rva + $Count) -le ([long]$Virtual + $RawSize)) {
                $Offset = [long]$Raw + $Rva - $Virtual
                if ($Offset -lt 0 -or $Offset + $Count -gt $Bytes.Length) { throw 'Invalid export offset.' }
                return [int]$Offset
            }
        }
        throw 'Export RVA is outside file-backed sections.'
    }
    $ExportRva = [BitConverter]::ToUInt32($Bytes, $Optional + 96)
    if ($ExportRva -eq 0) { throw 'DLL has no export directory.' }
    $Export = Rva-Offset $ExportRva 40
    $FunctionCount = [BitConverter]::ToUInt32($Bytes, $Export + 20)
    $NameCount = [BitConverter]::ToUInt32($Bytes, $Export + 24)
    if ($FunctionCount -gt 65536 -or $NameCount -gt 65536) { throw 'Unexpected export table size.' }
    $Functions = Rva-Offset ([BitConverter]::ToUInt32($Bytes, $Export + 28)) ([int]$FunctionCount * 4)
    $Names = Rva-Offset ([BitConverter]::ToUInt32($Bytes, $Export + 32)) ([int]$NameCount * 4)
    $Ordinals = Rva-Offset ([BitConverter]::ToUInt32($Bytes, $Export + 36)) ([int]$NameCount * 2)
    for ($Index = 0; $Index -lt $NameCount; $Index++) {
        $Name = Rva-Offset ([BitConverter]::ToUInt32($Bytes, $Names + $Index * 4)) 1
        $End = $Name
        while ($End -lt $Bytes.Length -and $End - $Name -lt 256 -and $Bytes[$End] -ne 0) { $End++ }
        if ($End -ge $Bytes.Length -or $Bytes[$End] -ne 0) { throw 'Invalid export name.' }
        $Symbol = [Text.Encoding]::ASCII.GetString($Bytes, $Name, $End - $Name)
        if ($Symbol -eq '?MQ2Version@@3MA') {
            $Ordinal = [BitConverter]::ToUInt16($Bytes, $Ordinals + $Index * 2)
            if ($Ordinal -ge $FunctionCount) { throw 'Invalid plugin export ordinal.' }
            $Value = Rva-Offset ([BitConverter]::ToUInt32($Bytes, $Functions + $Ordinal * 4)) 4
            return [BitConverter]::ToSingle($Bytes, $Value)
        }
    }
    throw 'MQ2Version export is missing; refusing installation.'
}


$Expected = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'integration-hashes.json') -Raw | ConvertFrom-Json
$Branch = (& git -C $Nav branch --show-current)
if ($LASTEXITCODE -ne 0 -or $Branch.Trim() -ne 'nero/nav-xyz-test') { throw 'Expected the Nav test branch; no files changed.' }
$Head = (& git -C $Nav rev-parse HEAD)
if ($LASTEXITCODE -ne 0 -or $Head.Trim() -ne $Expected.base_commit) { throw 'Nav HEAD changed; no files changed.' }
function Assert-Regular([string]$Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing file: $Path" }
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unexpected link: $Path; stopped." }
}
function Replace-Dll([string]$Source, [string]$Destination, [string]$Folder) {
    Check-Unloaded
    Assert-Regular $Destination
    $Temp = "$Destination.nero-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Copy-Item -LiteralPath $Source -Destination $Temp
        if ((File-Hash $Temp) -ne (File-Hash $Source)) { throw 'Staged DLL verification failed.' }
        [IO.File]::Replace($Temp, $Destination, (Join-Path $Folder ('MQ2Nav.before-replace-' + [guid]::NewGuid().ToString('N') + '.dll')))
    } finally {
        if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp }
    }
}
function Restore-Sources([string]$Folder) {
    foreach ($File in $Expected.files) {
        Copy-Item -LiteralPath (Join-Path "$Folder\source-before" $File.name) -Destination (Join-Path "$Nav\plugin" $File.name)
    }
}
if ($Action -eq 'RestoreWorking') {
    if (!$UpgradePath) { throw 'Supply the exact XYZ integration backup directory printed during installation.' }
    $RecordPath = Join-Path $UpgradePath 'integration-install.json'
    $Record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
    if ($Record.nav -ne $Nav -or $Record.runtime_dll -ne $RuntimeDll -or !$Record.installed) { throw 'Wrong or incomplete integration backup.' }
    foreach ($File in $Expected.files) {
        Assert-Regular (Join-Path "$Nav\plugin" $File.name)
        if ((Text-Hash (Join-Path "$Nav\plugin" $File.name)) -ne $File.after_sha256 -or (Text-Hash (Join-Path "$UpgradePath\source-before" $File.name)) -ne $File.before_sha256) { throw "Source changed: $($File.name); stopped." }
    }
    if ((File-Hash $RuntimeDll) -ne $Record.new_dll_hash -or (File-Hash (Join-Path $UpgradePath 'MQ2Nav.working.dll')) -ne $Record.old_dll_hash) { throw 'DLL changed; stopped.' }
    Check-Unloaded
    Replace-Dll (Join-Path $UpgradePath 'MQ2Nav.working.dll') $RuntimeDll $UpgradePath
    Restore-Sources $UpgradePath
    if ((File-Hash $RuntimeDll) -ne $Record.old_dll_hash) { throw 'Restore verification failed.' }
    $Record.installed = $false
    Write-Text $RecordPath ($Record | ConvertTo-Json -Depth 8)
    Write-Host 'Restored the verified 1.3.3.4 DLL and development source. Existing rollback records were preserved.'
    Write-Host 'Load MQ2Nav in every client: /plugin mq2nav load'
    exit
}
foreach ($File in $Expected.files) {
    $Local = Join-Path "$Nav\plugin" $File.name
    Assert-Regular $Local
    if ((Text-Hash $Local) -ne $File.before_sha256) { throw "Expected installed 1.3.3.4 source: $($File.name); no files changed." }
    if ((Text-Hash (Join-Path "$PSScriptRoot\source" $File.name)) -ne $File.after_sha256) { throw "Package hash mismatch: $($File.name)" }
}
Assert-Regular $RuntimeDll
Check-X86 $RuntimeDll
$CurrentVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($RuntimeDll)
if ($CurrentVersion.FileVersion -ne '1.3.3.4' -or [math]::Abs((Read-NavPluginVersion $RuntimeDll) - 1.3304) -gt 0.00001) { throw 'Expected the working 1.3.3.4 settings DLL; no files changed.' }
Check-Unloaded
$VSWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$MSBuild = @(& $VSWhere -latest -products '*' -requires Microsoft.Component.MSBuild Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find 'MSBuild\**\Bin\MSBuild.exe') | Select-Object -First 1
if (!$MSBuild -or !(Test-Path -LiteralPath $MSBuild)) { throw 'Visual Studio C++ MSBuild was not found.' }
$UpgradePath = Join-Path $BackupRoot ('nav-xyz-integration-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6))
$Output = Join-Path $UpgradePath 'build'
New-Item -ItemType Directory -Path $Output -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $UpgradePath 'source-before') -Force | Out-Null
foreach ($File in $Expected.files) {
    Copy-Item -LiteralPath (Join-Path "$Nav\plugin" $File.name) -Destination (Join-Path "$UpgradePath\source-before" $File.name)
}
Copy-Item -LiteralPath $RuntimeDll -Destination (Join-Path $UpgradePath 'MQ2Nav.working.dll')
$OldDllHash = File-Hash $RuntimeDll
if ((File-Hash (Join-Path $UpgradePath 'MQ2Nav.working.dll')) -ne $OldDllHash) { throw 'Working DLL backup verification failed.' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'integration-hashes.json') -Destination (Join-Path $UpgradePath 'integration-hashes.json')
Write-Host "XYZ integration backup: $UpgradePath"
$RecordPath = Join-Path $UpgradePath 'integration-install.json'
$Record = [pscustomobject]@{ nav=$Nav; runtime_dll=$RuntimeDll; old_dll_hash=$OldDllHash; new_dll_hash=''; installed=$false }
Write-Text $RecordPath ($Record | ConvertTo-Json -Depth 8)
$Replaced = $false
try {
    foreach ($File in $Expected.files) {
        Copy-Item -LiteralPath (Join-Path "$PSScriptRoot\source" $File.name) -Destination (Join-Path "$Nav\plugin" $File.name)
    }
    # Created By: NeroMorte - Build with fresh per-project objects, without invoking Clean.
    # Full compilation checks below reject a hook failure or stale object reuse.
    $BuildProps = Join-Path $UpgradePath 'isolated-build.props'
    $SafeObj = [Security.SecurityElement]::Escape((Join-Path $UpgradePath 'obj'))
    Write-Text $BuildProps ('<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003"><PropertyGroup><IntDir>' + $SafeObj + '\$(MSBuildProjectName)\</IntDir></PropertyGroup></Project>')
    $Log = Join-Path $UpgradePath 'build.log'
    & $MSBuild (Join-Path $Nav 'plugin\MQ2Nav.vcxproj') '/m:1' '/t:Build' '/p:Configuration=Release' '/p:Platform=Win32' "/p:ForceImportBeforeCppTargets=$BuildProps" "/p:OutDir=$Output\" "/flp:logfile=$Log;verbosity=normal"
    if ($LASTEXITCODE -ne 0) { throw "Build failed; working DLL was not replaced. Log: $Log" }
    $BuildText = Get-Content -LiteralPath $Log -Raw
    $RequiredUnits = @('pch.cpp','SwitchHandler.cpp','KeybindHandler.cpp','MapAPI.cpp','ModelLoader.cpp','MQ2Navigation.cpp','PluginSettings.cpp','NavigationPath.cpp','NavigationType.cpp','NavMeshLoader.cpp','NavMeshRenderer.cpp','PluginMain.cpp','RenderHandler.cpp','RenderList.cpp','UiController.cpp','Waypoints.cpp')
    foreach ($Unit in $RequiredUnits) {
        if ($BuildText -notmatch ('(?m)^\s*(?:\d+>)?\s*' + [regex]::Escape($Unit) + '\s*$')) { throw "Fresh compilation not confirmed for $Unit; working DLL was not replaced." }
    }
    $BuiltDll = Join-Path $Output 'MQ2Nav.dll'
    Check-X86 $BuiltDll
    $VersionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($BuiltDll)
    if ($VersionInfo.FileVersion -ne $Expected.version -or $VersionInfo.ProductVersion -ne $Expected.version -or $VersionInfo.Comments -notlike '*NeroMorte*' -or $VersionInfo.FileDescription -notlike '*NeroMorte XYZ Integration Test*') { throw 'Built version or credits verification failed.' }
    if ([math]::Abs((Read-NavPluginVersion $BuiltDll) - 1.3305) -gt 0.00001) { throw 'Built internal plugin version is not 1.3305; working DLL was not replaced.' }
    foreach ($File in $Expected.files) {
        if ((Text-Hash (Join-Path "$Nav\plugin" $File.name)) -ne $File.after_sha256) { throw "Source changed during build: $($File.name)" }
    }
    if ((File-Hash $RuntimeDll) -ne $OldDllHash) { throw 'Runtime DLL changed during build; stopped.' }
    $Record.new_dll_hash = File-Hash $BuiltDll
    Write-Text $RecordPath ($Record | ConvertTo-Json -Depth 8)
    Replace-Dll $BuiltDll $RuntimeDll $UpgradePath
    $Replaced = $true
    if ((File-Hash $RuntimeDll) -ne $Record.new_dll_hash) { throw 'Installed DLL hash verification failed.' }
    $Record.installed = $true
    Write-Text $RecordPath ($Record | ConvertTo-Json -Depth 8)
} catch {
    $Failure = $_
    if (!(Test-Path -LiteralPath $RuntimeDll)) {
        Check-Unloaded
        Copy-Item -LiteralPath (Join-Path $UpgradePath 'MQ2Nav.working.dll') -Destination $RuntimeDll
    } elseif ($Replaced -and (File-Hash $RuntimeDll) -eq $Record.new_dll_hash) {
        Replace-Dll (Join-Path $UpgradePath 'MQ2Nav.working.dll') $RuntimeDll $UpgradePath
    }
    if ((File-Hash $RuntimeDll) -eq $OldDllHash) {
        Restore-Sources $UpgradePath
        $Record.installed = $false
        Write-Text $RecordPath ($Record | ConvertTo-Json -Depth 8)
        Write-Host 'Working DLL verified; previous source restored. Review the build log.'
    } else {
        Write-Host "Runtime DLL changed unexpectedly; source and backup retained for review: $UpgradePath"
    }
    throw $Failure
}
Write-Host 'Installed and verified MQ2Nav 1.3.3.5 - NeroMorte XYZ Integration Test.'
Write-Host 'Load Nav: /plugin mq2nav load. Keep Triune stopped for the first checks.'
Write-Host 'Open /nav ui -> Settings -> General, or MacroQuest Settings -> Plugins -> Nav.'
Write-Host 'Enable Auto XYZ and Accept close stalled XYZ spawn arrival. Defaults: 5 seconds, distance limit 5.'
Write-Host 'Target leader, then /nav target dist=2 (no xyz parameter).'
Write-Host 'Per-route override remains available: /nav target dist=2 xyz=off'
Write-Host 'To restore the working 1.3.3.4 test, unload Nav everywhere, then run:'
Write-Host "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action RestoreWorking -UpgradePath `"$UpgradePath`""
