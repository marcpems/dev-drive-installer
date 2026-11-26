param([string]$RequestBase64, [string]$ProbeBase64)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$global:ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$script:ProbeBase64 = $ProbeBase64

function Get-IdentityHash([string]$Value) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Get-ReceiptRoot {
    Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)) 'DevDriveInstaller'
}

function Get-AttemptPath([string]$PoolId) {
    Join-Path (Get-ReceiptRoot) ((Get-IdentityHash $PoolId) + '.json')
}

function Initialize-NativeProbe {
    if (-not ('DevDriveInstaller.Native.VolumeProbe' -as [type])) {
        Add-Type -TypeDefinition ([Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($script:ProbeBase64)))
    }
}

function Get-DevDriveFlag([string]$VolumeId) {
    Initialize-NativeProbe
    [DevDriveInstaller.Native.VolumeProbe]::IsDevDrive($VolumeId)
}

function Get-ReceiptSecurity([switch]$Directory) {
    $security = if ($Directory) { [Security.AccessControl.DirectorySecurity]::new() } else {
        [Security.AccessControl.FileSecurity]::new()
    }
    $security.SetAccessRuleProtection($true, $false)
    $security.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $inheritance = if ($Directory) { 'ContainerInherit, ObjectInherit' } else { 'None' }
    foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl',
            $inheritance, 'None', 'Allow'))
    }
    $security
}

function Assert-ReceiptSecurity([string]$Path, [switch]$Directory) {
    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        (($attributes -band [IO.FileAttributes]::Directory) -ne 0) -ne [bool]$Directory) {
        throw "Receipt storage must not contain links or unexpected file types: $Path"
    }
    $security = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $trusted = @('S-1-5-32-544', 'S-1-5-18')
    $owner = $security.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $trusted -or ($Directory -and -not $security.AreAccessRulesProtected)) {
        throw "Receipt storage has an unsafe owner or inherited directory permissions. Preserve it for administrator review: $Path"
    }
    $write = [Security.AccessControl.FileSystemRights]::Write -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership -bor 0x10000000 -bor 0x40000000
    foreach ($rule in $security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin $trusted -and
            ($rule.FileSystemRights -band $write) -ne 0) {
            throw "Receipt storage allows untrusted writes. Preserve it for administrator review: $Path"
        }
    }
}

function Open-ReceiptDirectory([string]$Path, [switch]$Create) {
    $root = Get-ReceiptRoot
    if ([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path)) -ine $root -or
        [IO.Path]::GetFileName($Path) -cnotmatch '^[0-9A-F]{64}\.json$') {
        throw 'An exact per-pool receipt path is required.'
    }
    Initialize-NativeProbe
    $handles = [Collections.Generic.List[IDisposable]]::new()
    try {
        $parent = Split-Path $root
        $handles.Add([DevDriveInstaller.Native.VolumeProbe]::LockDirectory($parent))
        if (([IO.File]::GetAttributes($parent) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The common application-data directory must not be a link.'
        }
        if ($Create) { [IO.Directory]::CreateDirectory($root, (Get-ReceiptSecurity -Directory)) | Out-Null }
        if (-not (Test-Path -LiteralPath $root)) { return $null }
        $handles.Add([DevDriveInstaller.Native.VolumeProbe]::LockDirectory($root, $true))
        Assert-ReceiptSecurity $root -Directory
        $result = $handles
        $handles = $null
        return ,$result
    }
    finally { if ($null -ne $handles) { foreach ($handle in $handles) { $handle.Dispose() } } }
}

function Read-CreationRecord([string]$Path, [switch]$Optional) {
    $handles = Open-ReceiptDirectory $Path
    try {
        if ($null -eq $handles -or -not (Test-Path -LiteralPath $Path)) {
            if ($Optional) { return $null }
            throw "The original creation receipt is missing: $Path"
        }
        Assert-ReceiptSecurity $Path
        Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
    }
    finally { if ($null -ne $handles) { foreach ($handle in $handles) { $handle.Dispose() } } }
}

function Get-SizeGuidance([long]$PoolBytes, [long]$AllocatedBytes) {
    if ($PoolBytes -le 0 -or $AllocatedBytes -lt 0 -or $AllocatedBytes -gt $PoolBytes) {
        throw 'Pool capacity information is invalid.'
    }
    $free = $PoolBytes - $AllocatedBytes
    $headroom = [long][Math]::Max(100, [Math]::Ceiling(($PoolBytes / 1GB) * 0.20))
    $maximum = [long][Math]::Max(0, [Math]::Floor($free / 1GB) - $headroom)
    $recommended = if ($maximum -lt 51) { 0 } else {
        [long][Math]::Max(51, [Math]::Floor([Math]::Min(300, $maximum / 2) / 25) * 25)
    }
    [pscustomobject]@{
        PhysicalFreeBytes = $free; MinimumGiB = 51; MaximumGiB = $maximum
        HeadroomGiB = $headroom; RecommendedGiB = $recommended
    }
}

