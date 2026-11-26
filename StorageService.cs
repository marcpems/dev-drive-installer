using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;

namespace DevDriveInstaller;

public sealed class StorageService
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    public async Task<BackendResult> RunAsync(string mode, string fingerprint = "", long sizeGiB = 0)
    {
        var assembly = Assembly.GetExecutingAssembly();
        string script;
        string probe;
        using (var reader = new StreamReader(assembly.GetManifestResourceStream("StorageBackend")
            ?? throw new InvalidOperationException("Storage backend resource is missing.")))
            script = await reader.ReadToEndAsync();
        using (var reader = new StreamReader(assembly.GetManifestResourceStream("VolumeProbe")
            ?? throw new InvalidOperationException("Native volume probe resource is missing.")))
            probe = await reader.ReadToEndAsync();

        var request = Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(
            new { Mode = mode, Fingerprint = fingerprint, SizeGiB = sizeGiB })));
        var source = Convert.ToBase64String(Encoding.UTF8.GetBytes(probe));
        var command = $"& {{\n{script}\n}} -RequestBase64 '{request}' -ProbeBase64 '{source}'";
        var start = new ProcessStartInfo
        {
            FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                @"WindowsPowerShell\v1.0\powershell.exe"),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        foreach (var argument in new[] { "-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand",
            Convert.ToBase64String(Encoding.Unicode.GetBytes(
                "& ([scriptblock]::Create([Console]::In.ReadToEnd()))")) })
            start.ArgumentList.Add(argument);

        using var process = Process.Start(start) ?? throw new InvalidOperationException("Cannot start Windows PowerShell.");
        // Never time out or kill a process that may be formatting a newly created space.
        var stdout = process.StandardOutput.ReadToEndAsync();
        var stderr = process.StandardError.ReadToEndAsync();
        await process.StandardInput.WriteAsync(command);
        process.StandardInput.Close();
        await process.WaitForExitAsync();
        var output = await stdout;
        var errors = WithoutProgressRecords(await stderr);
        BackendResult result;
        try
        {
            result = JsonSerializer.Deserialize<BackendResult>(output, JsonOptions)
                ?? throw new JsonException("Empty storage response.");
        }
        catch (JsonException exception)
        {
            throw new InvalidOperationException(
                $"Storage backend returned an invalid response (exit {process.ExitCode}). " +
                $"Do not retry creation blindly.\n{errors}\n{output}", exception);
        }
        if (process.ExitCode != 0 || !string.IsNullOrWhiteSpace(errors))
            throw new InvalidOperationException(
                $"Storage backend failed (exit {process.ExitCode}). {result.Error}\n{errors}\nLog: {result.LogPath}");
        return result;
    }

    internal static string WithoutProgressRecords(string text)
    {
        if (!text.StartsWith("#< CLIXML", StringComparison.Ordinal)) return text;
        try
        {
            using var input = new StringReader(text[(text.IndexOf('\n') + 1)..]);
            using var reader = XmlReader.Create(input, new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit });
            var document = XDocument.Load(reader);
            var records = document.Root?.Elements().ToArray();
            return document.Root?.Name.LocalName == "Objs" && records is { Length: > 0 }
                && records.All(record => string.Equals((string?)record.Attribute("S"), "progress",
                    StringComparison.OrdinalIgnoreCase)) ? "" : text;
        }
        catch (XmlException)
        {
            return text;
        }
    }
}
