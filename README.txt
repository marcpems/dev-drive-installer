DEV DRIVE INSTALLER

The app, package, executable and receipt directory use DevDriveInstaller.
The 1.1 series retains that package identity, receipt schema and mutex name.
It starts a new build-number series and uses a replacement signing certificate.
Existing DevDriveInstaller packages can upgrade after the new downloaded CER
is reviewed and trusted; no storage recreation or receipt migration is needed.
Receipt security requirements still apply: directories from older versions may
need administrator review, and unsafe permissions are never repaired automatically.

UPGRADING FROM AN EARLIER PACKAGE IDENTITY

The following steps apply only to packages with a different identity, not to
DevDriveInstaller 1.0.13 or 1.0.14.

Stop and uninstall the earlier app before installing or running this version.
Never run earlier and current versions together: their cross-process mutex
names differ. Uninstalling the app does not delete an existing Dev Drive or
its operation receipts. Do not format, remove or recreate storage to upgrade.

Preserve the earlier ProgramData receipt directory. With both apps stopped,
copy its original per-pool JSON receipts and History directory into
%ProgramData%\DevDriveInstaller without modifying the contents or overwriting
any existing receipt. The pool-identity hash filenames and receipt schema are
unchanged. The app will verify those recorded identities against current storage
before offering removal. If you cannot identify the original receipts, stop:
do not delete safety records or use another removal tool to bypass ownership.
Receipt storage must be owned by Administrators or SYSTEM, with no write access
for other principals; the receipt/History directories must have protected ACLs.
Earlier directories or copied files may require administrator security review.
The app rejects unsafe ownership, permissions and links rather than taking
ownership or automatically repairing an existing directory. Preserve originals.

The main screen shows compact drive blocks side by side, with horizontal
scrolling only when their minimum widths exceed the window. Block widths scale
with logical volume capacity, retaining a 120-DIP minimum for readability;
larger windows redistribute the available width. The window has a DPI-aware
720-by-580-DIP preferred minimum size. Hover for complete capacity/health text.
Only volumes with a drive letter are shown.
The coloured bands resemble Disk Management, but represent volumes rather than
a physical-disk partition map. All volumes, including those without drive
letters, remain in the safety inventory and copied diagnostics.
The screen also shows filesystem usage and health, a compact
physical-pool allocation bar, and create/remove controls beside the size section.
Remove names the verified target drive letter (or the sole detected Dev Drive
while disabled); it never guesses between multiple targets. Hover tips
and Help explain sizing and shared capacity. There is no Details button.
Help's Copy diagnostics action copies the full inventory, previous record
errors and virtual-disk physical footprints. Main errors are concise; full
errors remain in diagnostics and durable operation receipts.
A wait spinner is shown during inspection, creation, removal and post-removal
refresh, not while awaiting a confirmation or reading Help.

GITHUB BUILDS

The Build Windows artifacts workflow runs on main pushes, pull requests to main,
and manual dispatch. It cross-compiles self-contained x64 and Arm64 releases on
Windows, runs the non-destructive backend fixture tests, and verifies required
runtime files, native architectures, and published app XAML resource hashes.
Native volume-probe tests also run under Windows PowerShell and PowerShell Core
with minimal compiler references. Exact volume paths use core GUID validation,
without relying on an implicitly referenced regular-expression assembly.
Main-branch builds upload a DevDriveInstaller-x64 or DevDriveInstaller-Arm64
artifact containing an application ZIP, signed MSIX installer, public signing
certificate and SHA256 checksums, retained for 30 days. Pull-request and other
branch builds produce unsigned validation packages without signing credentials.
Open the repository's Actions tab, select a completed workflow run, and download
the artifact for your device. Extract the artifact and then the application ZIP.
If the account's Actions artifact quota prevents uploads, main-branch/manual
builds publish the same files as architecture-specific prereleases instead.
Find those downloads in the repository's Releases page or the run's job summary.
The upload failure remains visible as a warning; releases are not created for
pull-request builds. No older account artifacts are automatically deleted.
Keep the entire architecture folder together; do not run just a copied executable.
CI does not launch the administrator app or create, format or remove real storage.
The separate transport integration test below is specific to the preparation
host's existing Dev Drive and is intentionally not run on hosted CI runners.

MSIX INSTALLATION

MSIX registers a Start-menu entry and supports normal Windows app removal.
It packages the same self-contained app; no separate runtime install is needed.
The packager imports Windows App SDK WinRT activation declarations from the
published executable and supplies the packaged WinUI resources.pri index.
The app still requires the normal administrator prompt when opened. Packaging
declares allowElevation and disables filesystem-write virtualization so the
one-time creation records remain shared in ProgramData, not private to the app.
Uninstalling the app does not remove storage spaces or ProgramData safety records.