function Get-BootPartitionSignature([int]$DiskNumber) {
    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop |
        Sort-Object Offset | Select-Object Guid, Offset, Size, GptType)
    if ($parts.Count -eq 0) { throw 'Windows disk has no verifiable partitions.' }
    ConvertTo-Json -InputObject $parts -Compress
}

function Get-StorageSnapshot {
    $blocked = [Collections.Generic.List[string]]::new()
    $devDrives = [Collections.Generic.List[string]]::new()
    $volumes = @(foreach ($volume in @(Get-Volume -ErrorAction Stop)) {
        $type = [string]$volume.FileSystemType
        $isDev = $false
        $devKnown = ($type -ne 'ReFS')
        $location = if ([string]$volume.DriveLetter -match '^[A-Za-z]$') {
            "$($volume.DriveLetter):"
        } else { [string]$volume.UniqueId }
        if ($type -eq 'ReFS') {
            try {
                $isDev = Get-DevDriveFlag ([string]$volume.UniqueId)
                $devKnown = $true
                if ($isDev) { $devDrives.Add($location) }
            }
            catch { $blocked.Add("Cannot verify Dev Drive status for ${location}: $($_.Exception.Message)") }
        }
        elseif ($type -in @('', 'Unknown', 'RAW') -and
            [string]$volume.DriveType -notin @('CD-ROM', 'CDROM')) {
            $blocked.Add("An unrecognized volume exists at $location; an existing Dev Drive cannot be ruled out.")
        }
        [pscustomobject]@{
            Name = [string]$volume.FileSystemLabel; FileSystem = $type; Location = $location
            Health = [string]$volume.HealthStatus
            DevStatusKnown = $devKnown
            SizeBytes = [long]$volume.Size; FreeBytes = [long]$volume.SizeRemaining; IsDevDrive = $isDev
        }
    })
    if ($devDrives.Count -gt 0) {
        $blocked.Add("An existing Dev Drive was detected: $($devDrives -join ', '). A second setup is not allowed.")
    }
    $offlineDisks = @(Get-Disk -ErrorAction Stop | Where-Object IsOffline)
    if (-not (Get-Command Format-Volume -ErrorAction Stop).Parameters.ContainsKey('DevDrive')) {
        $blocked.Add('This Windows Storage module does not support Dev Drive formatting.')
    }
    $systemLetter = $env:SystemDrive.Substring(0, 1)
    $osVolume = @(Get-Volume -DriveLetter $systemLetter -ErrorAction Stop)
    $osDisk = @(Get-Partition -DriveLetter $systemLetter -ErrorAction Stop | Get-Disk -ErrorAction Stop)
    if ($osVolume.Count -ne 1 -or $osDisk.Count -ne 1) { throw 'Cannot identify the running Windows volume and disk.' }
    if ($osVolume[0].FileSystemType -ne 'ReFS') {
        $blocked.Add('Creation requires Windows on a supported ReFS Storage Spaces boot pool.')
    }
    $boot = @()
    if ($osDisk[0].BusType -eq 'Spaces') {
        $boot = @(Get-VirtualDisk -Disk $osDisk[0] -ErrorAction Stop)
    }
    $pool = $null
    $member = $null
    $spaces = @()
    $poolId = ''
    $memberId = ''
    $bootId = ''
    $partitionSignature = ''
    $poolBytes = 0L
    $allocated = 0L
    $attemptStatus = ''
    $attemptError = ''
    if ($boot.Count -ne 1) {
        $blocked.Add('The Windows disk does not map to exactly one Storage Spaces virtual disk.')
    }
    else {
        $bootId = [string]$boot[0].UniqueId
        if ($boot[0].FriendlyName -ne 'Boot' -or $boot[0].ProvisioningType -ne 'Thin' -or
            $boot[0].ResiliencySettingName -ne 'Simple' -or $boot[0].HealthStatus -ne 'Healthy') {
            $blocked.Add('Windows must be on a healthy, thin-provisioned Simple Boot space.')
        }
        $pools = @(Get-StoragePool -VirtualDisk $boot[0] -ErrorAction Stop |
            Where-Object { -not $_.IsPrimordial })
        if ($pools.Count -ne 1) { $blocked.Add('The Windows space does not belong to one identifiable pool.') }
        else {
            $pool = $pools[0]
            $poolId = [string]$pool.UniqueId
            $poolBytes = [long]$pool.Size
            $allocated = [long]$pool.AllocatedSize
            if ($pool.FriendlyName -ne 'Boot' -or $pool.HealthStatus -ne 'Healthy' -or $pool.IsReadOnly) {
                $blocked.Add('The Windows pool must be the healthy, writable Boot pool.')
            }
            $members = @(Get-PhysicalDisk -StoragePool $pool -ErrorAction Stop)
            if ($members.Count -ne 1 -or $members[0].BusType -ne 'NVMe' -or $members[0].HealthStatus -ne 'Healthy') {
                $blocked.Add('Only a single healthy NVMe member in the Windows boot pool is supported.')
            }
            else {
                $member = $members[0]
                $memberId = [string]$member.UniqueId
            }
            $vds = @(Get-VirtualDisk -StoragePool $pool -ErrorAction Stop)
            if ($vds.Count -ne 1 -or $vds[0].UniqueId -ne $bootId) {
                $blocked.Add('The boot pool already contains another space or an incomplete Dev setup. Creation is disabled.')
            }
            if (@($vds | Where-Object HealthStatus -NE 'Healthy').Count -gt 0) {
                $blocked.Add('A virtual disk in the boot pool is unhealthy.')
            }
            $spaces = @(foreach ($vd in $vds) {
                [pscustomobject]@{
                    Name = [string]$vd.FriendlyName; Provisioning = [string]$vd.ProvisioningType
                    Health = [string]$vd.HealthStatus; LogicalBytes = [long]$vd.Size
                    FootprintBytes = [long]$vd.FootprintOnPool
                }
            })
            $path = Get-AttemptPath $poolId
            try {
                $saved = Read-CreationRecord $path -Optional
                if ($null -ne $saved) {
                    $attemptStatus = [string]$saved.Status
                    $attemptError = [string]$saved.Error
                }
            }
            catch {
                $attemptStatus = 'Unreadable creation record'
                $attemptError = $_.Exception.Message
            }
            if ($attemptStatus -and $attemptStatus -ne 'Removed') {
                $blocked.Add("A previous creation record exists ($attemptStatus). No automatic retry is allowed. Record: $path")
                if ($attemptError) { $blocked.Add("Receipt error: $attemptError") }
            }
        }
        $partitionSignature = Get-BootPartitionSignature $osDisk[0].Number
    }
    if ([string]::IsNullOrWhiteSpace($poolId) -or [string]::IsNullOrWhiteSpace($memberId) -or
        [string]::IsNullOrWhiteSpace($bootId) -or [string]::IsNullOrWhiteSpace($osDisk[0].UniqueId)) {
        $blocked.Add('Stable boot-pool, member and disk identities could not all be established.')
    }
    if (@($offlineDisks | Where-Object {
        [string]::IsNullOrWhiteSpace($memberId) -or $_.UniqueId -ne $memberId
    }).Count -gt 0) {
        $blocked.Add('An unrelated offline disk exists. Its Dev Drive status cannot be checked; disconnect it or bring it online for inspection.')
    }
    $limits = if ($poolBytes -gt 0) { Get-SizeGuidance $poolBytes $allocated } else {
        [pscustomobject]@{ PhysicalFreeBytes = 0L; MinimumGiB = 51L; MaximumGiB = 0L; HeadroomGiB = 100L; RecommendedGiB = 0L }
    }
    if ($limits.MaximumGiB -lt $limits.MinimumGiB) {
        $blocked.Add('Insufficient physical pool capacity for a 51 GiB space plus the safety headroom.')
    }
    $fingerprint = Get-IdentityHash (
        @($poolId, $memberId, $bootId, [string]$osDisk[0].UniqueId, $partitionSignature) -join '|')
    $snapshot = [pscustomobject]@{
        Fingerprint = $fingerprint; PoolId = $poolId; MemberId = $memberId; BootId = $bootId
        BootDiskId = [string]$osDisk[0].UniqueId; BootDiskNumber = $osDisk[0].Number
        PartitionSignature = $partitionSignature
        WindowsIsReFS = ($osVolume[0].FileSystemType -eq 'ReFS')
        PoolName = $(if ($pool) { [string]$pool.FriendlyName } else { '' })
        MemberName = $(if ($member) { [string]$member.FriendlyName } else { '' })
        MemberSerial = $(if ($member) { ([string]$member.SerialNumber).Trim() } else { '' })
        PoolBytes = $poolBytes; AllocatedBytes = $allocated
        PhysicalFreeBytes = $limits.PhysicalFreeBytes
        MinimumGiB = $limits.MinimumGiB; MaximumGiB = $limits.MaximumGiB
        HeadroomGiB = $limits.HeadroomGiB; RecommendedGiB = $limits.RecommendedGiB
        Guidance = "Minimum space size: 51 GiB (leaves room for GPT overhead above the Dev Drive minimum). " +
            "Current maximum: $($limits.MaximumGiB) GiB. " +
            "Suggested starting size: $($limits.RecommendedGiB) GiB. The maximum retains at least " +
            "$($limits.HeadroomGiB) GiB of current physical headroom (100 GiB or 20% of the pool, whichever is larger). " +
            'This is a conservative planning limit, not reserved capacity. More Windows growth reduces what remains. ' +
            'The suggestion uses about half that allowance, capped at 300 GiB; choose for your repositories and build outputs.'
        CanCreate = ($blocked.Count -eq 0); BlockReasons = @($blocked.ToArray())
        Spaces = @($spaces); Volumes = @($volumes); DevDrives = @($devDrives.ToArray())
        AttemptStatus = $attemptStatus; AttemptError = $attemptError
        CanRemove = $false; RemovalFingerprint = ''; RemovableDrive = ''; RemovableSizeBytes = 0L
        RemoveReason = 'Only a verified Dev space created by this tool can be removed.'
    }
    if ($attemptStatus -and $attemptStatus -ne 'Removed') {
        try {
            $target = Get-RemovalTarget $snapshot
            $snapshot.CanRemove = $true
            $snapshot.RemovalFingerprint = $target.Fingerprint
            $snapshot.RemovableDrive = $target.Location
            $snapshot.RemovableSizeBytes = [long]$target.Volume.Size
            $snapshot.RemoveReason = ''
        }
        catch { $snapshot.RemoveReason = $_.Exception.Message }
    }
    $snapshot
}

