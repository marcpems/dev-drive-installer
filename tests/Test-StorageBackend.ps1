param([string]$AppRoot = (Split-Path $PSScriptRoot))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $AppRoot 'StorageBackend.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
foreach ($function in $ast.FindAll({
    param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
$realEmptyCheck = (Get-Item Function:\Assert-DevDriveEmpty).ScriptBlock
$realAccessCheck = (Get-Item Function:\Assert-VolumeAccessible).ScriptBlock
$script:ProbeBase64 = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes((Get-Content -LiteralPath (Join-Path $AppRoot 'VolumeProbe.cs') -Raw)))
function Get-ReceiptRoot { Join-Path $env:ProgramData 'DevDriveInstaller' }

$originalProgramData = $env:ProgramData
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('DevDriveInstaller-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:Checks = [Collections.Generic.List[string]]::new()
$script:Calls = [Collections.Generic.List[string]]::new()

function Assert-Test([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw "FAILED: $Name" }
    $script:Checks.Add($Name)
}

function Assert-Throws([string]$Name, [scriptblock]$Action, [string]$Pattern) {
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Test $Name ($message -match $Pattern)
}

function Reset-Fixture {
    $script:Calls.Clear()
    $script:CreationRecordPath = ''
    $env:ProgramData = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $env:ProgramData | Out-Null
    $script:Fixture = @{
        Pool = [pscustomobject]@{
            FriendlyName = 'Boot'; UniqueId = 'pool-fixture'; IsPrimordial = $false
            HealthStatus = 'Healthy'; IsReadOnly = $false; Size = 1000GB; AllocatedSize = 100GB
        }
        Boot = [pscustomobject]@{
            FriendlyName = 'Boot'; UniqueId = 'boot-fixture'; ProvisioningType = 'Thin'
            ResiliencySettingName = 'Simple'; HealthStatus = 'Healthy'; Size = 990GB; FootprintOnPool = 90GB
        }
        Members = @([pscustomobject]@{
            FriendlyName = 'NVMe fixture'; UniqueId = 'nvme-fixture'; BusType = 'NVMe'
            HealthStatus = 'Healthy'; SerialNumber = 'fixture-serial'
        })
        OsDisk = [pscustomobject]@{ Number = 0; UniqueId = 'os-disk'; BusType = 'Spaces'; IsOffline = $false }
        NewDisk = [pscustomobject]@{
            Number = 7; UniqueId = 'new-disk'; PartitionStyle = 'RAW'; BusType = 'Spaces'
            IsBoot = $false; IsSystem = $false; IsOffline = $false; IsReadOnly = $false
        }
        BootPartitions = @(
            [pscustomobject]@{ Guid = 'efi'; Offset = 1MB; Size = 300MB; GptType = 'efi' },
            [pscustomobject]@{ Guid = 'os'; Offset = 320MB; Size = 980GB; GptType = 'data' },
            [pscustomobject]@{ Guid = 'recovery'; Offset = 981GB; Size = 2GB; GptType = 'recovery' }
        )
        NewPartitions = @([pscustomobject]@{
            Guid = 'dev-partition'; GptType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}'
        })
        Volumes = @([pscustomobject]@{
            UniqueId = 'volume-os'; DriveLetter = $env:SystemDrive.Substring(0, 1)
            FileSystemType = 'ReFS'; FileSystemLabel = 'Windows'; DriveType = 'Fixed'
            HealthStatus = 'Healthy'
            Size = 980GB; SizeRemaining = 900GB; IsDev = $false
        })
        NewVolume = [pscustomobject]@{
            UniqueId = 'volume-new'; DriveLetter = 'D'; FileSystemType = 'ReFS'
            FileSystemLabel = 'DevDrive'; DriveType = 'Fixed'; Size = 300GB; SizeRemaining = 299GB; IsDev = $true
            HealthStatus = 'Healthy'
        }
        NewVd = [pscustomobject]@{
            FriendlyName = 'Dev'; UniqueId = 'new-vd'; ProvisioningType = 'Thin'
            ResiliencySettingName = 'Simple'; HealthStatus = 'Healthy'; Size = 300GB; FootprintOnPool = 1GB
        }
        AdditionalSpace = $false; Created = $false; ProbeError = $false; HasDevDriveParameter = $true
        OfflineDisk = $false; OfflineId = 'offline-unrelated'; FailStage = ''; WrongNewPool = $false; ChangePartitions = $false
        PoolReads = 0; ExhaustOnSecondRead = $false
        NotEmpty = $false; EmptyReads = 0; BecomesNonEmpty = $false; ExtraSpace = $false
        Formatted = $false; VerifiedBeforeLetter = $false
    }
}

function Get-Volume {
    [CmdletBinding()] param([string]$DriveLetter, [Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -ne $InputObject) { $script:Fixture.NewVolume }
        elseif ($DriveLetter) {
            if ($script:Fixture.FailStage -eq 'LetterMapping' -and $DriveLetter -eq 'D') {
                $script:Fixture.Volumes[0]
            }
            else { $script:Fixture.Volumes | Where-Object DriveLetter -EQ $DriveLetter }
        }
        else { $script:Fixture.Volumes }
    }
}
function Get-DevDriveFlag([string]$VolumeId) {
    if ($script:Fixture.ProbeError) { throw 'Fixture native query failure' }
    if ($VolumeId -eq $script:Fixture.NewVolume.UniqueId -and $script:Fixture.Formatted -and
        -not $script:Fixture.NewVolume.DriveLetter) {
        if ($script:Fixture.FailStage -eq 'PreMountProbe') { throw 'Fixture pre-mount native query failure' }
        $script:Fixture.VerifiedBeforeLetter = $script:Fixture.NewVolume.IsDev
    }
    $match = @($script:Fixture.Volumes | Where-Object UniqueId -EQ $VolumeId)
    if ($match.Count -eq 1) { return $match[0].IsDev }
    if ($VolumeId -eq $script:Fixture.NewVolume.UniqueId) { return $script:Fixture.NewVolume.IsDev }
    throw 'Unrecognized fixture volume'
}
function Get-Command {
    [CmdletBinding()] param([string]$Name)
    if ($Name -ne 'Format-Volume') { throw 'Unexpected command inspection' }
    $parameters = @{}
    if ($script:Fixture.HasDevDriveParameter) { $parameters.DevDrive = $true }
    [pscustomobject]@{ Parameters = $parameters }
}
function Get-Disk {
    [CmdletBinding()] param($VirtualDisk, [Parameter(ValueFromPipeline)]$InputObject)
    process {
        if ($null -ne $VirtualDisk) { $script:Fixture.NewDisk }
        elseif ($script:Fixture.OfflineDisk -and $null -eq $InputObject) {
            $script:Fixture.OsDisk
            [pscustomobject]@{ IsOffline = $true; UniqueId = $script:Fixture.OfflineId }
        }
        else { $script:Fixture.OsDisk }
    }
}
function Get-Partition {
    [CmdletBinding()] param([string]$DriveLetter, [int]$DiskNumber)
    if ($DriveLetter) { [pscustomobject]@{ Fixture = 'OS' } }
    elseif ($DiskNumber -eq 7) { $script:Fixture.NewPartitions }
    else { $script:Fixture.BootPartitions }
}
function Get-VirtualDisk {
    [CmdletBinding()] param($Disk, $StoragePool)
    if ($null -ne $Disk) { $script:Fixture.Boot }
    else {
        $script:Fixture.Boot
        if ($script:Fixture.AdditionalSpace -or $script:Fixture.Created) { $script:Fixture.NewVd }
        if ($script:Fixture.ExtraSpace) { [pscustomobject]@{ UniqueId = 'unrelated-space' } }
    }
}
function Get-StoragePool {
    [CmdletBinding()] param($VirtualDisk, [string]$UniqueId)
    $script:Fixture.PoolReads++
    if ($script:Fixture.ExhaustOnSecondRead -and $script:Fixture.PoolReads -ge 2) {
        $script:Fixture.Pool.AllocatedSize = 850GB
    }
    if ($script:Fixture.WrongNewPool -and $null -ne $VirtualDisk -and $VirtualDisk.UniqueId -eq 'new-vd') {
        [pscustomobject]@{ IsPrimordial = $false; UniqueId = 'wrong-pool' }
    }
    else { $script:Fixture.Pool }
}
function Get-PhysicalDisk {
    [CmdletBinding()] param($StoragePool)
    $script:Fixture.Members
}
function New-VirtualDisk {
    [CmdletBinding()] param($StoragePoolUniqueId, $FriendlyName, $Size, $ProvisioningType,
        $ResiliencySettingName, $NumberOfColumns, $WriteCacheSize)
    if ($StoragePoolUniqueId -ne 'pool-fixture' -or $FriendlyName -ne 'Dev' -or
        $ProvisioningType -ne 'Thin' -or $ResiliencySettingName -ne 'Simple' -or
        $NumberOfColumns -ne 1 -or $WriteCacheSize -ne 0) { throw 'Invalid provisioning arguments' }
    $script:Calls.Add('Create:Dev')
    if ($script:Fixture.FailStage -eq 'Create') { throw 'Fixture creation failure' }
    $script:Fixture.Created = $true
    $script:Fixture.NewVd.Size = $Size
    $script:Fixture.NewVolume.Size = $Size - 16MB
    $script:Fixture.NewVd
}
function Initialize-Disk {
    [CmdletBinding()] param($VirtualDisk, $PartitionStyle)
    if ($VirtualDisk.UniqueId -ne 'new-vd' -or $PartitionStyle -ne 'GPT') { throw 'Unsafe initialization target' }
    $script:Calls.Add('Initialize:new-vd')
    if ($script:Fixture.FailStage -eq 'Initialize') { throw 'Fixture initialization failure' }
    $script:Fixture.NewDisk.PartitionStyle = 'GPT'
}
function New-Partition {
    [CmdletBinding()] param($DiskNumber, [switch]$UseMaximumSize, [switch]$AssignDriveLetter)
    if ($DiskNumber -ne 7 -or -not $UseMaximumSize -or $AssignDriveLetter) { throw 'Unsafe partition target or premature drive letter' }
    $script:Calls.Add('Partition:7')
    $script:Fixture.NewVolume.DriveLetter = ''
    [pscustomobject]@{ Fixture = 'new-partition' }
}
function Format-Volume {
    [CmdletBinding(SupportsShouldProcess)] param($Partition, $FileSystem, [switch]$DevDrive, $NewFileSystemLabel)
    if ($Partition.Fixture -ne 'new-partition' -or $FileSystem -ne 'ReFS' -or -not $DevDrive) {
        throw 'Unsafe format target'
    }
    $script:Calls.Add('Format:new-partition')
    if ($script:Fixture.NewVolume.DriveLetter) { throw 'Volume was exposed before formatting.' }
    if ($script:Fixture.FailStage -eq 'Format') { throw 'Fixture format failure' }
    $script:Fixture.Formatted = $true
    if ($script:Fixture.FailStage -eq 'FinalHealth') { $script:Fixture.NewVd.HealthStatus = 'Unhealthy' }
    if ($script:Fixture.ChangePartitions) { $script:Fixture.BootPartitions[1].Size -= 1GB }
    $script:Fixture.Volumes += $script:Fixture.NewVolume
    $script:Fixture.NewVolume
}

function Add-PartitionAccessPath {
    [CmdletBinding()] param($InputObject, [switch]$AssignDriveLetter)
    if ($InputObject.Fixture -ne 'new-partition' -or -not $AssignDriveLetter -or
        -not $script:Fixture.Formatted -or -not $script:Fixture.VerifiedBeforeLetter) {
        throw 'Drive letter was assigned before verifying the formatted Dev volume.'
    }
    $record = Get-Content -LiteralPath (Get-AttemptPath 'pool-fixture') -Raw | ConvertFrom-Json
    if ($record.VolumeId -ne 'volume-new') { throw 'Verified volume identity was not saved before mounting.' }
    $script:Calls.Add('Mount:new-partition')
    if ($script:Fixture.FailStage -eq 'Mount') { throw 'Fixture drive-letter assignment failure' }
    if ($script:Fixture.FailStage -ne 'NoLetter') { $script:Fixture.NewVolume.DriveLetter = 'D' }
    if ($script:Fixture.FailStage -eq 'MountIdentity') { $script:Fixture.NewVolume.UniqueId = 'volume-other' }
}

function Assert-VolumeAccessible([string]$RootPath) {
    if ($RootPath -ne 'D:\' -or -not $script:Fixture.Formatted -or
        -not $script:Fixture.VerifiedBeforeLetter) { throw 'Unsafe volume accessibility check.' }
    $script:Calls.Add('Access:new-volume')
    if ($script:Fixture.FailStage -eq 'Access') { throw 'Fixture volume access failure: the parameter is incorrect.' }
}

function Assert-DevDriveEmpty([string]$RootPath) {
    if ($RootPath -ne $script:Fixture.NewVolume.UniqueId) { throw 'Unexpected empty-check target' }
    $script:Fixture.EmptyReads++
    if ($script:Fixture.NotEmpty -or ($script:Fixture.BecomesNonEmpty -and
        (Get-Content -LiteralPath (Get-AttemptPath 'pool-fixture') -Raw | ConvertFrom-Json).Status -eq
            'RemovalStarted-NoAutomaticRetry')) { throw 'The Dev Drive is not empty.' }
}

function Remove-VirtualDisk {
    [CmdletBinding(SupportsShouldProcess)] param($InputObject)
    if ($InputObject.UniqueId -ne 'new-vd') { throw 'Unsafe removal target' }
    $script:Calls.Add('Remove:new-vd')
    if ($script:Fixture.FailStage -eq 'Remove') { throw 'Fixture removal failure' }
    $script:Fixture.Created = $false
    $script:Fixture.NewDisk.PartitionStyle = 'RAW'
    if ($script:Fixture.FailStage -eq 'RemovePoolHealth') { $script:Fixture.Pool.HealthStatus = 'Unhealthy' }
    if ($script:Fixture.FailStage -eq 'RemoveMemberHealth') { $script:Fixture.Members[0].HealthStatus = 'Unhealthy' }
    if ($script:Fixture.FailStage -ne 'RemoveVerify') {
        $script:Fixture.Volumes = @($script:Fixture.Volumes | Where-Object UniqueId -NE 'volume-new')
    }
}

function New-RemovalRequest {
    [pscustomobject]@{ Mode = 'Remove'; Fingerprint = (Get-StorageSnapshot).RemovalFingerprint }
}

function New-Request {
    $snapshot = Get-StorageSnapshot
    [pscustomobject]@{ Fingerprint = $snapshot.Fingerprint; SizeGiB = 300; Mode = 'Create' }
}

try {
    $limits = Get-SizeGuidance 1000GB 100GB
    Assert-Test 'Size policy uses actual free capacity, not advertised Boot size' ($limits.MaximumGiB -eq 700)
    Assert-Test 'Size policy retains 20 percent or 100 GiB, whichever is greater' ($limits.HeadroomGiB -eq 200)
    Assert-Test 'Suggested starting size is capped at 300 GiB' ($limits.RecommendedGiB -eq 300)
    $limits = Get-SizeGuidance 200GB 20GB
    Assert-Test 'Small pools retain the 100 GiB floor' ($limits.MaximumGiB -eq 80 -and $limits.RecommendedGiB -eq 51)
    $limits = Get-SizeGuidance 200GB 51GB
    Assert-Test 'Less than 50 GiB allowance disables a suggested size' ($limits.MaximumGiB -eq 49 -and $limits.RecommendedGiB -eq 0)
    $limits = Get-SizeGuidance 200GB 50GB
    Assert-Test 'Minimum advertised space allows for GPT overhead above the Dev Drive minimum' (
        $limits.MinimumGiB -eq 51 -and $limits.MaximumGiB -eq 50 -and $limits.RecommendedGiB -eq 0)
    Assert-Throws 'Inconsistent pool capacity is an error' { Get-SizeGuidance 100GB 101GB } 'invalid'
    Reset-Fixture
    $snapshot = Get-StorageSnapshot
    Assert-Test 'Supported empty-of-Dev boot pool is eligible' $snapshot.CanCreate
    Assert-Test 'Inspection never invokes a mutating storage command' ($script:Calls.Count -eq 0)
    Assert-Test 'Displayed allocation separates logical size and actual footprint' (
        $snapshot.Spaces[0].LogicalBytes -eq 990GB -and $snapshot.Spaces[0].FootprintBytes -eq 90GB)
    $script:Fixture.OfflineDisk = $true
    $script:Fixture.OfflineId = 'nvme-fixture'
    Assert-Test 'Known pool member is not mistaken for an unrelated offline data disk' (Get-StorageSnapshot).CanCreate
    foreach ($case in @('ExistingRenamedDev', 'UnletteredDev', 'ProbeFailure', 'AdditionalSpace',
        'ReadOnly', 'Unhealthy', 'FixedBoot', 'MultipleMembers', 'NtfsWindows', 'NonSpacesWindows',
        'OfflineDisk', 'MissingFormatSupport', 'UnknownVolume')) {
        Reset-Fixture
        switch ($case) {
            'ExistingRenamedDev' { $script:Fixture.NewVolume.FileSystemLabel = 'Renamed'; $script:Fixture.Volumes += $script:Fixture.NewVolume }
            'UnletteredDev' { $script:Fixture.NewVolume.DriveLetter = ''; $script:Fixture.Volumes += $script:Fixture.NewVolume }
            'ProbeFailure' { $script:Fixture.ProbeError = $true }
            'AdditionalSpace' { $script:Fixture.AdditionalSpace = $true; $script:Fixture.NewVd.FriendlyName = 'Anything' }
            'ReadOnly' { $script:Fixture.Pool.IsReadOnly = $true }
            'Unhealthy' { $script:Fixture.Pool.HealthStatus = 'Unhealthy' }
            'FixedBoot' { $script:Fixture.Boot.ProvisioningType = 'Fixed' }
            'MultipleMembers' { $script:Fixture.Members += $script:Fixture.Members[0] }
            'NtfsWindows' { $script:Fixture.Volumes[0].FileSystemType = 'NTFS' }
            'NonSpacesWindows' { $script:Fixture.OsDisk.BusType = 'NVMe' }
            'OfflineDisk' { $script:Fixture.OfflineDisk = $true }
            'MissingFormatSupport' { $script:Fixture.HasDevDriveParameter = $false }
            'UnknownVolume' { $script:Fixture.NewVolume.FileSystemType = 'Unknown'; $script:Fixture.Volumes += $script:Fixture.NewVolume }
        }
        $snapshot = Get-StorageSnapshot
        Assert-Test "Creation fails closed: $case" (-not $snapshot.CanCreate -and $snapshot.BlockReasons.Count -gt 0)
    }
    foreach ($size in @(-1, 0, 49, 50, 700.5, 701, 'NaN')) {
        Reset-Fixture
        $request = New-Request
        $request.SizeGiB = $size
        Assert-Throws "Rejecting invalid or out-of-range size: $size" { Invoke-CreateDevDrive $request } '.'
        Assert-Test "No provisioning on invalid size: $size" ($script:Calls.Count -eq 0)
    }
    Reset-Fixture
    $request = New-Request
    $request.Fingerprint = 'stale'
    Assert-Throws 'Changed target or partition fingerprint blocks creation' { Invoke-CreateDevDrive $request } 'changed since review'
    Assert-Test 'Stale target never reaches a write command' ($script:Calls.Count -eq 0)
    Reset-Fixture
    $request = New-Request
    $script:Fixture.PoolReads = 0
    $script:Fixture.ExhaustOnSecondRead = $true
    Assert-Throws 'Capacity is rechecked again under the creation mutex' { Invoke-CreateDevDrive $request } 'Insufficient'
    Assert-Test 'Freshly exhausted capacity invokes no storage writes' ($script:Calls.Count -eq 0)
    Reset-Fixture
    $result = Invoke-CreateDevDrive (New-Request)
    Assert-Test 'Happy path creates a verified Dev Drive' ($result.Success -and $result.CreatedDrive -eq 'D:')
    Assert-Test 'Only the new virtual disk and its new partition are modified' (
        ($script:Calls -join ',') -ceq 'Create:Dev,Initialize:new-vd,Partition:7,Format:new-partition,Mount:new-partition,Access:new-volume')
    Assert-Test 'Formatting and native verification finish before any drive letter is assigned' (
        $script:Fixture.Formatted -and $script:Fixture.VerifiedBeforeLetter)
    $record = Get-Content -LiteralPath $result.LogPath -Raw | ConvertFrom-Json
    Assert-Test 'Completed record persists stable created disk and volume identities' (
        $record.Status -eq 'Completed' -and $record.CreatedVirtualDiskId -eq 'new-vd' -and $record.VolumeId -eq 'volume-new')
    Assert-Test 'Existing Dev Drive and receipt disable further creation' (-not $result.Snapshot.CanCreate)
    $script:Calls.Clear()
    Assert-Throws 'A repeated run does not create another space' { Invoke-CreateDevDrive (New-Request) } 'existing Dev Drive|previous creation'
    Assert-Test 'Repeated run issues no storage write' ($script:Calls.Count -eq 0)
    foreach ($stage in @('Create', 'Initialize', 'Format', 'PreMountProbe', 'Mount', 'Access')) {
        Reset-Fixture
        $script:Fixture.FailStage = $stage
        Assert-Throws "Partial failure is reported: $stage" { Invoke-CreateDevDrive (New-Request) } 'Fixture'
        $path = Get-AttemptPath 'pool-fixture'
        Assert-Test "Partial failure retains a failed one-shot record: $stage" (
            (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).Status -eq 'Failed-NoAutomaticRetry')
        Assert-Test "Partial failure disables future creation: $stage" (-not (Get-StorageSnapshot).CanCreate)
        if ($stage -in @('Format', 'PreMountProbe')) {
            Assert-Test "An unverified volume never receives a letter: $stage" (
                -not ($script:Calls -contains 'Mount:new-partition') -and -not $script:Fixture.NewVolume.DriveLetter)
        }
        if ($stage -in @('Mount', 'Access')) {
            Assert-Test "Verified volume identity survives a letter/access failure: $stage" (
                (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).VolumeId -eq 'volume-new')
        }
    }
    foreach ($case in @('BootDisk', 'NonRaw', 'WrongPool', 'WrongNewId')) {
        Reset-Fixture
        switch ($case) {
            'BootDisk' { $script:Fixture.NewDisk.IsBoot = $true }
            'NonRaw' { $script:Fixture.NewDisk.PartitionStyle = 'GPT' }
            'WrongPool' { $script:Fixture.WrongNewPool = $true }
            'WrongNewId' { $script:Fixture.NewVd.UniqueId = 'boot-fixture' }
        }
        Assert-Throws "Unsafe newly returned disk is rejected: $case" { Invoke-CreateDevDrive (New-Request) } '.'
        Assert-Test "Unsafe disk is never initialized: $case" (-not ($script:Calls -contains 'Initialize:new-vd'))
    }
    Reset-Fixture
    $script:Fixture.NewVolume.IsDev = $false
    Assert-Throws 'A plain ReFS format is not accepted as a Dev Drive' { Invoke-CreateDevDrive (New-Request) } 'could not be verified'
    Assert-Test 'Plain ReFS is never exposed as a new drive letter' (
        -not ($script:Calls -contains 'Mount:new-partition'))
    foreach ($stage in @('NoLetter', 'MountIdentity', 'LetterMapping')) {
        Reset-Fixture
        $script:Fixture.FailStage = $stage
        Assert-Throws "Invalid post-format mount is rejected: $stage" { Invoke-CreateDevDrive (New-Request) } 'drive letter'
        Assert-Test "No root access on an invalid mount: $stage" (
            -not ($script:Calls -contains 'Access:new-volume'))
    }
    $beforeAccess = (Get-ChildItem -LiteralPath $testRoot -Force | Select-Object -ExpandProperty Name) -join ','
    & $realAccessCheck $testRoot
    Assert-Test 'Real accessibility check reads an existing directory without writing' (
        ((Get-ChildItem -LiteralPath $testRoot -Force | Select-Object -ExpandProperty Name) -join ',') -ceq $beforeAccess)
    Assert-Throws 'Real accessibility check rejects a missing volume root' {
        & $realAccessCheck (Join-Path $testRoot 'missing-root')
    } '.'
    Reset-Fixture
    $script:Fixture.FailStage = 'FinalHealth'
    Assert-Throws 'A new unhealthy space is not reported as successful' { Invoke-CreateDevDrive (New-Request) } 'health.*verification failed'
    Reset-Fixture
    $script:Fixture.ChangePartitions = $true
    Assert-Throws 'Unexpected original Windows partition changes prevent success' { Invoke-CreateDevDrive (New-Request) } 'partition layout changed'
    Reset-Fixture
    $path = Get-AttemptPath 'pool-fixture'
    [IO.Directory]::CreateDirectory((Split-Path $path), (Get-ReceiptSecurity -Directory)) | Out-Null
    'broken json' | Set-Content -LiteralPath $path
    Assert-Test 'Unreadable prior attempt record blocks creation' (-not (Get-StorageSnapshot).CanCreate)
    Assert-Throws 'CreateNew does not overwrite an existing creation record' {
        Write-CreationRecord -Path $path -Record @{ Status = 'Started' } -New
    } '.'
    Reset-Fixture
    Invoke-CreateDevDrive (New-Request) | Out-Null
    Assert-Test 'Recorded healthy empty Dev space is removable' (Get-StorageSnapshot).CanRemove
    $script:Calls.Clear()
    $removed = Invoke-RemoveDevDrive (New-RemovalRequest)
    Assert-Test 'Only the recorded virtual disk is removed' (($script:Calls -join ',') -ceq 'Remove:new-vd')
    Assert-Test 'Removal persists a verified Removed record' (
        (Get-Content -LiteralPath $removed.LogPath -Raw | ConvertFrom-Json).Status -eq 'Removed')
    Assert-Test 'Successful removal does not retain an in-progress review warning' (
        $removed.Snapshot.RemoveReason -eq 'No recorded Dev Drive remains.')
    Assert-Test 'Fresh inspection permits creation after verified removal' (Get-StorageSnapshot).CanCreate
    Invoke-CreateDevDrive (New-Request) | Out-Null
    $archives = @(Get-ChildItem -LiteralPath (Join-Path (Split-Path $removed.LogPath) 'History') -File)
    Assert-Test 'Explicit recreation preserves the prior removal record' (
        $archives.Count -eq 1 -and (Get-Content -LiteralPath $archives[0].FullName -Raw | ConvertFrom-Json).Status -eq 'Removed')
    foreach ($case in @('NotEmpty', 'Stale', 'BootDisk', 'SystemDisk', 'PhysicalMember',
        'WrongOwner', 'WrongVolume', 'WrongPool', 'ExtraSpace', 'EfiPartition', 'NotDev',
        'Unhealthy', 'UnknownRemoval', 'ChangedWindows')) {
        Reset-Fixture
        Invoke-CreateDevDrive (New-Request) | Out-Null
        $request = New-RemovalRequest
        $path = Get-AttemptPath 'pool-fixture'
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        switch ($case) {
            'NotEmpty' { $script:Fixture.NotEmpty = $true }
            'Stale' { $request.Fingerprint = 'stale' }
            'BootDisk' { $script:Fixture.NewDisk.IsBoot = $true }
            'SystemDisk' { $script:Fixture.NewDisk.IsSystem = $true }
            'PhysicalMember' { $script:Fixture.NewDisk.UniqueId = 'nvme-fixture' }
            'WrongOwner' { $record.CreatedVirtualDiskId = 'boot-fixture' }
            'WrongVolume' { $record.VolumeId = 'unrelated-volume' }
            'WrongPool' { $script:Fixture.WrongNewPool = $true }
            'ExtraSpace' { $script:Fixture.ExtraSpace = $true }
            'EfiPartition' { $script:Fixture.NewPartitions[0].GptType = 'efi' }
            'NotDev' { $script:Fixture.NewVolume.IsDev = $false }
            'Unhealthy' { $script:Fixture.Pool.HealthStatus = 'Unhealthy' }
            'UnknownRemoval' { $record.Status = 'RemovalStarted-NoAutomaticRetry' }
            'ChangedWindows' { $script:Fixture.BootPartitions[1].Size -= 1GB }
        }
        Write-CreationRecord -Path $path -Record $record
        $script:Calls.Clear()
        Assert-Throws "Unsafe removal is refused: $case" { Invoke-RemoveDevDrive $request } '.'
        Assert-Test "Unsafe removal issues no storage write: $case" ($script:Calls.Count -eq 0)
    }
    Reset-Fixture
    Invoke-CreateDevDrive (New-Request) | Out-Null
    $path = Get-AttemptPath 'pool-fixture'
    $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $record.Status = 'Failed-NoAutomaticRetry'
    $record.VolumeId = ''
    Write-CreationRecord -Path $path -Record $record
    Assert-Test 'A formatted Dev from failed final verification is removable by stable ownership' (Get-StorageSnapshot).CanRemove
    $script:Fixture.NewVolume.DriveLetter = ''
    Assert-Test 'A renamed or unlettered owned Dev remains removable' (Get-StorageSnapshot).CanRemove
    foreach ($stage in 'Remove', 'RemoveVerify', 'RemovePoolHealth', 'RemoveMemberHealth', 'BecomesNonEmpty') {
        Reset-Fixture
        Invoke-CreateDevDrive (New-Request) | Out-Null
        $request = New-RemovalRequest
        if ($stage -eq 'BecomesNonEmpty') { $script:Fixture.BecomesNonEmpty = $true }
        else { $script:Fixture.FailStage = $stage }
        $script:Calls.Clear()
        Assert-Throws "Removal failure is surfaced: $stage" { Invoke-RemoveDevDrive $request } '.'
        $record = Get-Content -LiteralPath (Get-AttemptPath 'pool-fixture') -Raw | ConvertFrom-Json
        Assert-Test "Removal failure is durably blocked: $stage" ($record.Status -eq 'RemovalFailed-NoAutomaticRetry')
        Assert-Test "No automatic repeat after removal failure: $stage" (-not (Get-StorageSnapshot).CanRemove)
        if ($stage -eq 'BecomesNonEmpty') {
            Assert-Test 'Emptiness is rechecked immediately before deletion' ($script:Calls.Count -eq 0)
        }
    }
    foreach ($case in @('DirectoryOwner', 'DirectoryWrite', 'DirectoryLink', 'FileOwner', 'FileWrite', 'FileLink')) {
        Reset-Fixture
        $path = Get-AttemptPath 'pool-fixture'
        $root = Split-Path $path
        $record = @{ Status = 'Started-NoAutomaticRetry'; Error = '' }
        $outside = Join-Path $env:ProgramData 'outside'
        New-Item -ItemType Directory -Path $outside | Out-Null
        $victim = Join-Path $outside 'victim.json'
        Set-Content -LiteralPath $victim -Value '{"preserve":"original"}'
        $original = (Get-FileHash -LiteralPath $victim).Hash
        if ($case -eq 'DirectoryLink') {
            New-Item -ItemType Junction -Path $root -Target $outside | Out-Null
        }
        elseif ($case -like 'Directory*') {
            $acl = Get-ReceiptSecurity -Directory
            if ($case -eq 'DirectoryOwner') {
                $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
            }
            else {
                $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                    [Security.Principal.SecurityIdentifier]::new('S-1-1-0'), 'Modify',
                    'ContainerInherit, ObjectInherit', 'None', 'Allow'))
            }
            [IO.Directory]::CreateDirectory($root, $acl) | Out-Null
        }
        else {
            Write-CreationRecord -Path $path -Record $record -New
            if ($case -eq 'FileLink') {
                Remove-Item -LiteralPath $path
                New-Item -ItemType SymbolicLink -Path $path -Target $victim | Out-Null
            }
            else {
                $acl = Get-ReceiptSecurity
                if ($case -eq 'FileOwner') {
                    $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
                }
                else {
                    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                        [Security.Principal.SecurityIdentifier]::new('S-1-1-0'), 'Write', 'Allow'))
                }
                Set-Acl -LiteralPath $path -AclObject $acl
            }
        }
        $arguments = @{ Path = $path; Record = $record; New = ($case -like 'Directory*') }
        Assert-Throws "Unsafe receipt writes are refused: $case" {
            Write-CreationRecord @arguments
        } 'unsafe|untrusted|links'
        Assert-Test "Unsafe receipts cannot authorize creation or removal: $case" (
            -not (Get-StorageSnapshot).CanCreate -and -not (Get-StorageSnapshot).CanRemove -and
            $script:Calls.Count -eq 0)
        Assert-Test "Receipt redirection cannot change an unrelated file: $case" (
            (Get-FileHash -LiteralPath $victim).Hash -ceq $original)
        if ($case -eq 'DirectoryLink') { [IO.Directory]::Delete($root) }
        if ($case -eq 'FileLink') { [IO.File]::Delete($path) }
    }
    Reset-Fixture
    $path = Get-AttemptPath 'pool-fixture'
    $handles = Open-ReceiptDirectory $path -Create
    try {
        Assert-Throws 'Receipt directory locks prevent directory replacement' {
            [IO.Directory]::Move((Split-Path $path), (Join-Path $env:ProgramData 'replaced'))
        } '.'
    } finally { foreach ($handle in $handles) { $handle.Dispose() } }
    $emptyRoot = Join-Path $testRoot 'empty-volume'
    New-Item -ItemType Directory -Path $emptyRoot | Out-Null
    & $realEmptyCheck $emptyRoot
    Assert-Test 'An empty filesystem root passes the real empty check' $true
    New-Item -ItemType Directory -Path (Join-Path $emptyRoot 'System Volume Information') | Out-Null
    $recycle = Join-Path $emptyRoot '$Recycle.Bin'
    New-Item -ItemType Directory -Path $recycle | Out-Null
    Set-Content -LiteralPath (Join-Path $recycle 'desktop.ini') -Value 'metadata'
    & $realEmptyCheck $emptyRoot
    Assert-Test 'Only system and empty Recycle Bin metadata are excluded' $true
    Set-Content -LiteralPath (Join-Path $recycle 'recycled-data.txt') -Value 'data'
    Assert-Throws 'Recycled user data prevents deletion' { & $realEmptyCheck $emptyRoot } 'Recycle Bin'
    Remove-Item -LiteralPath (Join-Path $recycle 'recycled-data.txt')
    Set-Content -LiteralPath (Join-Path $emptyRoot 'user.txt') -Value 'data'
    Assert-Throws 'User data prevents deletion' { & $realEmptyCheck $emptyRoot } 'not empty'
    Remove-Item -LiteralPath (Join-Path $emptyRoot 'user.txt')
    New-Item -ItemType Directory -Path (Join-Path $emptyRoot 'user-folder') | Out-Null
    Assert-Throws 'Even an empty user directory prevents deletion' { & $realEmptyCheck $emptyRoot } 'not empty'
    Remove-Item -LiteralPath (Join-Path $emptyRoot 'user-folder')
    $linkTarget = Join-Path $testRoot 'link-target'
    New-Item -ItemType Directory -Path $linkTarget | Out-Null
    $link = Join-Path $emptyRoot 'link'
    New-Item -ItemType Junction -Path $link -Target $linkTarget | Out-Null
    Assert-Throws 'A directory link is never followed or treated as an empty drive' {
        & $realEmptyCheck $emptyRoot
    } 'link'
    Remove-Item -LiteralPath $link -Force
    Assert-Throws 'Unreadable or missing roots do not count as empty' {
        & $realEmptyCheck (Join-Path $testRoot 'missing-root')
    } '.'
    Write-Host "Passed $($script:Checks.Count) non-destructive storage backend checks."
    [pscustomobject]@{ Passed = $script:Checks.Count; RealStorageWrites = 0; Checks = $script:Checks.ToArray() }
}
finally {
    $env:ProgramData = $originalProgramData
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