CI signs with a stable self-signed development certificate, NOT a Microsoft
or publicly trusted publisher certificate. Its encrypted PFX and password are
GitHub Actions secrets in the release-signing environment, restricted to main.
Only trusted main-branch jobs use them. The PFX is decoded outside the repository
in runner temporary storage; the temporary PFX, imported certificate and private
key are removed after signing. Only the public CER is distributed.
Missing signing secrets fail release builds; there is no temporary-key fallback.
GitHub secrets are encrypted storage, not hardware-backed signing: maintainers
able to change trusted workflows can use or disclose them.
Review the repository/run and certificate before trusting it. In administrator
PowerShell on the target device, import only the matching downloaded certificate:

Import-Certificate -FilePath .\DevDriveInstaller-Arm64.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople

Then double-click DevDriveInstaller-Arm64.msix to install. Use x64 filenames on x64.
Alternatively use Add-AppxPackage -Path .\DevDriveInstaller-Arm64.msix after trust.
Managed-device sideloading policy may prohibit this; do not bypass that policy.
Future builds using the same certificate do not require a new trust import.
Certificate replacement or expiry requires renewed trust. Remove development
certificate trust when no longer needed. ZIP builds remain available without
MSIX installation or certificate trust.

The installer is built and signed without installing or opening the app on the
preparation host or CI. Actual MSIX installation/launch remains unqualified.

Small WinUI 3 application with x64 and Arm64 builds for a supported ReFS boot pool.
Copy the COMPLETE Arm64 folder onto an Arm64 device and run DevDriveInstaller.exe.
Approve the Windows administrator prompt. No .NET or Windows App SDK installation
is required: the release includes both runtimes. Do not copy just the executable.

Opening the app and Refresh perform read-only storage inspection. Create opens
one confirmation dialog stating WARNING: backup data before proceeding, with
the shared-capacity warning. Pool and drive IDs remain in copied diagnostics,
not this dialog. Remove also has an explicit permanent-deletion WARNING.
There is no separate backup checkbox on the main screen.
Cancel makes no storage changes.
Use the x64 folder only on an x64 Windows device; creation remains unavailable
unless the supported boot-pool topology is detected. A generic app name does
not mean arbitrary disks, ordinary partitions or VHDX layouts are supported.

DISPLAY AND SIZE POLICY

Shows physical pool capacity, allocated and unallocated bytes; virtual disk
advertised sizes and physical footprints; and connected volume allocation.
Native ReFS Dev Drive flags are checked, not friendly names or localized text.
An unlettered or renamed Dev Drive also prevents another setup.

Minimum advertised space size: 51 GiB, leaving room for GPT overhead above
the Dev Drive filesystem minimum.
Maximum: floor(physically unallocated pool GiB) minus safety headroom.
Safety headroom: the larger of 100 GiB or 20 percent of total pool capacity,
rounded up to a whole GiB. If less than 51 GiB remains, creation is disabled.
Suggestion: about half the permitted allowance, rounded down to 25 GiB,
limited to 51..300 GiB when eligible.

These are conservative planning limits, NOT reserved capacity. Boot and Dev
are thin-provisioned and share one SSD. Writing to C: or Dev consumes the same
physical pool. Their filesystem-free figures can exceed actual available
capacity. Monitor the physical allocation and maintain headroom. There is
no disk-failure redundancy.

GUARDS

Creation requires the running ReFS Windows volume to map to a healthy thin
Simple Boot space in a healthy, writable Boot pool with one healthy NVMe member.
It refuses an existing Dev Drive anywhere among connected volumes, an unknown
or uninspectable volume, an unrelated offline disk, or any extra space in the boot pool.
Disconnect unrelated offline/unknown disks before inspection if appropriate;
never initialize them merely to satisfy the app.

The app rechecks identities, Windows partition layout, all Dev Drive flags and
capacity after confirmation and again under an exclusive cross-process mutex.
It durably creates a per-pool CreateNew record BEFORE any storage mutation.
It creates a thin Simple data space named Dev, verifies its distinct RAW virtual disk, and initializes
and formats ONLY that new disk/partition using Format-Volume -DevDrive.
The new partition has no drive letter while formatting. ReFS size and native
Dev Drive status are verified through its volume identity first. Only then is
a drive letter assigned, its mapping rechecked, and its root read to confirm
accessibility. This avoids publishing a RAW drive to Explorer during formatting.
The verified volume identity is saved before letter assignment; mount/access
failures preserve the receipt without automatic cleanup or retry.
It does not resize, remove or format Boot, physical EFI, Windows or recovery,
change AV/filter policies, or set boot flags on the new data space.

Native Dev Drive designation, new space/pool health and unchanged original
Windows disk/member/partition identities are checked before reporting success.

CREATION RECORDS AND ERRORS