function Get-RemovalTarget($Snapshot) {
    if (-not $Snapshot.WindowsIsReFS -or [string]::IsNullOrWhiteSpace($Snapshot.PoolId) -or
        [string]::IsNullOrWhiteSpace($Snapshot.MemberId) -or [string]::IsNullOrWhiteSpace($Snapshot.BootId)) {
        throw 'Removal requires a verified Windows boot pool.'
    }
    $path = Get-AttemptPath $Snapshot.PoolId
    $record = Read-CreationRecord $path
    if ($record.Status -notin @('Completed', 'Failed-NoAutomaticRetry', 'Started-NoAutomaticRetry')) {
        throw 'This creation record requires manual review before removal.'
    }
    if ($record.PoolId -cne $Snapshot.PoolId -or $record.MemberId -cne $Snapshot.MemberId -or
        $record.BootId -cne $Snapshot.BootId -or $record.Fingerprint -cne $Snapshot.Fingerprint -or
        [string]::IsNullOrWhiteSpace($record.CreatedVirtualDiskId) -or
        $record.CreatedVirtualDiskId -ceq $Snapshot.BootId) {
        throw 'The creation record does not match the current Windows disk and Dev space.'
    }
    $pools = @(Get-StoragePool -UniqueId $Snapshot.PoolId -ErrorAction Stop)
    if ($pools.Count -ne 1 -or $pools[0].IsPrimordial -or $pools[0].IsReadOnly -or
        $pools[0].HealthStatus -ne 'Healthy') { throw 'The recorded pool is not healthy and writable.' }
    $pool = $pools[0]
    $members = @(Get-PhysicalDisk -StoragePool $pool -ErrorAction Stop)
    if ($members.Count -ne 1 -or $members[0].UniqueId -cne $Snapshot.MemberId -or
        $members[0].HealthStatus -ne 'Healthy' -or $members[0].BusType -ne 'NVMe') {
        throw 'The pool member changed or is unhealthy.'
    }
    $spaces = @(Get-VirtualDisk -StoragePool $pool -ErrorAction Stop)
    $boot = @($spaces | Where-Object UniqueId -EQ $Snapshot.BootId)
    $dev = @($spaces | Where-Object UniqueId -EQ $record.CreatedVirtualDiskId)
    if ($spaces.Count -ne 2 -or $boot.Count -ne 1 -or $dev.Count -ne 1 -or
        $boot[0].HealthStatus -ne 'Healthy' -or $boot[0].ProvisioningType -ne 'Thin' -or
        $boot[0].ResiliencySettingName -ne 'Simple' -or $dev[0].HealthStatus -ne 'Healthy' -or
        $dev[0].ProvisioningType -ne 'Thin' -or $dev[0].ResiliencySettingName -ne 'Simple') {
        throw 'The pool must contain only Windows and the recorded healthy Dev space.'
    }
    $associated = @(Get-StoragePool -VirtualDisk $dev[0] -ErrorAction Stop)
    $disks = @(Get-Disk -VirtualDisk $dev[0] -ErrorAction Stop)
    if ($associated.Count -ne 1 -or $associated[0].UniqueId -cne $Snapshot.PoolId -or
        $disks.Count -ne 1 -or $disks[0].BusType -ne 'Spaces' -or
        $disks[0].PartitionStyle -ne 'GPT' -or $disks[0].IsBoot -or $disks[0].IsSystem -or
        $disks[0].IsOffline -or $disks[0].IsReadOnly -or
        $disks[0].Number -eq $Snapshot.BootDiskNumber -or
        [string]::IsNullOrWhiteSpace($disks[0].UniqueId) -or
        $disks[0].UniqueId -ceq $Snapshot.BootDiskId -or $disks[0].UniqueId -ceq $Snapshot.MemberId) {
        throw 'The recorded Dev disk cannot be safely separated from Windows or physical storage.'
    }
    $parts = @(Get-Partition -DiskNumber $disks[0].Number -ErrorAction Stop)
    $dataType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
    $reservedType = '{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}'
    $data = @($parts | Where-Object GptType -EQ $dataType)
    if ($data.Count -ne 1 -or [string]::IsNullOrWhiteSpace($data[0].Guid) -or
        @($parts | Where-Object { $_.GptType -notin @($dataType, $reservedType) }).Count -ne 0) {
        throw 'Removal requires one data partition and no EFI or recovery partitions on the Dev disk.'
    }
    $volumes = @($data[0] | Get-Volume -ErrorAction Stop)
    if ($volumes.Count -ne 1 -or $volumes[0].FileSystemType -ne 'ReFS' -or
        $volumes[0].HealthStatus -ne 'Healthy' -or
        -not (Get-DevDriveFlag ([string]$volumes[0].UniqueId)) -or
        ($record.VolumeId -and $record.VolumeId -cne $volumes[0].UniqueId)) {
        throw 'The recorded data partition is not a verified healthy Dev Drive.'
    }
    Assert-DevDriveEmpty ([string]$volumes[0].UniqueId)
    $location = if ([string]$volumes[0].DriveLetter -match '^[A-Za-z]$') {
        "$($volumes[0].DriveLetter):"
    } else { 'Dev Drive (no drive letter)' }
    [pscustomobject]@{
        Record = $record; Path = $path; Dev = $dev[0]; Volume = $volumes[0]; Location = $location
        Fingerprint = Get-IdentityHash (@($Snapshot.Fingerprint, $dev[0].UniqueId,
            $disks[0].UniqueId, $data[0].Guid, $volumes[0].UniqueId, $volumes[0].Size) -join '|')
    }
}

