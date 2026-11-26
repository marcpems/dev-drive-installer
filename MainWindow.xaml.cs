using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Windowing;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.UI;

namespace DevDriveInstaller;

public sealed partial class MainWindow : Window
{
    private readonly StorageService service = new();
    private StorageSnapshot? snapshot;
    private bool busy;
    private bool changingStorage;
    private string diagnostics = "";

    public MainWindow()
    {
        InitializeComponent();
        Title = "Dev Drive installer";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "AppIcon.ico"));
        AppWindow.Resize(new SizeInt32(940, 820));
        AppWindow.Closing += (_, args) => args.Cancel = changingStorage;
        Root.Loaded += async (_, _) =>
        {
            SetMinimumWindowSize();
            Root.XamlRoot.Changed += (_, _) => SetMinimumWindowSize();
            await RefreshAsync();
        };
    }

    private void SetMinimumWindowSize()
    {
        if (AppWindow.Presenter is not OverlappedPresenter presenter) return;
        double scale = Root.XamlRoot.RasterizationScale;
        int width = (int)Math.Ceiling(720 * scale);
        int height = (int)Math.Ceiling(580 * scale);
        if (presenter.PreferredMinimumWidth != width) presenter.PreferredMinimumWidth = width;
        if (presenter.PreferredMinimumHeight != height) presenter.PreferredMinimumHeight = height;
        if (AppWindow.Size.Width < width || AppWindow.Size.Height < height)
            AppWindow.Resize(new SizeInt32(Math.Max(width, AppWindow.Size.Width),
                Math.Max(height, AppWindow.Size.Height)));
    }

    private void Drives_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateDriveWidths();

    private void UpdateDriveWidths()
    {
        if (VolumesList.ItemsSource is not VolumeAllocation[] volumes || DrivesViewport.ActualWidth <= 0) return;
        var widths = DriveLayout.GetWidths(volumes, DrivesViewport.ActualWidth);
        for (int index = 0; index < volumes.Length; index++)
            volumes[index].DisplayWidth = widths[index];
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();

    private async Task RefreshAsync()
    {
        if (busy) return;
        SetBusy(true, "Reading drives...");
        snapshot = null;
        try { ApplyResult(await service.RunAsync("Inspect")); }
        catch (Exception exception) { ShowError(exception.Message, false); }
        finally { SetBusy(false); }
    }

    private void ApplyResult(BackendResult result)
    {
        if (!result.Success || result.Snapshot is null)
            throw new InvalidOperationException($"{result.Error}\n{result.LogPath}");
        snapshot = result.Snapshot;
        VolumesList.ItemsSource = snapshot.LetteredVolumes.ToArray();
        UpdateDriveWidths();
        PoolText.Text = snapshot.PoolBytes == 0 ? "" :
            $"Pool free: {Units.GiB(snapshot.PhysicalFreeBytes)} / {Units.GiB(snapshot.PoolBytes)} GiB";
        AllocationBar.Value = snapshot.PoolBytes == 0 ? 0 :
            Math.Clamp(100d * snapshot.AllocatedBytes / snapshot.PoolBytes, 0, 100);
        SizeBox.Minimum = snapshot.MinimumGiB;
        SizeBox.Maximum = Math.Max(snapshot.MinimumGiB, snapshot.MaximumGiB);
        SizeBox.Value = snapshot.RecommendedGiB >= snapshot.MinimumGiB ?
            snapshot.RecommendedGiB : double.NaN;
        SizeHintText.Text = snapshot.CanCreate ?
            $"Suggested {snapshot.RecommendedGiB} GiB\nRange {snapshot.MinimumGiB}-{snapshot.MaximumGiB} GiB" :
            "Creation unavailable. See Help.";
        diagnostics = string.Join("\n", snapshot.BlockReasons) + "\n" + snapshot.RemoveReason +
            $"\n\nPool: {snapshot.PoolName}\nSSD: {snapshot.MemberName} / {snapshot.MemberSerial}\n\n" +
            string.Join("\n", snapshot.Spaces.Select(space => $"{space.Display}\n{space.Capacity}")) +
            "\n\nAll volumes (including those without drive letters):\n" +
            string.Join("\n", snapshot.Volumes.Select(volume => $"{volume.Display}\n{volume.Capacity}")) +
            "\n\n" + snapshot.Guidance + $"\n\nRecord status: {snapshot.AttemptStatus}\n{snapshot.AttemptError}";
        StatusBar.Severity = snapshot.CanCreate ? InfoBarSeverity.Success : InfoBarSeverity.Informational;
        StatusBar.Title = snapshot.CanCreate ? "Ready" :
            snapshot.DevDrives.Length > 0 ? "Dev Drive found" : "Creation unavailable";
        StatusBar.Message = snapshot.CanCreate ? "" : snapshot.CanRemove ?
            $"{snapshot.RemovableDrive} is empty and can be removed." :
            snapshot.RemoveReason.Contains("not empty", StringComparison.OrdinalIgnoreCase) ||
                snapshot.RemoveReason.Contains("Recycle Bin", StringComparison.OrdinalIgnoreCase) ?
                "Move files and empty the Recycle Bin before removal." :
                "Open Help for guidance or copy diagnostics.";
        RemoveButton.Visibility = snapshot.DevDrives.Length > 0 || snapshot.CanRemove ?
            Visibility.Visible : Visibility.Collapsed;
        RemoveButton.Content = snapshot.RemoveLabel;
        ToolTipService.SetToolTip(RemoveButton, snapshot.CanRemove ?
            $"Remove the verified empty space at {snapshot.RemovableDrive}." : snapshot.RemoveReason);
        UpdateControls();
    }

    private void Size_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args) => UpdateControls();

    private void DriveBand_Loaded(object sender, RoutedEventArgs e)
    {
        if (sender is Border band && band.DataContext is VolumeAllocation volume)
            band.Background = new SolidColorBrush(volume.IsDevDrive ?
                Color.FromArgb(255, 16, 124, 16) : Color.FromArgb(255, 0, 95, 184));
    }

    private void UpdateControls()
    {
        if (SizeBox is null || CreateButton is null || RemoveButton is null) return;
        bool valid = snapshot?.CanCreate == true && double.IsFinite(SizeBox.Value) &&
            SizeBox.Value == Math.Floor(SizeBox.Value) &&
            SizeBox.Value >= snapshot.MinimumGiB && SizeBox.Value <= snapshot.MaximumGiB;
        CreateButton.IsEnabled = !busy && valid;
        RemoveButton.IsEnabled = !busy && snapshot?.CanRemove == true;
        SizeBox.IsEnabled = !busy && snapshot?.CanCreate == true;
        RefreshButton.IsEnabled = !busy;
        HelpButton.IsEnabled = !busy;
    }

    private void SetBusy(bool value, string message = "", bool working = true)
    {
        busy = value;
        ActivityText.Text = message;
        BusyRing.IsActive = value && working && message.Length > 0;
        BusyRing.Visibility = BusyRing.IsActive ? Visibility.Visible : Visibility.Collapsed;
        UpdateControls();
    }

    private void ShowError(string error, bool mutation)
    {
        snapshot = null;
        diagnostics = error;
        VolumesList.ItemsSource = null;
        RemoveButton.Content = "Remove Dev Drive";
        PoolText.Text = "";
        AllocationBar.Value = 0;
        SizeHintText.Text = "Refresh to read current storage.";
        StatusBar.Severity = InfoBarSeverity.Error;
        StatusBar.Title = mutation ? "Operation stopped" : "Storage unavailable";
        StatusBar.Message = error.Contains("not empty", StringComparison.OrdinalIgnoreCase) ||
            error.Contains("Recycle Bin", StringComparison.OrdinalIgnoreCase) ?
            "Move files and empty the Recycle Bin before removal." :
            mutation ? "Do not retry. Open Help to copy diagnostics." : "Refresh or open Help.";
        UpdateControls();
    }

    private async void Help_Click(object sender, RoutedEventArgs e)
    {
        if (busy) return;
        SetBusy(true);
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = "About Dev Drive installer",
                Content = new ScrollViewer
                {
                    MaxHeight = 420,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    Content = new TextBlock
                    {
                        TextWrapping = TextWrapping.Wrap,
                        Text = "x64 and Arm64 builds use the same storage checks. Creation currently requires " +
                        "Windows on a healthy ReFS, thin Simple Boot space with one NVMe member.\n\n" +
                        "Drive blocks show only volumes with drive letters, side by side. Scroll " +
                        "horizontally if their minimum widths exceed the window. Widths scale with " +
                        "logical volume capacity, with a minimum readable width for small volumes. " +
                        "These are volumes, not a physical partition map. " +
                        "All volumes, even those without a letter, are still checked before creating " +
                        "or removing storage.\n\n" +
                        "Drive cards show filesystem capacity. The pool bar shows physical allocation. " +
                        "Thin Windows and Dev spaces share capacity; free space is not reserved. " +
                        "There is no disk-failure redundancy.\n\n" +
                        "The size limit leaves at least 100 GiB or 20% of physical pool capacity free. " +
                        "The suggested starting size is at most 300 GiB.\n\n" +
                        "Removal is only for this tool's recorded Dev space. It must be empty; " +
                        "system volume metadata and empty Recycle Bin metadata are excluded. Close apps " +
                        "using the drive. Empty checks do not lock out another process writing to it.\n\n" +
                        "Failed operations retain a safety record. Do not delete it or retry blindly. " +
                        "After verified removal, the app refreshes automatically and checks whether " +
                        "another Dev Drive can be created.\n\n" +
                        "These boot-pool operations are experimental. Back up important data first.\n\n" +
                        "Copy diagnostics includes the full inventory and any saved error. " +
                        "Operation receipts are kept in %ProgramData%\\DevDriveInstaller."
                    }
                },
                PrimaryButtonText = "Copy diagnostics",
                CloseButtonText = "Close",
                DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            {
                var data = new DataPackage();
                data.SetText(diagnostics);
                Clipboard.SetContent(data);
            }
        }
        catch (Exception exception) { ShowError(exception.Message, false); }
        finally { SetBusy(false); }
    }

    private async void Create_Click(object sender, RoutedEventArgs e)
    {
        if (snapshot is null || !CreateButton.IsEnabled) return;
        var reviewed = snapshot;
        long size = checked((long)SizeBox.Value);
        SetBusy(true, "Awaiting confirmation...", false);
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = $"Create a {size:N0} GiB Dev Drive?",
                Content = "WARNING: backup data before proceeding.\n\n" +
                    "Windows and Dev share physical capacity. " +
                    "Only the new data space will be formatted. " +
                    "Windows, EFI and recovery are not resized or formatted.",
                PrimaryButtonText = "Create",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            changingStorage = true;
            SetBusy(true, "Creating and verifying. Do not shut down.");
            var result = await service.RunAsync("Create", reviewed.Fingerprint, size);
            ApplyResult(result);
            StatusBar.Severity = InfoBarSeverity.Success;
            StatusBar.Title = $"Dev Drive ready: {result.CreatedDrive}";
            StatusBar.Message = "Creation is disabled while this drive exists.";
            diagnostics += $"\nReceipt: {result.LogPath}";
        }
        catch (Exception exception) { ShowError(exception.Message, true); }
        finally { changingStorage = false; SetBusy(false); }
    }

    private async void Remove_Click(object sender, RoutedEventArgs e)
    {
        if (snapshot is null || !RemoveButton.IsEnabled) return;
        var reviewed = snapshot;
        bool removalVerified = false;
        string receipt = "";
        SetBusy(true, "Awaiting confirmation...", false);
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot,
                Title = $"Remove {reviewed.RemovableDrive}?",
                Content = "WARNING: this permanently deletes the Dev Drive. Back up data before proceeding.\n\n" +
                    $"This deletes the {Units.GiB(reviewed.RemovableSizeBytes)} GiB Dev space. " +
                    "It must still be empty when checked again. Close apps using the drive. " +
                    "Windows and EFI will not be removed.",
                PrimaryButtonText = "Remove permanently",
                CloseButtonText = "Cancel",
                DefaultButton = ContentDialogButton.Close
            };
            if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
            changingStorage = true;
            SetBusy(true, "Removing and verifying. Do not shut down.");
            var result = await service.RunAsync("Remove", reviewed.RemovalFingerprint);
            ApplyResult(result);
            removalVerified = true;
            receipt = result.LogPath;
            changingStorage = false;
            SetBusy(true, "Refreshing drives...");
            ApplyResult(await service.RunAsync("Inspect"));
            StatusBar.Severity = InfoBarSeverity.Success;
            StatusBar.Title = "Dev Drive removed";
            StatusBar.Message = snapshot?.CanCreate == true ?
                "Ready to create another Dev Drive." : "Open Help for guidance.";
            diagnostics += $"\nReceipt: {receipt}";
        }
        catch (Exception exception)
        {
            ShowError(exception.Message, !removalVerified);
            if (removalVerified)
            {
                StatusBar.Title = "Dev Drive removed; refresh failed";
                diagnostics += $"\nRemoval receipt: {receipt}";
            }
        }
        finally { changingStorage = false; SetBusy(false); }
    }
}