Receipts live in %ProgramData%\DevDriveInstaller\<pool-identity-hash>.json.
The actual path uses Windows' common application-data location, not a caller's
ProgramData environment override. New directories/files have explicit protected
Administrators/SYSTEM ACLs. Directory handles prevent replacement
during checks and receipt access; links and unsafe owners/write
permissions are refused before reading ownership records or updating them.
A Started, Failed, Completed, or unreadable record disables further creation
even after a restart. Partial operations are NEVER automatically deleted or
retried. Preserve the record and inspect the created space on failure.
Do not delete the record to force another attempt.

REMOVING AN EMPTY DEV SPACE

Remove is restricted to this tool's recorded virtual disk and a native-verified
healthy ReFS Dev Drive in the original boot pool. Friendly names alone never
authorize removal. A failed creation's formatted Dev Drive may be eligible if
the record identifies it and all current disk, pool, boot and native checks pass.
Unrelated Dev Drives, physical disks, Windows, EFI and recovery are not removed.

The volume must contain no user files, folders or links. Only the protected
System Volume Information directory and an empty Recycle Bin's metadata are
excluded. Recycled user data, inaccessible directories or unexpected links
block removal. Nothing is cleaned up automatically.

There is an explicit permanent-removal confirmation. Fresh ownership, identity
and emptiness checks run under the same global mutex used by creation, with an
additional empty check immediately before Remove-VirtualDisk. Close other apps:
the empty check does not lock the filesystem against a later concurrent writer.
Removal deletes only the verified Dev virtual disk, not the pool or its NVMe.
The original Windows identity/layout and absence of the Dev disk/volume are
checked before success. Failure preserves a no-automatic-retry record.

After verified removal, the app automatically refreshes the drive list and
rechecks whether creation can be enabled again. An inspection failure is shown
as a refresh failure, not a failed removal; use Refresh or Help to investigate.
The Removed receipt
is archived in the ProgramData History directory before a new atomic creation
record is written. Failed/incomplete removals are never silently retried.

The app cannot be closed normally while a create/remove process is running.
Do not shut down Windows, disconnect the disk, or kill the process during it.
The persistent record remains if the process or machine stops unexpectedly.

An approved read-only x64 preview was checked on the preparation host, including
minimum/maximized proportional layouts. The backend/transport was exercised,
including detection of its existing Dev Drive and disabled creation.
Actual device-side creation/removal and the Explorer popup fix remain unqualified.

This application and the underlying ReFS boot configuration are experimental.
Build and non-destructive tests do NOT qualify creation on the actual device.
Back up important data before using Create. No real storage creation or removal
was performed on the preparation host while developing this application.

BUILD AND TEST (PREPARATION HOST)

Requires .NET 8 or later SDK, Windows build tools, and package feed access.
Versions are pinned in DevDriveInstaller.csproj.

dotnet publish DevDriveInstaller.csproj -c Release -r win-arm64 -p:Platform=ARM64 -o artifacts\publish\Arm64
dotnet publish DevDriveInstaller.csproj -c Release -r win-x64 -p:Platform=x64 -o artifacts\publish\x64

With Windows SDK packaging tools installed, build an unsigned validation installer:
powershell.exe -NoProfile -File installer\Build-MSIX.ps1 -Architecture Arm64 -PublishDirectory artifacts\publish\Arm64
For local development signing, supply an external, standalone code-signing PFX
whose subject is CN=DevDriveInstaller, stored outside the repository. In a
PowerShell session, read its password securely and pass the SecureString:
$password = Read-Host 'PFX password' -AsSecureString
.\installer\Build-MSIX.ps1 -Architecture Arm64 -PublishDirectory artifacts\publish\Arm64 -Sign -CertificatePath C:\secure\signing.pfx -CertificatePassword $password
Never commit private keys or passwords, or include them in release assets.
Use a fresh artifacts\msix-stage-Arm64 directory for each build; an existing
staging directory is refused rather than silently replacing its contents.

Run tests with native Windows PowerShell:
powershell.exe -NoProfile -File tests\Test-StorageBackend.ps1
powershell.exe -NoProfile -File tests\Test-VolumeProbe.ps1
pwsh -NoProfile -File tests\Test-VolumeProbe.ps1
powershell.exe -NoProfile -File tests\Test-MSIX.ps1 -PublishDirectory artifacts\publish\x64

The preparation-host read-only integration test (expects its existing Dev Drive
and an unsupported/noneligible Windows boot topology):
dotnet run --project tests\Transport\Transport.csproj -c Release

Storage fixture tests replace discovery/mutation commands and write only
temporary receipts; no real storage configuration changes. MSIX tests create
temporary certificates/packages, verify unsigned isolation and signer checks,
and remove their private keys. They never install packages or add certificate trust.