function Assert-DevDriveEmpty([string]$RootPath) {
    foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($RootPath)) {
        $attributes = [IO.File]::GetAttributes($entry)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The Dev Drive contains a link. Remove it before deleting the space.'
        }
        $name = [IO.Path]::GetFileName($entry)
        if ($name -eq 'System Volume Information' -and
            ($attributes -band [IO.FileAttributes]::Directory) -ne 0) { continue }
        if ($name -eq '$Recycle.Bin' -and
            ($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            $directories = [Collections.Generic.Stack[string]]::new()
            $directories.Push($entry)
            while ($directories.Count) {
                foreach ($item in [IO.Directory]::EnumerateFileSystemEntries($directories.Pop())) {
                    $flags = [IO.File]::GetAttributes($item)
                    if (($flags -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                        throw 'The Recycle Bin contains a link. Review it before removing the drive.'
                    }
                    if (($flags -band [IO.FileAttributes]::Directory) -ne 0) { $directories.Push($item) }
                    elseif ([IO.Path]::GetFileName($item) -ne 'desktop.ini') {
                        throw 'Empty the Dev Drive Recycle Bin before removing the space.'
                    }
                }
            }
            continue
        }
        throw 'The Dev Drive is not empty. Move its files and folders before removing the space.'
    }
}

