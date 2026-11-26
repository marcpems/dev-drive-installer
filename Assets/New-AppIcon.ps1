param([string]$OutputPath = (Join-Path $PSScriptRoot 'AppIcon.ico'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class IconHandle {
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr handle);
}
'@
$bitmap = [Drawing.Bitmap]::new(256, 256)
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$background = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(0, 95, 184))
$white = [Drawing.SolidBrush]::new([Drawing.Color]::White)
$green = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(92, 230, 140))
$handle = [IntPtr]::Zero
try {
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::Transparent)
    $graphics.FillEllipse($background, 4, 4, 248, 248)
    foreach ($y in 72, 142) {
        $graphics.FillRectangle($white, 54, $y, 148, 42)
        $graphics.FillRectangle($background, 66, ($y + 12), 78, 18)
        $graphics.FillEllipse($green, 170, ($y + 12), 18, 18)
    }
    $handle = $bitmap.GetHicon()
    $icon = [Drawing.Icon]::FromHandle($handle)
    $stream = [IO.File]::Create($OutputPath)
    try { $icon.Save($stream) } finally { $stream.Dispose(); $icon.Dispose() }
}
finally {
    if ($handle -ne [IntPtr]::Zero) { [void][IconHandle]::DestroyIcon($handle) }
    $green.Dispose()
    $white.Dispose()
    $background.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
}
