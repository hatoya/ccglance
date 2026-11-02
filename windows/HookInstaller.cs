// Runs the bundled Node hooks: install.js on launch (and when a new
// claude-desktop-switcher profile appears) and ccglance-hook.js --fetch-pr
// for PR status. Mirrors findNode / runInstaller / refreshPRStatuses in
// main.swift.
using System.Diagnostics;
using System.IO;

namespace CcGlance;

internal static class HookInstaller
{
    private static readonly Lazy<string?> NodePath = new(FindNode);
    private static readonly Dictionary<string, double> PrFetchAttempts = new();
    private static DateTime? _profilesStamp;
    private static int _installerInFlight;

    public static string HooksDir => Path.Combine(App.ExeDir, "hooks");
    public static string HookScript => Path.Combine(HooksDir, "ccglance-hook.js");
    public static bool HasNode => NodePath.Value != null;

    private static string CswProfilesDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".context-switcher-claude", "profiles");

    public static bool RunInstaller()
    {
        var installer = Path.Combine(HooksDir, "install.js");
        if (!File.Exists(installer)) return false;
        if (NodePath.Value is not string node)
        {
            App.Log("node not found; run hooks\\install.js manually");
            return false;
        }
        // Launch and the CSW catch-up can overlap; one writer on settings.json
        if (Interlocked.Exchange(ref _installerInFlight, 1) == 1) return false;
        try
        {
            var psi = Start(node, installer);
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            using var proc = Process.Start(psi);
            if (proc == null) return false;
            // Drain both pipes or a chatty installer deadlocks on a full buffer
            var stdout = proc.StandardOutput.ReadToEndAsync();
            var stderr = proc.StandardError.ReadToEndAsync();
            if (!proc.WaitForExit(30000))
            {
                proc.Kill();
                return false;
            }
            Task.WaitAll(stdout, stderr);
            if (proc.ExitCode != 0) App.Log($"install.js exited {proc.ExitCode}: {stderr.Result}");
            return proc.ExitCode == 0;
        }
        catch (Exception ex)
        {
            App.Log(ex);
            return false;
        }
        finally
        {
            Interlocked.Exchange(ref _installerInFlight, 0);
        }
    }

    // Re-run the installer when a claude-desktop-switcher profile appears or
    // disappears, so sessions from new environments show up without a restart
    public static void CatchUpNewEnvironments()
    {
        DateTime? stamp = null;
        try
        {
            if (Directory.Exists(CswProfilesDir)) stamp = Directory.GetLastWriteTimeUtc(CswProfilesDir);
        }
        catch
        {
        }
        if (_profilesStamp == null)
        {
            _profilesStamp = stamp ?? DateTime.MinValue;
            return;
        }
        if (stamp == _profilesStamp) return;
        _profilesStamp = stamp ?? DateTime.MinValue;
        Task.Run(RunInstaller);
    }

    // Poll PR status for idle sessions with a live PR: 12s while the session
    // saw a hook event in the last 30min, 55s after; force ignores the throttle
    public static void RefreshPrStatuses(IReadOnlyList<SessionState> sessions, bool force)
    {
        if (NodePath.Value is not string node || !File.Exists(HookScript)) return;
        var now = SessionStore.Now;
        var live = sessions.Select(s => s.SessionId).ToHashSet();
        foreach (var key in PrFetchAttempts.Keys.Where(k => !live.Contains(k)).ToList())
            PrFetchAttempts.Remove(key);
        foreach (var s in sessions)
        {
            if (s.IsActive || s.Cwd == null) continue;
            if (!force)
            {
                if (s.Pr is not PRInfo pr || pr.State == "MERGED") continue;
                if (pr.Url != null && s.PrDismissed?.Contains(pr.Url) == true) continue;
                var throttle = now - s.UpdatedAt < 1800 ? 12 : 55;
                // Throttle on the last attempt too: a failing gh never advances checkedAt
                var last = Math.Max(pr.CheckedAt ?? 0, PrFetchAttempts.GetValueOrDefault(s.SessionId));
                if (now - last < throttle) continue;
            }
            PrFetchAttempts[s.SessionId] = now;
            try
            {
                using var _ = Process.Start(Start(node, HookScript, "--fetch-pr", s.SessionId, s.Cwd));
            }
            catch (Exception ex)
            {
                App.Log(ex);
            }
        }
    }

    private static ProcessStartInfo Start(string node, params string[] args)
    {
        var psi = new ProcessStartInfo(node)
        {
            UseShellExecute = false,
            CreateNoWindow = true, // no console flash
            WorkingDirectory = App.ExeDir,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        return psi;
    }

    // PATH first, then the usual installers (MSI, nvm-windows, scoop, volta)
    private static string? FindNode()
    {
        var candidates = new List<string>();
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
            candidates.Add(Path.Combine(dir.Trim('"'), "node.exe"));

        void Add(string? root, params string[] parts)
        {
            if (!string.IsNullOrEmpty(root)) candidates.Add(Path.Combine([root, .. parts]));
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        Add(Environment.GetEnvironmentVariable("ProgramFiles"), "nodejs", "node.exe");
        Add(Environment.GetEnvironmentVariable("ProgramFiles(x86)"), "nodejs", "node.exe");
        Add(Environment.GetEnvironmentVariable("NVM_SYMLINK"), "node.exe");
        Add(home, "scoop", "apps", "nodejs", "current", "node.exe");
        Add(home, "scoop", "apps", "nodejs-lts", "current", "node.exe");
        Add(Environment.GetEnvironmentVariable("LOCALAPPDATA"), "Volta", "bin", "node.exe");
        Add(Environment.GetEnvironmentVariable("LOCALAPPDATA"), "Programs", "nodejs", "node.exe");
        try
        {
            var nvm = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "nvm");
            if (Directory.Exists(nvm))
            {
                // Newest version first (numeric, so v20 beats v9)
                static Version Parse(string dir) =>
                    Version.TryParse(Path.GetFileName(dir).TrimStart('v'), out var v) ? v : new Version(0, 0);
                foreach (var v in Directory.GetDirectories(nvm, "v*").OrderByDescending(Parse))
                    candidates.Add(Path.Combine(v, "node.exe"));
            }
        }
        catch
        {
        }
        foreach (var c in candidates)
        {
            try
            {
                if (File.Exists(c)) return c;
            }
            catch
            {
            }
        }
        return null;
    }
}
