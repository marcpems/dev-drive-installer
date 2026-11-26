[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('x64', 'Arm64')]
    [string]$Architecture,
    [string]$PublishDirectory,
    [string]$OutputDirectory,
    [version]$Version = '1.0.0.0',
    [switch]$Sign,
    [string]$CertificatePath,
    [Security.SecureString]$CertificatePassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Sign -and (-not $CertificatePath -or -not $CertificatePassword)) {
    throw 'Signing requires an external PFX certificate and its secure password. Private keys must not be stored in the repository.'
}
$root = Split-Path $PSScriptRoot
if (-not $PublishDirectory) { $PublishDirectory = Join-Path $root "artifacts\$Architecture" }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'artifacts' }
if ($Version.Major -lt 1 -or $Version.Build -lt 0 -or $Version.Revision -lt 0 -or
    @($Version.Major, $Version.Minor, $Version.Build, $Version.Revision |
        Where-Object { $_ -gt 65535 }).Count -gt 0) {
    throw 'MSIX version must have four components in 0..65535 and a nonzero major version.'
}
[xml]$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'AppxManifest.xml') -Raw
if ($Sign) {
    $CertificatePath = (Resolve-Path -LiteralPath $CertificatePath).Path
    $pfxData = Get-PfxData -FilePath $CertificatePath -Password $CertificatePassword
    if (@($pfxData.EndEntityCertificates).Count -ne 1 -or $pfxData.OtherCertificates) {
        throw 'The signing PFX must contain exactly one standalone signing certificate.'
    }
    $inspection = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $CertificatePath, $CertificatePassword,
        [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
    try {
        if (-not $inspection.HasPrivateKey -or $inspection.Subject -cne $manifest.Package.Identity.Publisher -or
            $inspection.NotBefore -gt (Get-Date) -or $inspection.NotAfter -le (Get-Date)) {
            throw 'The external signing certificate must be valid and match the package publisher.'
        }
        if (Test-Path -LiteralPath "Cert:\CurrentUser\My\$($inspection.Thumbprint)") {
            throw 'The signing certificate already exists in the current-user store; refusing to replace or delete its existing private key.'
        }
    } finally { $inspection.Dispose() }
}
$PublishDirectory = (Resolve-Path -LiteralPath $PublishDirectory).Path
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$sdk = Get-ChildItem -LiteralPath $sdkRoot -Directory |
    Where-Object { $_.Name -match '^\d+\.\d+\.\d+\.\d+$' } |
    Sort-Object { [version]$_.Name } -Descending |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'x64\makeappx.exe') } |
    Select-Object -First 1
if (-not $sdk) { throw 'Windows SDK x64 MSIX packaging tools are required.' }
$makeappx = Join-Path $sdk.FullName 'x64\makeappx.exe'
$signtool = Join-Path $sdk.FullName 'x64\signtool.exe'
$stage = Join-Path $OutputDirectory "msix-stage-$Architecture"
if (Test-Path -LiteralPath $stage) {
    throw "A previous staging directory exists. Review it before rebuilding: $stage"
}
foreach ($name in 'DevDriveInstaller.exe', 'App.xbf', 'MainWindow.xbf', 'DevDriveInstaller.pri') {
    if (-not (Test-Path -LiteralPath (Join-Path $PublishDirectory $name) -PathType Leaf)) {
        throw "Required published application file is missing: $name"
    }
}
New-Item -ItemType Directory -Path $stage | Out-Null
Get-ChildItem -LiteralPath $PublishDirectory -Force |
    Copy-Item -Destination $stage -Recurse
# Packaged WinUI resolves its primary resource index from resources.pri.
Copy-Item -LiteralPath (Join-Path $stage 'DevDriveInstaller.pri') `
    -Destination (Join-Path $stage 'resources.pri')
$manifest.Package.Identity.ProcessorArchitecture = $Architecture.ToLowerInvariant()
$manifest.Package.Identity.Version = $Version.ToString()
# Package identity needs the SDK's WinRT registrations, not just desktop SxS activation.
$activationPath = Join-Path $OutputDirectory "activation-$Architecture.manifest"
& (Join-Path $sdk.FullName 'x64\mt.exe') `
    "-inputresource:$PublishDirectory\DevDriveInstaller.exe;#1" "-out:$activationPath" -nologo
