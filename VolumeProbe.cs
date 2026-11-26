using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace DevDriveInstaller.Native
{
    public static class VolumeProbe
    {
        private const uint QueryPersistentVolumeState = 0x0009023C;
        private const uint DevVolume = 0x00002000;

        [StructLayout(LayoutKind.Sequential)]
        private struct VolumeState
        {
            public uint Flags;
            public uint Mask;
            public uint Version;
            public uint Reserved;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeviceIoControl(
            SafeFileHandle handle, uint control, ref VolumeState input, uint inputSize,
            out VolumeState output, uint outputSize, out uint returned, IntPtr overlapped);

        public static SafeFileHandle LockDirectory(string path, bool allowWrites = false)
        {
            // Directory-list access makes replacement participate in share checks.
            SafeFileHandle handle = CreateFile(path, 0x00020081, allowWrites ? 3u : 1u,
                IntPtr.Zero, 3, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "Cannot lock receipt directory " + path + " (Win32 " + error + ").");
            }
            return handle;
        }

        public static bool IsDevDrive(string volumePath)
        {
            const string prefix = @"\\?\Volume{";
            const string suffix = @"}\";
            Guid volumeId;
            if (volumePath == null ||
                volumePath.Length != prefix.Length + 36 + suffix.Length ||
                !volumePath.StartsWith(prefix, StringComparison.Ordinal) ||
                !volumePath.EndsWith(suffix, StringComparison.Ordinal) ||
                !Guid.TryParseExact(volumePath.Substring(prefix.Length, 36), "D", out volumeId))
                throw new ArgumentException("An exact volume GUID path is required.");

            using (SafeFileHandle handle = CreateFile(volumePath.TrimEnd('\\'), 0x80000000, 7,
                IntPtr.Zero, 3, 0, IntPtr.Zero))
            {
                if (handle.IsInvalid)
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new Win32Exception(error, "Cannot inspect ReFS volume " + volumePath + " (Win32 " + error + ").");
                }
                VolumeState input = new VolumeState { Mask = DevVolume, Version = 1 };
                VolumeState output;
                uint returned;
                if (!DeviceIoControl(handle, QueryPersistentVolumeState, ref input, 16, out output, 16,
                    out returned, IntPtr.Zero))
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new Win32Exception(error, "Cannot query Dev Drive flag on " + volumePath + " (Win32 " + error + ").");
                }
                // Version belongs to the request; ReFS leaves it zero in the response.
                if (returned < 16)
                    throw new InvalidOperationException("Unrecognized Dev Drive flag response on " + volumePath +
                        " (bytes " + returned + ", version " + output.Version + ").");
                return (output.Flags & DevVolume) != 0;
            }
        }
    }
}
