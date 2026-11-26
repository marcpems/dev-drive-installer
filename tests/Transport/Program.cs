using DevDriveInstaller;

var inventory = new StorageSnapshot
{
    Volumes =
    [
        new() { Location = "C:" },
        new() { Location = @"\\?\Volume{00000000-0000-0000-0000-000000000001}\", IsDevDrive = true },
        new() { Location = "F:", IsDevDrive = true },
        new() { Location = "" },
        new() { Location = @"C:\Mount\Data" },
        new() { Location = "x:" },
        new() { Location = "1:" }
    ]
};
if (!inventory.LetteredVolumes.Select(volume => volume.Location).SequenceEqual(new[] { "C:", "F:", "x:" }))
    throw new InvalidOperationException("The drive-card list must include only lettered drives, in inventory order.");
if (inventory.Volumes.Length != 7 || inventory.Volumes.Count(volume => volume.IsDevDrive) != 2)
    throw new InvalidOperationException("Filtering drive cards must not remove unlettered volumes from the safety inventory.");
Console.WriteLine("Passed compact drive-list checks: lettered cards only; full inventory and unlettered Dev Drive retained.");

inventory.DevDrives = ["F:"];
if (inventory.RemoveLabel != "Remove Dev Drive (F:)")
    throw new InvalidOperationException("The single detected Dev Drive letter must appear on Remove, even while disabled.");
inventory.DevDrives = ["F:", "G:"];
if (inventory.RemoveLabel != "Remove Dev Drive")
    throw new InvalidOperationException("Remove must not guess between multiple Dev Drives.");
inventory.RemovableDrive = "G:";
if (inventory.RemoveLabel != "Remove Dev Drive (G:)")
    throw new InvalidOperationException("The verified removal target must take priority over other Dev Drives.");
inventory.RemovableDrive = @"\\?\Volume{00000000-0000-0000-0000-000000000001}\";
if (inventory.RemoveLabel != "Remove Dev Drive")
    throw new InvalidOperationException("An unlettered removal target must not borrow another drive's letter.");
Console.WriteLine("Passed 4 removal-label checks: detected/verified letters, ambiguous drives and unlettered targets.");

var sizedVolumes = new VolumeAllocation[] { new() { SizeBytes = 100 }, new() { SizeBytes = 300 } };
var widths = DriveLayout.GetWidths(sizedVolumes, 1000);
if (Math.Abs(widths[1] / widths[0] - 3) > 0.000001 || Math.Abs(widths.Sum() + 20 - 1000) > 0.000001)
    throw new InvalidOperationException("Drive widths must match capacity proportions and fill the viewport including gaps.");
var expanded = DriveLayout.GetWidths(sizedVolumes, 1400);
if (expanded[0] <= widths[0] || expanded[1] <= widths[1] || Math.Abs(expanded[1] / expanded[0] - 3) > 0.000001)
    throw new InvalidOperationException("Drive blocks must grow proportionally when the window expands.");
if (!DriveLayout.GetWidths(sizedVolumes, 200).SequenceEqual(new[] { 120d, 120d }))
    throw new InvalidOperationException("Narrow windows must retain readable minimum widths for horizontal scrolling.");
var uneven = new VolumeAllocation[] { new() { SizeBytes = 1 }, new() { SizeBytes = 100 }, new() { SizeBytes = 200 } };
if (!DriveLayout.GetWidths(uneven, 450).SequenceEqual(new[] { 120d, 120d, 180d }))
    throw new InvalidOperationException("Clamping small drives must redistribute the remaining width to larger drives.");
if (!DriveLayout.GetWidths(new VolumeAllocation[] { new(), new() }, 800).SequenceEqual(new[] { 390d, 390d }))
    throw new InvalidOperationException("Unknown zero capacities must use equal readable widths, not NaN.");
if (!DriveLayout.GetWidths(new VolumeAllocation[] { new() { SizeBytes = ulong.MaxValue }, new() { SizeBytes = ulong.MaxValue } },
    800).SequenceEqual(new[] { 390d, 390d }))
    throw new InvalidOperationException("Large capacities must not overflow the proportional width calculation.");
if (DriveLayout.GetWidths(Array.Empty<VolumeAllocation>(), 800).Length != 0)
    throw new InvalidOperationException("Empty inventories must produce no drive blocks.");
Console.WriteLine("Passed 7 proportional-layout checks: capacity ratios, resizing, minimum widths, redistribution and empty/zero/large capacities.");

var progress = "#< CLIXML\n<Objs><Obj S=\"progress\"><S>Completed</S></Obj></Objs>";
if (StorageService.WithoutProgressRecords(progress) != "")
    throw new InvalidOperationException("PowerShell progress was mistaken for a storage failure.");
foreach (var diagnostic in new[]
{
    "#< CLIXML\n<Objs><S S=\"Error\">Storage failed</S></Objs>",
    "#< CLIXML\n<Objs><S S=\"warning\">Storage warning</S></Objs>",
    "#< CLIXML\n<not-valid-xml",
    "Unstructured storage error"
})
{
    if (StorageService.WithoutProgressRecords(diagnostic) != diagnostic)
        throw new InvalidOperationException("A storage error, warning or unknown diagnostic was silently discarded.");
}
Console.WriteLine("Passed 5 PowerShell diagnostic-stream checks: progress only is ignored; errors and warnings remain visible.");

// Integration test: only the read-only request may be sent to the real host.
var result = await new StorageService().RunAsync("Inspect");
if (!result.Success || result.Snapshot is null)
    throw new InvalidOperationException(result.Error);
if (result.Snapshot.CanCreate)
    throw new InvalidOperationException("The preparation host must not be eligible for storage creation.");
if (result.Snapshot.BlockReasons.Length == 0 || result.Snapshot.Volumes.Length == 0)
    throw new InvalidOperationException("The read-only inventory or disabled-state explanation is missing.");
if (!result.Snapshot.Volumes.Any(volume => volume.IsDevDrive) ||
    result.Snapshot.DevDrives.Length == 0)
    throw new InvalidOperationException("The preparation host's existing Dev Drive was not detected.");
Console.WriteLine($"Passed read-only C# transport / Windows PowerShell integration: " +
    $"{result.Snapshot.Volumes.Length} volumes, existing Dev Drive detected, creation disabled. No storage writes.");