if ($LASTEXITCODE -ne 0) { throw 'Cannot read the embedded runtime activation manifest.' }
[xml]$activation = Get-Content -LiteralPath $activationPath -Raw
$namespace = $manifest.DocumentElement.NamespaceURI
$extensions = $manifest.CreateElement('Extensions', $namespace)
$classCount = 0
foreach ($file in $activation.SelectNodes("//*[local-name()='file']")) {
    $classes = @($file.ChildNodes | Where-Object LocalName -EQ 'activatableClass')
    if ($classes.Count -eq 0) { continue }
    $dll = $file.GetAttribute('name')
    if (-not (Test-Path -LiteralPath (Join-Path $stage $dll) -PathType Leaf)) {
        throw "An SDK activation server is missing from the package: $dll"
    }
    $extension = $manifest.CreateElement('Extension', $namespace)
    $extension.SetAttribute('Category', 'windows.activatableClass.inProcessServer')
    $server = $manifest.CreateElement('InProcessServer', $namespace)
    $path = $manifest.CreateElement('Path', $namespace)
    $path.InnerText = $dll
    [void]$server.AppendChild($path)
    foreach ($class in $classes) {
        $entry = $manifest.CreateElement('ActivatableClass', $namespace)
        $entry.SetAttribute('ActivatableClassId', $class.GetAttribute('name'))
        $model = switch ($class.GetAttribute('threadingModel').ToLowerInvariant()) {
            'both' { 'both' }
            'sta' { 'STA' }
            'mta' { 'MTA' }
            default { throw 'Unsupported SDK WinRT threading model.' }
        }
        $entry.SetAttribute('ThreadingModel', $model)
        [void]$server.AppendChild($entry)
        $classCount++
    }
    [void]$extension.AppendChild($server)
    [void]$extensions.AppendChild($extension)
}
if ($classCount -eq 0) { throw 'No Windows App SDK WinRT activation classes were found.' }
[void]$manifest.Package.InsertBefore($extensions, $manifest.Package.Capabilities)
$settings = [Xml.XmlWriterSettings]::new()
$settings.Indent = $true
$settings.Encoding = [Text.UTF8Encoding]::new($false)
$writer = [Xml.XmlWriter]::Create((Join-Path $stage 'AppxManifest.xml'), $settings)
try { $manifest.Save($writer) } finally { $writer.Dispose() }

Add-Type -AssemblyName System.Drawing
$assets = Join-Path $stage 'Assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null
$icon = [Drawing.Icon]::new((Join-Path $assets 'AppIcon.ico'))
$iconBitmap = $icon.ToBitmap()
try {
    foreach ($asset in @(@{ Name = 'StoreLogo.png'; Size = 50 },
        @{ Name = 'Square44x44Logo.png'; Size = 44 },
        @{ Name = 'Square150x150Logo.png'; Size = 150 })) {
        $bitmap = [Drawing.Bitmap]::new($asset.Size, $asset.Size)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::Transparent)
            $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($iconBitmap, 0, 0, $asset.Size, $asset.Size)
            $bitmap.Save((Join-Path $assets $asset.Name), [Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
} finally { $iconBitmap.Dispose(); $icon.Dispose() }
$package = Join-Path $OutputDirectory "DevDriveInstaller-$Architecture.msix"
& $makeappx pack /d $stage /p $package /o
if ($LASTEXITCODE -ne 0) { throw "MSIX schema/payload validation failed: $LASTEXITCODE" }

if ($Sign) {
    if (-not (Test-Path -LiteralPath $signtool)) { throw 'Windows SDK signtool is required.' }
    $certificate = @()
    try {
        $certificate = Import-PfxCertificate -FilePath $CertificatePath -Password $CertificatePassword `
            -CertStoreLocation 'Cert:\CurrentUser\My'
        if (@($certificate).Count -ne 1 -or -not $certificate.HasPrivateKey) {
            throw 'The signing PFX must contain exactly one signing certificate with a private key.'
        }
        $publicCertificate = Join-Path $OutputDirectory "DevDriveInstaller-$Architecture.cer"
        Export-Certificate -Cert $certificate -FilePath $publicCertificate | Out-Null
        & $signtool sign /fd SHA256 /s My /sha1 $certificate.Thumbprint $package
        if ($LASTEXITCODE -ne 0) { throw "MSIX signing failed: $LASTEXITCODE" }
        $signature = Get-AuthenticodeSignature -LiteralPath $package
        if (-not $signature.SignerCertificate -or
            $signature.SignerCertificate.Thumbprint -cne $certificate.Thumbprint) {
            throw 'The signed package does not expose the expected signing certificate.'
        }
    } finally {
        foreach ($imported in @($certificate)) {
            if ($imported.HasPrivateKey) {
                Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($imported.Thumbprint)" -DeleteKey
            }
            else { Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($imported.Thumbprint)" }
        }
        if (Test-Path -LiteralPath "Cert:\CurrentUser\My\$($pfxData.EndEntityCertificates[0].Thumbprint)") {
            Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($pfxData.EndEntityCertificates[0].Thumbprint)" -DeleteKey
        }
    }
}
$hash = Get-FileHash -LiteralPath $package -Algorithm SHA256
"$($hash.Hash)  $([IO.Path]::GetFileName($package))" |
    Set-Content -LiteralPath "$package.sha256" -Encoding ascii
Write-Host "MSIX built: $package. No package installation or certificate trust changes performed."
