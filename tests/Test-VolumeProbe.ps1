param([string]$AppRoot = (Split-Path $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = Get-Content -LiteralPath (Join-Path $AppRoot 'VolumeProbe.cs') -Raw
if ($PSEdition -eq 'Core') {
    Add-Type -TypeDefinition $source -ReferencedAssemblies @(
        'System.Runtime.dll', 'System.Runtime.InteropServices.dll',
        'System.ComponentModel.Primitives.dll', 'Microsoft.Win32.Primitives.dll')
}
else {
    Add-Type -TypeDefinition $source
}
$checks = 0
$id = [guid]::NewGuid().ToString('D')
foreach ($invalid in @($null, '', ' ', 'C:\', '\\.\PhysicalDrive0',
    "\\?\Volume{$id}", "\\?\Volume{$id}\extra",
    "\\?\Volume{$($id.Replace('-', ''))}\",
    '\\?\Volume{0123456789abcdef0123456789abcdef----}\',
    "\\?\Volume{$id}\ ")) {
    try {
        [DevDriveInstaller.Native.VolumeProbe]::IsDevDrive($invalid) | Out-Null
        throw 'An invalid volume path was accepted.'
    }
    catch {
        if ($_.Exception.InnerException -isnot [ArgumentException]) { throw }
    }
    $checks++
}
foreach ($valid in @("\\?\Volume{$id}\", "\\?\Volume{$($id.ToUpperInvariant())}\")) {
    try {
        [DevDriveInstaller.Native.VolumeProbe]::IsDevDrive($valid) | Out-Null
        throw 'The random nonexistent test volume unexpectedly exists.'
    }
    catch {
        if ($_.Exception.InnerException -isnot [ComponentModel.Win32Exception] -or
            $_.Exception.InnerException.Message -notlike 'Cannot inspect ReFS volume*') { throw }
    }
    $checks++
}
Write-Host "Passed $checks volume-probe checks under $PSEdition; no storage writes."
