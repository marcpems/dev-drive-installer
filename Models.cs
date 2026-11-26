using System.ComponentModel;

namespace DevDriveInstaller;

public sealed class StorageSnapshot
{
    public string Fingerprint { get; set; } = "";
    public string PoolName { get; set; } = "";
    public string MemberName { get; set; } = "";
    public string MemberSerial { get; set; } = "";
    public ulong PoolBytes { get; set; }
    public ulong AllocatedBytes { get; set; }
    public ulong PhysicalFreeBytes { get; set; }
    public long MinimumGiB { get; set; }
    public long MaximumGiB { get; set; }
    public long RecommendedGiB { get; set; }
    public long HeadroomGiB { get; set; }
    public bool CanCreate { get; set; }
    public bool CanRemove { get; set; }
    public string RemovalFingerprint { get; set; } = "";
    public string RemovableDrive { get; set; } = "";
    public ulong RemovableSizeBytes { get; set; }
    public string RemoveReason { get; set; } = "";
    public string[] BlockReasons { get; set; } = [];
    public SpaceAllocation[] Spaces { get; set; } = [];
    public VolumeAllocation[] Volumes { get; set; } = [];
    public IEnumerable<VolumeAllocation> LetteredVolumes => Volumes.Where(volume => volume.HasDriveLetter);
    public string[] DevDrives { get; set; } = [];
    public string RemoveLabel
    {
        get
        {
            string target = RemovableDrive.Length > 0 ? RemovableDrive :
                DevDrives.Length == 1 ? DevDrives[0] : "";
            return target.Length == 2 && char.IsAsciiLetter(target[0]) && target[1] == ':' ?
                $"Remove Dev Drive ({target})" : "Remove Dev Drive";
        }
    }
    public string AttemptStatus { get; set; } = "";
    public string AttemptError { get; set; } = "";
    public string Guidance { get; set; } = "";
}

public sealed class SpaceAllocation
{
    public string Name { get; set; } = "";
    public string Provisioning { get; set; } = "";
    public string Health { get; set; } = "";
    public ulong LogicalBytes { get; set; }
    public ulong FootprintBytes { get; set; }
    public string Display => $"{Name}  |  {Provisioning}  |  {Health}";
    public string Capacity => $"Advertised: {Units.GiB(LogicalBytes)} GiB    Physical footprint: {Units.GiB(FootprintBytes)} GiB";
}

public sealed class VolumeAllocation : INotifyPropertyChanged
{
    private double displayWidth = DriveLayout.MinimumWidth;
    public event PropertyChangedEventHandler? PropertyChanged;
    public double DisplayWidth
    {
        get => displayWidth;
        set
        {
            if (displayWidth == value) return;
            displayWidth = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(DisplayWidth)));
        }
    }
    public string Name { get; set; } = "";
    public string FileSystem { get; set; } = "";
    public string Location { get; set; } = "";
    public ulong SizeBytes { get; set; }
    public ulong FreeBytes { get; set; }
    public bool IsDevDrive { get; set; }
    public bool DevStatusKnown { get; set; }
    public string Health { get; set; } = "";
    public bool HasDriveLetter => Location.Length == 2 && char.IsAsciiLetter(Location[0]) && Location[1] == ':';
    public string Heading => $"{(HasDriveLetter ? Location : "No drive letter")}  {Name}";
    public string Status => $"{FileSystem} / " +
        $"{(IsDevDrive ? "Dev Drive / " : FileSystem == "ReFS" && !DevStatusKnown ? "Dev status unknown / " : "")}" +
        $"{(string.IsNullOrEmpty(Health) ? "Unknown" : Health)}";
    public double UsedPercent => SizeBytes == 0 ? 0 :
        Math.Clamp(100d * (SizeBytes - Math.Min(FreeBytes, SizeBytes)) / SizeBytes, 0, 100);
    public string Display => $"{Location}  {Name}  |  {FileSystem}{(IsDevDrive ? " / Dev Drive" : "")}";
    public string Capacity => $"Volume: {Units.GiB(SizeBytes)} GiB    Filesystem free: {Units.GiB(FreeBytes)} GiB";
    public string SizeText => $"{Units.GiB(SizeBytes)} GiB";
}

public static class DriveLayout
{
    public const double MinimumWidth = 120;
    private const double Gap = 10;

    public static double[] GetWidths(IReadOnlyList<VolumeAllocation> volumes, double viewportWidth)
    {
        if (!double.IsFinite(viewportWidth) || viewportWidth < 0)
            throw new ArgumentOutOfRangeException(nameof(viewportWidth));
        var widths = Enumerable.Repeat(MinimumWidth, volumes.Count).ToArray();
        double remaining = viewportWidth - volumes.Count * Gap;
        if (remaining <= volumes.Count * MinimumWidth) return widths;
        var pending = Enumerable.Range(0, volumes.Count).ToList();
        while (pending.Count > 0)
        {
            double total = pending.Sum(index => (double)volumes[index].SizeBytes);
            double ProposedWidth(int index) => total == 0 ? remaining / pending.Count :
                remaining * (volumes[index].SizeBytes / total);
            var small = pending.Where(index => ProposedWidth(index) < MinimumWidth).ToArray();
            if (small.Length == 0)
            {
                foreach (int index in pending) widths[index] = ProposedWidth(index);
                break;
            }
            foreach (int index in small)
            {
                remaining -= MinimumWidth;
                pending.Remove(index);
            }
        }
        return widths;
    }
}

public sealed class BackendResult
{
    public bool Success { get; set; }
    public string Error { get; set; } = "";
    public string LogPath { get; set; } = "";
    public string CreatedDrive { get; set; } = "";
    public StorageSnapshot? Snapshot { get; set; }
}

public static class Units
{
    public static string GiB(ulong value) => (value / 1073741824d).ToString("N1");
}
