param(
    [Parameter(Mandatory=$true)][ValidateSet('Install','Rollback','InspectNew','InspectOld')][string]$Action,
    [Parameter(Mandatory=$true)][string]$RuntimeRoot,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$ProfileID,
    [Parameter(Mandatory=$true)][ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$PluginName,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$CommitSHA,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$NewSHA256,
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$OldSHA256,
    [Parameter(Mandatory=$true)][ValidateSet('0','1')][string]$OldPresent
)

$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($RuntimeRoot).TrimEnd('\')
if ($Root -notmatch '^[A-Za-z]:\\' -or $Root -match '["%!&|<>^]') { throw 'Invalid runtime directory.' }
if ($OldPresent -eq '0' -and $OldSHA256 -ne ('0' * 64)) { throw 'Invalid absent-file marker.' }
$DllName = "$PluginName.dll"
$Plugins = Join-Path $Root 'plugins'
$Live = Join-Path $Plugins $DllName
$Payload = Join-Path $Root 'webupdate_stage\dll-handoff-payload.dll'
$BackupDir = Join-Path $Root "webupdate_backup\$ProfileID\dll\$PluginName\$CommitSHA"
$Backup = Join-Path $BackupDir $DllName
$Temp = Join-Path $Plugins "$DllName.handoff.tmp"
$RollbackDiscard = Join-Path $Plugins "$DllName.rollback-discard.tmp"

function Assert-Directory([string]$Path) {
    if (!(Test-Path -LiteralPath $Path -PathType Container)) { throw "Missing directory: $Path" }
    $Item = Get-Item -LiteralPath $Path -Force
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Protected linked directory: $Path"
    }
}
function Assert-Regular([string]$Path) {
    $Item = Get-Item -LiteralPath $Path -Force
    if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Protected or nonregular file: $Path"
    }
}
function Assert-Hash([string]$Path, [string]$Expected) {
    Assert-Regular $Path
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
        throw "Hash mismatch: $Path"
    }
}
function Assert-PE32([string]$Path) {
    $Stream = [IO.File]::OpenRead($Path)
    try {
        if ($Stream.Length -lt 512) { throw 'DLL is too small.' }
        $Header = New-Object byte[] 512
        [void]$Stream.Read($Header, 0, 512)
        $Offset = [BitConverter]::ToUInt32($Header, 0x3c)
        if ($Offset -gt $Stream.Length - 26) { throw 'Invalid PE header offset.' }
        $Stream.Position = $Offset
        $Pe = New-Object byte[] 26
        [void]$Stream.Read($Pe, 0, 26)
        if ($Header[0] -ne 77 -or $Header[1] -ne 90 -or
            $Pe[0] -ne 80 -or $Pe[1] -ne 69 -or $Pe[2] -ne 0 -or $Pe[3] -ne 0 -or
            [BitConverter]::ToUInt16($Pe,4) -ne 0x14c -or
            ([BitConverter]::ToUInt16($Pe,22) -band 0x2000) -eq 0 -or
            [BitConverter]::ToUInt16($Pe,24) -ne 0x10b) {
            throw 'Expected a PE32 x86 DLL.'
        }
    } finally { $Stream.Dispose() }
}
function Assert-BackupPath {
    $Current = $Root
    foreach ($Part in @('webupdate_backup', $ProfileID, 'dll', $PluginName, $CommitSHA)) {
        $Current = Join-Path $Current $Part
        if (Test-Path -LiteralPath $Current) { Assert-Directory $Current }
    }
    if (Test-Path -LiteralPath $Backup) { Assert-Regular $Backup }
}

Assert-Directory $Root
Assert-Directory $Plugins
Assert-Directory (Join-Path $Root 'webupdate_stage')
if (Test-Path -LiteralPath $Live) { Assert-Regular $Live }
if (Test-Path -LiteralPath $Temp) { throw 'Handoff temporary file exists; manual recovery required.' }
if (Test-Path -LiteralPath $RollbackDiscard) {
    Assert-Hash $RollbackDiscard $NewSHA256
    if ($OldPresent -ne '1' -or !(Test-Path -LiteralPath $Live)) {
        throw 'Rollback discard file has no verifiable original DLL.'
    }
    Assert-Hash $Live $OldSHA256
    Remove-Item -LiteralPath $RollbackDiscard
}
Assert-BackupPath

if ($Action -eq 'InspectNew') {
    Assert-Hash $Live $NewSHA256
    exit 0
}
if ($Action -eq 'InspectOld') {
    if ($OldPresent -eq '1') { Assert-Hash $Live $OldSHA256 }
    elseif (Test-Path -LiteralPath $Live) { throw 'Unexpected installed plugin.' }
    exit 0
}
if ($Action -eq 'Install') {
    Assert-Hash $Payload $NewSHA256
    Assert-PE32 $Payload
    if ($OldPresent -eq '1') { Assert-Hash $Live $OldSHA256 }
    elseif (Test-Path -LiteralPath $Live) { throw 'New plugin destination became occupied.' }
    if (Test-Path -LiteralPath $Backup) { throw 'A previous DLL backup already exists.' }
    if ($OldPresent -eq '1') {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        Assert-BackupPath
    }
    Copy-Item -LiteralPath $Payload -Destination $Temp
    try {
        Assert-Hash $Temp $NewSHA256
        if ($OldPresent -eq '1') {
            [IO.File]::Replace($Temp, $Live, $Backup, $true)
            Assert-Hash $Backup $OldSHA256
        } else {
            [IO.File]::Move($Temp, $Live)
        }
        Assert-Hash $Live $NewSHA256
    } finally {
        if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp }
    }
    exit 0
}

# Rollback accepts the original state if Install failed before replacement.
if ($OldPresent -eq '1') {
    if (Test-Path -LiteralPath $Live) {
        $Current = (Get-FileHash -LiteralPath $Live -Algorithm SHA256).Hash
        if ($Current -eq $OldSHA256) { exit 0 }
        if ($Current -ne $NewSHA256) { throw 'Unknown DLL contents; rollback refused.' }
    } else { throw 'Installed plugin is missing; rollback refused.' }
    Assert-Hash $Backup $OldSHA256
    Copy-Item -LiteralPath $Backup -Destination $Temp
    try {
        Assert-Hash $Temp $OldSHA256
        [IO.File]::Replace($Temp, $Live, $RollbackDiscard, $true)
        Assert-Hash $Live $OldSHA256
        Assert-Hash $RollbackDiscard $NewSHA256
        Remove-Item -LiteralPath $RollbackDiscard
    } finally {
        if (Test-Path -LiteralPath $Temp) { Remove-Item -LiteralPath $Temp }
    }
} elseif (Test-Path -LiteralPath $Live) {
    Assert-Hash $Live $NewSHA256
    Remove-Item -LiteralPath $Live
    if (Test-Path -LiteralPath $Live) { throw 'New DLL was not removed.' }
}