function Invoke-RemoveDevDrive($Request) {
    $before = Get-StorageSnapshot
    $target = Get-RemovalTarget $before
    if ($target.Fingerprint -cne $Request.Fingerprint) { throw 'The Dev Drive changed. Refresh before removal.' }
    $mutex = [Threading.Mutex]::new($false, ('Global\DevDriveInstaller-' + (Get-IdentityHash $before.PoolId)))
    $owned = $false
    $record = $null
    try {
        $owned = $mutex.WaitOne(0)
        if (-not $owned) { throw 'Another storage operation is running. Nothing was removed.' }
        $before = Get-StorageSnapshot
        $target = Get-RemovalTarget $before
        if ($target.Fingerprint -cne $Request.Fingerprint) { throw 'The Dev Drive changed. Refresh before removal.' }
        $record = $target.Record
        $record.Status = 'RemovalStarted-NoAutomaticRetry'
        $record.VolumeId = [string]$target.Volume.UniqueId
        $record | Add-Member -NotePropertyName RemovalStartedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Write-CreationRecord -Path $target.Path -Record $record
        $script:CreationRecordPath = $target.Path
        Assert-DevDriveEmpty ([string]$target.Volume.UniqueId)
        Remove-VirtualDisk -InputObject $target.Dev -Confirm:$false -ErrorAction Stop
        $after = Get-StorageSnapshot
        $finalPools = @(Get-StoragePool -UniqueId $before.PoolId -ErrorAction Stop)
        if ($finalPools.Count -ne 1 -or $finalPools[0].HealthStatus -ne 'Healthy' -or
            $finalPools[0].IsReadOnly -or $finalPools[0].UniqueId -cne $before.PoolId) {
            throw 'Pool health could not be verified after removal. Preserve the record.'
        }
        $finalMembers = @(Get-PhysicalDisk -StoragePool $finalPools[0] -ErrorAction Stop)
        $remaining = @(Get-VirtualDisk -StoragePool $finalPools[0] -ErrorAction Stop)
        if (-not $after.WindowsIsReFS -or $after.Fingerprint -cne $before.Fingerprint -or
            $finalMembers.Count -ne 1 -or $finalMembers[0].UniqueId -cne $before.MemberId -or
            $finalMembers[0].HealthStatus -ne 'Healthy' -or $remaining.Count -ne 1 -or
            $remaining[0].UniqueId -cne $before.BootId -or $remaining[0].HealthStatus -ne 'Healthy' -or
            @(Get-Volume -ErrorAction Stop | Where-Object UniqueId -EQ $record.VolumeId).Count -ne 0) {
            throw 'Removal could not be fully verified. Preserve the record and review storage.'
        }
        $record.Status = 'Removed'
        $record | Add-Member -NotePropertyName RemovedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        Write-CreationRecord -Path $target.Path -Record $record
        $after.AttemptStatus = 'Removed'
        $after.CanRemove = $false
        $after.CanCreate = $false
        $after.RemoveReason = 'No recorded Dev Drive remains.'
        $after.BlockReasons = @('Removal verified. Refresh before creating again.')
        [pscustomobject]@{ Success = $true; Snapshot = $after; CreatedDrive = ''; LogPath = $target.Path; Error = '' }
    }
    catch {
        $message = $_.Exception.Message
        if ($record -and $script:CreationRecordPath -eq $target.Path) {
            $record.Status = 'RemovalFailed-NoAutomaticRetry'
            $record.Error = $message
            try { Write-CreationRecord -Path $target.Path -Record $record }
            catch { throw "$message`nThe removal record could not be updated. Preserve $($target.Path)." }
        }
        throw $message
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Assert-CreationRequest($Snapshot, $Request) {
    if (-not $Snapshot.CanCreate) { throw ($Snapshot.BlockReasons -join "`n") }
    if ([string]::IsNullOrWhiteSpace([string]$Request.Fingerprint) -or
        $Snapshot.Fingerprint -cne $Request.Fingerprint) {
        throw 'The target or Windows partition layout changed since review. Refresh and review it again.'
    }
    $size = [decimal]$Request.SizeGiB
    if ($size -ne [Math]::Floor($size) -or $size -lt $Snapshot.MinimumGiB -or $size -gt $Snapshot.MaximumGiB) {
        throw 'Requested size is outside the freshly verified whole-GiB safety limits. Refresh and review the current capacity.'
    }
    [long]$size
}

function Write-CreationRecord([string]$Path, $Record, [switch]$New) {
    $handles = Open-ReceiptDirectory $Path -Create
    try {
        if (-not $New) { Assert-ReceiptSecurity $Path }
        $stream = if ($New) {
            [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew,
                [Security.AccessControl.FileSystemRights]::Write, [IO.FileShare]::Read,
                4096, [IO.FileOptions]::WriteThrough, (Get-ReceiptSecurity))
        } else { [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read) }
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 6))
            $stream.SetLength(0)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
}

function Assert-VolumeAccessible([string]$RootPath) {
    $entries = [IO.Directory]::EnumerateFileSystemEntries($RootPath).GetEnumerator()
    try { $null = $entries.MoveNext() }
    finally { $entries.Dispose() }
}

function Invoke-CreateDevDrive($Request) {
    $before = Get-StorageSnapshot
    $sizeGiB = Assert-CreationRequest $before $Request
    $mutex = [Threading.Mutex]::new($false, ('Global\DevDriveInstaller-' + (Get-IdentityHash $before.PoolId)))
    $owned = $false
    $record = $null
    $path = Get-AttemptPath $before.PoolId
    try {
        $owned = $mutex.WaitOne(0)
        if (-not $owned) { throw 'Another Dev Drive creation process is running. No changes were made by this process.' }
        $before = Get-StorageSnapshot
        $sizeGiB = Assert-CreationRequest $before $Request
        $handles = Open-ReceiptDirectory $path -Create
        try {
            if (Test-Path -LiteralPath $path) {
                Assert-ReceiptSecurity $path
                $previous = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                if ($previous.Status -ne 'Removed') { throw 'The previous operation still requires manual review.' }
                $history = Join-Path (Split-Path $path) 'History'
                [IO.Directory]::CreateDirectory($history, (Get-ReceiptSecurity -Directory)) | Out-Null
                $historyHandle = [DevDriveInstaller.Native.VolumeProbe]::LockDirectory($history, $true)
                try {
                    Assert-ReceiptSecurity $history -Directory
                    [IO.File]::Move($path, (Join-Path $history ([guid]::NewGuid().ToString('N') + '.json')))
                } finally { $historyHandle.Dispose() }
            }
        } finally { foreach ($handle in $handles) { $handle.Dispose() } }
        $record = [ordered]@{
            Status = 'Started-NoAutomaticRetry'; PoolId = $before.PoolId; MemberId = $before.MemberId
            BootId = $before.BootId; Fingerprint = $before.Fingerprint; SizeGiB = $sizeGiB
            StartedAt = [DateTime]::UtcNow.ToString('o'); CreatedVirtualDiskId = ''; VolumeId = ''; Error = ''
        }
        Write-CreationRecord -Path $path -Record $record -New
        $script:CreationRecordPath = $path
        $dev = New-VirtualDisk -StoragePoolUniqueId $before.PoolId -FriendlyName Dev `
            -Size ($sizeGiB * 1GB) -ProvisioningType Thin -ResiliencySettingName Simple `
            -NumberOfColumns 1 -WriteCacheSize 0 -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$dev.UniqueId) -or $dev.UniqueId -eq $before.BootId) {
            throw 'The new virtual disk did not return a distinct stable identity.'
        }
        $record.CreatedVirtualDiskId = [string]$dev.UniqueId
        Write-CreationRecord -Path $path -Record $record
        $newPool = @(Get-StoragePool -VirtualDisk $dev -ErrorAction Stop | Where-Object { -not $_.IsPrimordial })
        $disk = @(Get-Disk -VirtualDisk $dev -ErrorAction Stop)
        if ($newPool.Count -ne 1 -or $newPool[0].UniqueId -ne $before.PoolId -or
            $disk.Count -ne 1 -or $disk[0].PartitionStyle -ne 'RAW' -or $disk[0].BusType -ne 'Spaces' -or
            $disk[0].IsBoot -or $disk[0].IsSystem -or $disk[0].IsOffline -or $disk[0].IsReadOnly -or
            $disk[0].Number -eq $before.BootDiskNumber -or
            [string]::IsNullOrWhiteSpace([string]$disk[0].UniqueId) -or $disk[0].UniqueId -eq $before.BootDiskId) {
            throw 'Only the newly created RAW data disk in the reviewed pool can be initialized. No disk was initialized.'
        }
        Initialize-Disk -VirtualDisk $dev -PartitionStyle GPT -ErrorAction Stop | Out-Null
        $partition = New-Partition -DiskNumber $disk[0].Number -UseMaximumSize -ErrorAction Stop
        $formatted = Format-Volume -Partition $partition -FileSystem ReFS -DevDrive `
            -NewFileSystemLabel DevDrive -Confirm:$false -ErrorAction Stop
        $volume = @($partition | Get-Volume -ErrorAction Stop)
        if ($volume.Count -ne 1 -or $volume[0].FileSystemType -ne 'ReFS' -or
            $volume[0].Size -lt ($sizeGiB * 1GB - 64MB) -or
            -not (Get-DevDriveFlag ([string]$volume[0].UniqueId))) {
            throw 'The newly formatted volume could not be verified as the requested ReFS Dev Drive.'
        }
        $record.VolumeId = [string]$volume[0].UniqueId
        Write-CreationRecord -Path $path -Record $record
        Add-PartitionAccessPath -InputObject $partition -AssignDriveLetter -ErrorAction Stop | Out-Null
        $volume = @($partition | Get-Volume -ErrorAction Stop)
        if ($volume.Count -ne 1 -or $volume[0].UniqueId -cne $record.VolumeId -or
            $volume[0].FileSystemType -ne 'ReFS' -or
            -not (Get-DevDriveFlag ([string]$volume[0].UniqueId)) -or
            [string]$volume[0].DriveLetter -notmatch '^[A-Za-z]$') {
            throw 'The verified Dev Drive did not receive a valid drive letter with the same volume identity.'
        }
        $letterVolume = @(Get-Volume -DriveLetter $volume[0].DriveLetter -ErrorAction Stop)
        if ($letterVolume.Count -ne 1 -or $letterVolume[0].UniqueId -cne $record.VolumeId) {
            throw 'The assigned drive letter does not resolve to the verified Dev Drive.'
        }
        Assert-VolumeAccessible "$($volume[0].DriveLetter):\"
        $after = Get-StorageSnapshot
        if ($after.PoolId -cne $before.PoolId -or $after.MemberId -cne $before.MemberId -or
            $after.BootId -cne $before.BootId -or $after.BootDiskId -cne $before.BootDiskId -or
            $after.PartitionSignature -cne $before.PartitionSignature) {
            throw 'The original Windows disk, pool member or Windows partition layout changed. Manual review is required.'
        }
        $finalPool = @(Get-StoragePool -VirtualDisk $dev -ErrorAction Stop | Where-Object { -not $_.IsPrimordial })
        if ($finalPool.Count -ne 1 -or $finalPool[0].HealthStatus -ne 'Healthy') {
            throw 'Final pool identity or health verification failed. Manual review is required.'
        }
        $finalDev = @(Get-VirtualDisk -StoragePool $finalPool[0] -ErrorAction Stop |
            Where-Object UniqueId -EQ $dev.UniqueId)
        if ($finalDev.Count -ne 1 -or $finalDev[0].HealthStatus -ne 'Healthy' -or
            $after.DevDrives.Count -ne 1) {
            throw 'Final pool, space health or unique Dev Drive verification failed. Manual review is required.'
        }
        $record.Status = 'Completed'
        $record.VolumeId = [string]$volume[0].UniqueId
        $record['CompletedAt'] = [DateTime]::UtcNow.ToString('o')
        Write-CreationRecord -Path $path -Record $record
        [pscustomobject]@{
            Success = $true; Snapshot = Get-StorageSnapshot; CreatedDrive = "$($volume[0].DriveLetter):"
            LogPath = $path; Error = ''
        }
    }
    catch {
        $errorText = $_.Exception.Message
        if ($null -ne $record -and $script:CreationRecordPath -eq $path) {
            $record.Status = 'Failed-NoAutomaticRetry'
            $record.Error = $errorText
            try { Write-CreationRecord -Path $path -Record $record }
            catch { throw "$errorText`nThe failure record could not be updated: $($_.Exception.Message). Preserve $path." }
        }
        throw "$errorText`nNo automatic cleanup or retry is allowed. Preserve creation record: $path"
    }
    finally {
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

$script:CreationRecordPath = ''
try {
    $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($RequestBase64)) | ConvertFrom-Json
    if ($request.Mode -eq 'Inspect') {
        $result = [pscustomobject]@{ Success = $true; Snapshot = Get-StorageSnapshot; Error = ''; LogPath = '' }
    }
    elseif ($request.Mode -eq 'Create') { $result = Invoke-CreateDevDrive $request }
    elseif ($request.Mode -eq 'Remove') { $result = Invoke-RemoveDevDrive $request }
    else { throw 'Unknown storage request.' }
}
catch {
    $result = [pscustomobject]@{
        Success = $false; Error = "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
        LogPath = $script:CreationRecordPath; Snapshot = $null
    }
}
ConvertTo-Json -InputObject $result -Depth 10 -Compress
