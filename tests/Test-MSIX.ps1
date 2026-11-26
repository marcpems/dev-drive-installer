param([Parameter(Mandatory)][string]$PublishDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$builder = Join-Path (Split-Path $PSScriptRoot) 'installer\Build-MSIX.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('DevDriveInstaller-signing-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $root
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent().User, 'FullControl',
    'ContainerInherit, ObjectInherit', 'None', 'Allow'))
Set-Acl -LiteralPath $root -AclObject $acl
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$bytes = [byte[]]::new(32)
$random.GetBytes($bytes)
$random.Dispose()
$password = ConvertTo-SecureString ([Convert]::ToBase64String($bytes)) -AsPlainText -Force
$certificates = @()
function Assert-Rejected([hashtable]$Arguments, [string]$Expected) {
    $rejected = $false
    try { & $builder -Architecture x64 -PublishDirectory $PublishDirectory @Arguments }
    catch {
        if ($_.Exception.Message -notlike $Expected) { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw "Expected refusal: $Expected" }
}
try {
    Assert-Rejected @{ Sign = $true } '*Signing requires an external PFX*'
    foreach ($subject in @('CN=UnrelatedTestPublisher', 'CN=DevDriveInstaller')) {
        $certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject `
            -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy Exportable `
            -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -NotAfter (Get-Date).AddDays(2)
        $certificates += $certificate.Thumbprint
        $pfx = Join-Path $root ($certificate.Thumbprint + '.pfx')
        Export-PfxCertificate -Cert $certificate -FilePath $pfx -Password $password `
            -ChainOption EndEntityCertOnly -CryptoAlgorithmOption AES256_SHA256 | Out-Null
        if ($subject -eq 'CN=UnrelatedTestPublisher') {
            Assert-Rejected @{ Sign = $true; CertificatePath = $pfx; CertificatePassword = $password } `
                '*must be valid and match the package publisher*'
        }
        else {
            Assert-Rejected @{ Sign = $true; CertificatePath = $pfx; CertificatePassword = $password } `
                '*already exists in the current-user store*'
        }
        if (-not (Get-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)").HasPrivateKey) {
            throw 'A rejected signing request modified an existing certificate.'
        }
        Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -DeleteKey
    }
    $unsigned = Join-Path $root 'unsigned'
    & $builder -Architecture x64 -PublishDirectory $PublishDirectory -OutputDirectory $unsigned
    if ((Get-AuthenticodeSignature -LiteralPath (Join-Path $unsigned 'DevDriveInstaller-x64.msix')).SignerCertificate -or
        (Test-Path -LiteralPath (Join-Path $unsigned 'DevDriveInstaller-x64.cer'))) {
        throw 'Unsigned validation packaging unexpectedly used a certificate.'
    }
    $signed = Join-Path $root 'signed'
    & $builder -Architecture x64 -PublishDirectory $PublishDirectory -OutputDirectory $signed `
        -Sign -CertificatePath $pfx -CertificatePassword $password
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $signed 'DevDriveInstaller-x64.msix')
    $public = [Security.Cryptography.X509Certificates.X509Certificate2]::new(
        (Join-Path $signed 'DevDriveInstaller-x64.cer'))
    try {
        if ($signature.SignerCertificate.Thumbprint -cne $certificate.Thumbprint -or
            $public.Thumbprint -cne $certificate.Thumbprint -or $public.HasPrivateKey -or
            (Test-Path -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)")) {
            throw 'Signed packaging did not preserve the expected public signer or clean up its private key.'
        }
    } finally { $public.Dispose() }
    Write-Host 'Passed 5 MSIX signing/unsigned isolation checks; no installation or trust changes.'
} finally {
    foreach ($thumbprint in $certificates) {
        if (Test-Path -LiteralPath "Cert:\CurrentUser\My\$thumbprint") {
            Remove-Item -LiteralPath "Cert:\CurrentUser\My\$thumbprint" -DeleteKey
        }
    }
    $password.Dispose()
    Remove-Item -LiteralPath $root -Recurse -Force
}
