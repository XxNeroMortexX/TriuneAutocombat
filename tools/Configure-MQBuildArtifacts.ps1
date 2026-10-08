# Created By: NeroMorte - Persist shared MQ C++ artifact paths and relocate existing build-only files.
# This evaluates MSBuild settings, never builds or replaces a DLL/EXE. Do not run while compiling.
param(
    [ValidateSet('Install','Restore')][string]$Action='Install',
    [string]$Root='E:\MQ2Next\macroquest',
    [ValidateSet('Win32','x64')][string]$Platform='Win32',
    [string]$BackupPath,
    [string]$PreflightPath
)
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath($Root).TrimEnd('\')
$Artifacts=Join-Path $Root 'build\artifacts'
function Assert-NoLink([string]$Path) {
    $Current=[IO.Path]::GetFullPath($Path)
    while ($Current) {
        $Item=Get-Item -LiteralPath $Current -Force -ErrorAction SilentlyContinue
        if ($Item -and ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Linked build path is unsupported: $Current" }
        $Parent=Split-Path -Parent $Current
        if (!$Parent -or $Parent -eq $Current) { break }
        $Current=$Parent
    }
}
function Save-Record($Record,[string]$Path) {
    $Temp=$Path+'.writing'
    $Record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Temp -Encoding UTF8
    Move-Item -LiteralPath $Temp -Destination $Path -Force
}
function Undo-Record($Record,[string]$Backup,[bool]$CheckEdits=$false) {
    # Verify every reverse move before changing anything.
    if ($CheckEdits) {
        foreach ($Edit in $Record.edits) {
            if ((Get-FileHash -LiteralPath $Edit.path -Algorithm SHA256).Hash -ne $Edit.installedHash) { throw "Settings changed since installation: $($Edit.path)" }
        }
        if ((Test-Path -LiteralPath $Record.hook) -and (Get-FileHash -LiteralPath $Record.hook -Algorithm SHA256).Hash -ne $Record.hookHash) { throw 'Artifact hook changed since installation; stopped.' }
    }
    foreach ($Move in $Record.moves) {
        if (Test-Path -LiteralPath $Move.to) {
            Assert-NoLink $Move.to
            Assert-NoLink $Move.from
            if (Test-Path -LiteralPath $Move.from) { throw "Rollback collision: $($Move.from)" }
            if (!$Move.directory -and (Get-FileHash -LiteralPath $Move.to -Algorithm SHA256).Hash -ne $Move.hash) { throw "Moved file changed: $($Move.to)" }
        } elseif (!(Test-Path -LiteralPath $Move.from)) { throw "Both move locations missing: $($Move.from)" }
    }
    foreach ($Edit in $Record.edits) {
        Assert-NoLink $Edit.path
        if (!(Test-Path -LiteralPath $Edit.saved)) { throw "Configuration backup missing: $($Edit.saved)" }
    }
    for ($i=$Record.moves.Count-1;$i -ge 0;$i--) {
        $Move=$Record.moves[$i]
        if (Test-Path -LiteralPath $Move.to) {
            New-Item -ItemType Directory -Path (Split-Path -Parent $Move.from) -Force | Out-Null
            Move-Item -LiteralPath $Move.to -Destination $Move.from
        }
    }
    foreach ($Edit in $Record.edits) { Copy-Item -LiteralPath $Edit.saved -Destination $Edit.path -Force }
    if ($Record.createdHook -and (Test-Path -LiteralPath $Record.hook)) { Remove-Item -LiteralPath $Record.hook }
}
if (Get-Process -Name @('MSBuild','cl','link','lib') -ErrorAction SilentlyContinue) { throw 'A build tool is running. Finish/stop the build and close Visual Studio before changing paths.' }
if ($Action -eq 'Restore') {
    if (!$BackupPath) { throw 'Supply the installation backup path.' }
    $Record=Get-Content -LiteralPath (Join-Path $BackupPath 'restore.json') -Raw | ConvertFrom-Json
    Undo-Record $Record $BackupPath $true
    Write-Host 'Restored shared build settings and moved artifacts to their previous paths.'
    return
}
$Common=Join-Path $Root 'src\Common.props'
$Plugin=Join-Path $Root 'src\Plugin.props'
$Hook=Join-Path $Root 'src\NeroMorte.Artifacts.targets'
foreach ($Path in @($Common,$Plugin,$Hook,$Artifacts)) { Assert-NoLink $Path }
if (Test-Path -LiteralPath $Hook) { throw 'Artifact configuration is already present. Stopped without overwriting it.' }
$VsWhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (!(Test-Path -LiteralPath $VsWhere)) { throw 'Cannot locate vswhere.exe.' }
$MSBuild=@(& $VsWhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe') | Select-Object -First 1
if (!$MSBuild -or !(Test-Path -LiteralPath $MSBuild)) { throw 'Cannot locate MSBuild.' }
$Edits=New-Object 'System.Collections.Generic.List[object]'
function Add-Edit([string]$Path,[string]$New) {
    [xml]$Checked=$New
    $Edits.Add([pscustomobject]@{path=$Path;text=$New;saved=$null})
}
function Replace-Exact([string]$Text,[string]$Old,[string]$New,[int]$Count) {
    if ([regex]::Matches($Text,[regex]::Escape($Old)).Count -ne $Count) { throw "Unexpected build setting; stopped: $Old" }
    return $Text.Replace($Old,$New)
}
$Text=[IO.File]::ReadAllText($Common)
$NL=if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
$Text=Replace-Exact $Text '<MQLibDir>$(MQBuildDirectory)lib\$(Platform)\$(MQBinaryDirName)\</MQLibDir>' '<!-- Edited By: NeroMorte - keep build libraries outside runtime. --><MQLibDir>$(MQArtifactsDirectory)lib\$(Platform)\$(MQBinaryDirName)\</MQLibDir>' 2
$Text=Replace-Exact $Text '<IntDir>$(MQBuildDirectory)obj\$(Platform)\$(MQBinaryDirName)\$(ProjectName)\</IntDir>' '<!-- Edited By: NeroMorte - consolidate compiler intermediates. --><IntDir>$(MQArtifactsDirectory)obj\$(Platform)\$(MQBinaryDirName)\$(ProjectName)\</IntDir>' 2
$Text=Replace-Exact $Text '<MQBuildDirectory>$(MQRoot)build\</MQBuildDirectory>' ('<MQBuildDirectory>$(MQRoot)build\</MQBuildDirectory>'+$NL+'    <!-- Edited By: NeroMorte - single artifact parent. -->'+$NL+'    <MQArtifactsDirectory>$(MQRoot)build\artifacts\</MQArtifactsDirectory>') 1
$Text=Replace-Exact $Text '<MQBuildDirectory>$(MQRoot)build\$(eqlibClientTarget)\</MQBuildDirectory>' ('<MQBuildDirectory>$(MQRoot)build\$(eqlibClientTarget)\</MQBuildDirectory>'+$NL+'    <!-- Edited By: NeroMorte - separate clients within the same artifact parent. -->'+$NL+'    <MQArtifactsDirectory>$(MQRoot)build\artifacts\$(eqlibClientTarget)\</MQArtifactsDirectory>') 1
$Import=@'
  <!-- Edited By: NeroMorte - apply final linker defaults after project property groups. -->
  <PropertyGroup>
    <MQ2LibDir>$(MQLibDir)</MQ2LibDir>
    <ForceImportAfterCppTargets Condition="'$(NeroMorteArtifactsHookSet)'!='true' And '$(ForceImportAfterCppTargets)'==''">$(MQRoot)src\NeroMorte.Artifacts.targets</ForceImportAfterCppTargets>
    <ForceImportAfterCppTargets Condition="'$(NeroMorteArtifactsHookSet)'!='true' And '$(ForceImportAfterCppTargets)'!='' And '$(ForceImportAfterCppTargets)'!='$(MQRoot)src\NeroMorte.Artifacts.targets'">$(ForceImportAfterCppTargets);$(MQRoot)src\NeroMorte.Artifacts.targets</ForceImportAfterCppTargets>
    <NeroMorteArtifactsHookSet>true</NeroMorteArtifactsHookSet>
  </PropertyGroup>
'@
$Text=Replace-Exact $Text '</Project>' ($Import.Replace("`r`n","`n").Replace("`n",$NL)+$NL+'</Project>') 1
Add-Edit $Common $Text
$Text=[IO.File]::ReadAllText($Plugin)
$Text=Replace-Exact $Text '<AdditionalLibraryDirectories>$(MQBuildDirectory)bin\$(MQBinaryDirName);%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>' '<!-- Edited By: NeroMorte - resolve relocated core import libraries. --><AdditionalLibraryDirectories>$(MQLibDir);$(MQBuildDirectory)bin\$(MQBinaryDirName);%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>' 1
Add-Edit $Plugin $Text
# Created By: NeroMorte - use the reviewed, successful shared-MQ project evaluations.
if (!$PreflightPath) {
    $PreflightPath=Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'MQ-artifact-preflight-*' |
        Sort-Object LastWriteTime -Descending | ForEach-Object {
            $Candidate=Join-Path $_.FullName 'preflight.txt'
            if (Test-Path -LiteralPath $Candidate) { $Candidate }
        } | Select-Object -First 1
}
if (!$PreflightPath -or !(Test-Path -LiteralPath $PreflightPath)) { throw 'Supply the reviewed report with -PreflightPath.' }
$Report=[IO.File]::ReadAllText($PreflightPath)
$Projects=New-Object 'System.Collections.Generic.List[object]'
$Skipped=New-Object 'System.Collections.Generic.List[string]'
$Pattern='(?ms)^PROJECT: (?<path>[^\r\n]+)\r?\n(?<body>.*?)(?=^PROJECT: |^EXPLICIT ARTIFACT|\z)'
foreach ($Match in [regex]::Matches($Report,$Pattern)) {
    $Path=$Match.Groups['path'].Value.Trim()
    try { $OldProps=($Match.Groups['body'].Value | ConvertFrom-Json).Properties } catch { $Skipped.Add($Path); continue }
    if (!$OldProps.MQLibDir) { $Skipped.Add($Path); continue }
    Assert-NoLink $Path
    if (!(Test-Path -LiteralPath $Path) -or !$Path.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Reviewed project path is invalid: $Path" }
    Write-Host "Checking reviewed baseline: $([IO.Path]::GetFileNameWithoutExtension($Path))"
    $Raw=& $MSBuild $Path /nologo '/p:Configuration=Release' "/p:Platform=$Platform" '/p:MQ_BUILD_SEPARATE=0' '/getProperty:IntDir,OutDir,MQLibDir,MQBuildDirectory,TargetPath,ForceImportBeforeCppTargets,ForceImportAfterCppTargets'
    if ($LASTEXITCODE -ne 0) { throw "Baseline evaluation failed; no settings changed: $Path" }
    $Before=(($Raw -join "`n") | ConvertFrom-Json).Properties
    foreach ($Key in @('IntDir','OutDir','MQLibDir','MQBuildDirectory','TargetPath','ForceImportBeforeCppTargets','ForceImportAfterCppTargets')) {
        if ($Before.$Key -ne $OldProps.$Key) { throw "Project changed since preflight: $Path ($Key). No settings changed." }
    }
    $Project=Get-Item -LiteralPath $Path
    $Projects.Add([pscustomobject]@{FullName=$Path;BaseName=$Project.BaseName;before=$Before})
    $ProjectText=[IO.File]::ReadAllText($Path)
    $Old='<IntDir>$(MQBuildDirectory)obj\$(Platform)\$(MQBinaryDirName)\$(ProjectName)\</IntDir>'
    if ($ProjectText.Contains($Old)) {
        Add-Edit $Path ($ProjectText.Replace($Old,'<!-- Edited By: NeroMorte - retain shared artifact directory in project overrides. --><IntDir>$(MQArtifactsDirectory)obj\$(Platform)\$(MQBinaryDirName)\$(ProjectName)\</IntDir>'))
    }
}
if ($Projects.Count -lt 4) { throw 'Too few successful shared MQ projects in the reviewed report; stopped.' }
$BackupPath=Join-Path $Artifacts ('Backup\layout-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
$Record=[pscustomobject]@{root=$Root;hook=$Hook;createdHook=$true;edits=@();moves=@();status='prepared'}
foreach ($Edit in $Edits) {
    $Relative=$Edit.path.Substring($Root.Length).TrimStart('\')
    $Edit.saved=Join-Path $BackupPath $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $Edit.saved) -Force | Out-Null
    Copy-Item -LiteralPath $Edit.path -Destination $Edit.saved
    $Record.edits += [pscustomobject]@{path=$Edit.path;saved=$Edit.saved}
}
$Manifest=Join-Path $BackupPath 'restore.json'
Save-Record $Record $Manifest
$HookText=@'
<?xml version="1.0" encoding="utf-8"?>
<!-- Created By: NeroMorte - final C++ defaults for non-runtime artifacts. -->
<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <NeroMorteSymbolsDir>$(MQArtifactsDirectory)symbols\$(Platform)\$(MQBinaryDirName)\</NeroMorteSymbolsDir>
  </PropertyGroup>
  <ItemDefinitionGroup>
    <ClCompile>
      <ProgramDataBaseFileName>$(IntDir)$(MSBuildProjectName).compiler.pdb</ProgramDataBaseFileName>
      <PrecompiledHeaderOutputFile>$(IntDir)$(MSBuildProjectName).pch</PrecompiledHeaderOutputFile>
    </ClCompile>
    <Link>
      <ProgramDatabaseFile>$(NeroMorteSymbolsDir)$(TargetName).pdb</ProgramDatabaseFile>
      <ImportLibrary>$(MQLibDir)$(TargetName).lib</ImportLibrary>
      <IncrementalLinkDatabaseFile>$(IntDir)$(TargetName).ilk</IncrementalLinkDatabaseFile>
      <AdditionalLibraryDirectories>$(MQLibDir);%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
    </Link>
  </ItemDefinitionGroup>
  <Target Name="NeroMorteCreateArtifactDirectories" BeforeTargets="PrepareForBuild">
    <MakeDir Directories="$(IntDir);$(MQLibDir);$(NeroMorteSymbolsDir)" />
  </Target>
  <Target Name="NeroMorteInspectArtifacts">
    <ItemGroup><Link Include="__nero_layout_probe__" /></ItemGroup>
    <WriteLinesToFile File="$(NeroMorteInspectFile)" Overwrite="true"
      Lines="Root=$(MQArtifactsDirectory);IntDir=$(IntDir);OutDir=$(OutDir);Libraries=$(MQLibDir);PDB=%(Link.ProgramDatabaseFile);ImportLibrary=%(Link.ImportLibrary);TargetPath=$(TargetPath)"
      Condition="'%(Link.Identity)'=='__nero_layout_probe__'" />
  </Target>
</Project>
'@
try {
    [IO.File]::WriteAllText($Hook,$HookText,(New-Object Text.UTF8Encoding($false)))
    foreach ($Edit in $Edits) { [IO.File]::WriteAllText($Edit.path,$Edit.text,(New-Object Text.UTF8Encoding($false))) }
    $LogDir=Join-Path $BackupPath 'evaluation'
    New-Item -ItemType Directory -Path $LogDir | Out-Null
    foreach ($Project in $Projects) {
        $Index=$Projects.IndexOf($Project)
        $Output=Join-Path $LogDir ($Index.ToString()+'-'+$Project.BaseName+'.txt')
        $Log=$Output+'.log'
        Write-Host "Checking saved settings: $($Project.BaseName)"
        & $MSBuild $Project.FullName /nologo /v:minimal /t:NeroMorteInspectArtifacts '/p:Configuration=Release' "/p:Platform=$Platform" '/p:MQ_BUILD_SEPARATE=0' "/p:NeroMorteInspectFile=$Output" *> $Log
        if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $Output)) { throw "MSBuild evaluation failed: $($Project.FullName). Details: $Log" }
        $Values=@{}
        foreach ($Line in Get-Content -LiteralPath $Output) { $Pair=$Line.Split(@('='),2); if ($Pair.Count -eq 2) { $Values[$Pair[0]]=$Pair[1] } }
        foreach ($Key in @('Root','IntDir','Libraries','PDB','ImportLibrary')) {
            if (!$Values[$Key] -or !([IO.Path]::GetFullPath($Values[$Key])).StartsWith($Artifacts+'\',[StringComparison]::OrdinalIgnoreCase)) { throw "Project artifact path escaped the new folder: $($Project.BaseName) $Key=$($Values[$Key])" }
        }
        $Before=$Project.before
        if ([IO.Path]::GetExtension($Before.TargetPath) -ne '.lib') {
            if ([IO.Path]::GetFullPath($Values.OutDir) -ine [IO.Path]::GetFullPath($Before.OutDir) -or
                [IO.Path]::GetFullPath($Values.TargetPath) -ine [IO.Path]::GetFullPath($Before.TargetPath)) {
                throw "Runtime output changed: $($Project.BaseName)"
            }
        } elseif (!([IO.Path]::GetFullPath($Values.TargetPath)).StartsWith($Artifacts+'\',[StringComparison]::OrdinalIgnoreCase)) {
            throw "Static library output escaped artifact folder: $($Project.BaseName)"
        }
    }
    # Directory moves preserve cached files without duplicating large intermediate trees.
    $Build=Join-Path $Root 'build'
    $Bases=@([pscustomobject]@{path=$Build;prefix=''})
    foreach ($Dir in Get-ChildItem -LiteralPath $Build -Directory) {
        if ($Dir.Name -notin @('artifacts','bin','obj','lib') -and (Test-Path -LiteralPath (Join-Path $Dir.FullName 'bin'))) {
            $Bases += [pscustomobject]@{path=$Dir.FullName;prefix=$Dir.Name}
        }
    }
    $Plan=@()
    foreach ($Base in $Bases) {
        foreach ($Name in @('obj','lib')) {
            $From=Join-Path $Base.path $Name
            if (Test-Path -LiteralPath $From) {
                $To=Join-Path (Join-Path $Artifacts $Base.prefix) $Name
                Assert-NoLink $From; Assert-NoLink $To
                if (Test-Path -LiteralPath $To) { throw "Artifact destination already exists: $To" }
                $Plan += [pscustomobject]@{from=$From;to=$To;directory=$true;hash=$null}
            }
        }
    }
    $Conflicts=@()
    $Bin=Join-Path $Root 'build\bin\release'
    $Extensions=@('.pdb','.lib','.exp','.obj','.pch','.ipch','.ilk','.idb','.iobj','.ipdb','.tlog','.lastbuildstate')
    foreach ($Directory in @($Bin,(Join-Path $Bin 'plugins'))) {
        foreach ($File in Get-ChildItem -LiteralPath $Directory -File -ErrorAction Stop) {
            if ($File.Extension.ToLowerInvariant() -notin $Extensions) { continue }
            Assert-NoLink $File.FullName
            if ($File.Extension -in @('.lib','.exp')) { $Sub='lib' }
            elseif ($File.Extension -eq '.pdb') { $Sub='symbols' }
            else { $Sub='legacy-runtime' }
            $To=Join-Path (Join-Path (Join-Path (Join-Path $Artifacts $Sub) $Platform) 'release') $File.Name
            if (Test-Path -LiteralPath $To) { throw "Artifact destination already exists: $To" }
            # Do not overwrite a file that will arrive with the old lib tree.
            foreach ($Move in $Plan) {
                if ($Move.directory -and $To.StartsWith($Move.to+'\',[StringComparison]::OrdinalIgnoreCase)) {
                    $OldCandidate=Join-Path $Move.from $To.Substring($Move.to.Length+1)
                    if (Test-Path -LiteralPath $OldCandidate) {
                        # Preserve the older library-tree copy separately; the runtime copy
                        # accompanies the currently deployed DLL and becomes the primary import lib.
                        $Archived=Join-Path (Join-Path $Artifacts 'legacy-runtime\previous-lib-tree') $To.Substring($Move.to.Length+1)
                        if (Test-Path -LiteralPath $Archived) { throw "Prior-library archive already exists: $Archived" }
                        $OldHandle=[IO.File]::Open($OldCandidate,'Open','Read','None'); $OldHandle.Dispose()
                        $Conflicts += [pscustomobject]@{from=$OldCandidate;to=$Archived;directory=$false;hash=(Get-FileHash -LiteralPath $OldCandidate -Algorithm SHA256).Hash}
                    }
                }
            }
            $Handle=[IO.File]::Open($File.FullName,'Open','Read','None'); $Handle.Dispose()
            $Plan += [pscustomobject]@{from=$File.FullName;to=$To;directory=$false;hash=(Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash}
        }
    }
    $Plan=@($Conflicts)+@($Plan)
    if (($Plan | Group-Object to | Where-Object Count -gt 1)) { throw 'Two artifacts map to the same destination; stopped.' }
    foreach ($Move in $Plan) {
        $Record.moves += $Move
        Save-Record $Record $Manifest
        New-Item -ItemType Directory -Path (Split-Path -Parent $Move.to) -Force | Out-Null
        Move-Item -LiteralPath $Move.from -Destination $Move.to
        if (!$Move.directory -and (Get-FileHash -LiteralPath $Move.to -Algorithm SHA256).Hash -ne $Move.hash) { throw 'Moved file hash verification failed.' }
    }
    foreach ($Edit in $Record.edits) { $Edit | Add-Member -NotePropertyName installedHash -NotePropertyValue (Get-FileHash -LiteralPath $Edit.path -Algorithm SHA256).Hash }
    $Record | Add-Member -NotePropertyName hookHash -NotePropertyValue (Get-FileHash -LiteralPath $Hook -Algorithm SHA256).Hash
    $Record.status='installed' 
    Save-Record $Record $Manifest
} catch {
    $Reason=$_
    try { Undo-Record $Record $BackupPath } catch { throw "Installation stopped; rollback also needs review. Backup: $BackupPath. Original: $Reason. Rollback: $_" }
    throw "Installation stopped; previous settings and artifact locations restored. Backup: $BackupPath. $Reason"
}
Write-Host "Configured persistent shared MQ C++ artifact folder: $Artifacts"
Write-Host "Verified $($Projects.Count) Release/$Platform project settings without compiling."
Write-Host "Moved $($Record.moves.Count) existing artifact files/directories. Runtime EXEs/DLLs/Lua/resources were not replaced."
Write-Host "Backup and evaluation logs: $BackupPath"
Write-Host "Rollback: powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$PSCommandPath' -Action Restore -BackupPath '$BackupPath'"
foreach ($Path in $Skipped) { Write-Host "Outside the shared MQ change (preflight failed or legacy standalone): $Path" }
Write-Host 'Reopen Visual Studio to load the saved settings. A normal build may regenerate moved caches; test a build before deleting any backup.'
