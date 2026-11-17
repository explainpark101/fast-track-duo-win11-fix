using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            var asm = Assembly.GetExecutingAssembly();
            var title = ((AssemblyTitleAttribute)Attribute.GetCustomAttribute(
                asm, typeof(AssemblyTitleAttribute)))?.Title
                ?? Path.GetFileNameWithoutExtension(asm.Location)
                ?? "FastTrackDuoPackage";

            Console.WriteLine(title);
            Console.WriteLine("Extracting payload...");

            var work = Path.Combine(
                Path.GetTempPath(),
                "FastTrackDuoFix",
                Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(work);

            using (var stream = OpenPayload(asm))
            using (var zip = new ZipArchive(stream, ZipArchiveMode.Read))
            {
                foreach (var zipEntry in zip.Entries)
                {
                    var dest = Path.Combine(work, zipEntry.FullName.Replace('/', Path.DirectorySeparatorChar));
                    var dir = Path.GetDirectoryName(dest);
                    if (!string.IsNullOrEmpty(dir))
                        Directory.CreateDirectory(dir);
                    if (string.IsNullOrEmpty(zipEntry.Name))
                        continue; // directory entry
                    zipEntry.ExtractToFile(dest, true);
                }
            }

            var scriptPath = FindEntryScript(work);
            if (scriptPath == null)
            {
                Console.Error.WriteLine("No Install-*.ps1 found in payload.");
                return 2;
            }

            Console.WriteLine("Running " + Path.GetFileName(scriptPath) + " ...");
            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + scriptPath + "\"",
                UseShellExecute = false,
                WorkingDirectory = Path.GetDirectoryName(scriptPath),
            };

            using (var proc = Process.Start(psi))
            {
                if (proc == null)
                    throw new InvalidOperationException("Failed to start PowerShell.");
                proc.WaitForExit();
                Console.WriteLine();
                Console.WriteLine("Exit code: " + proc.ExitCode);
                Console.WriteLine("Press Enter to close...");
                try { Console.ReadLine(); } catch { }
                return proc.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.ToString());
            Console.WriteLine("Press Enter to close...");
            try { Console.ReadLine(); } catch { }
            return 1;
        }
    }

    private static Stream OpenPayload(Assembly asm)
    {
        foreach (var res in asm.GetManifestResourceNames())
        {
            if (res.EndsWith("payload.zip", StringComparison.OrdinalIgnoreCase))
            {
                var s = asm.GetManifestResourceStream(res);
                if (s == null)
                    throw new InvalidOperationException("Empty resource: " + res);
                return s;
            }
        }

        throw new InvalidOperationException(
            "Embedded payload.zip missing. Rebuild with packaging/build.ps1.");
    }

    private static string FindEntryScript(string root)
    {
        var preferred = new[]
        {
            Path.Combine(root, "Install-Driver.ps1"),
            Path.Combine(root, "Install-Patch.ps1"),
        };
        foreach (var p in preferred)
        {
            if (File.Exists(p)) return p;
        }

        return Directory.EnumerateFiles(root, "Install-*.ps1", SearchOption.AllDirectories)
            .OrderBy(f => f.Length)
            .FirstOrDefault();
    }
}
