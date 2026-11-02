// Auto-update from GitHub Releases — Sources/UpdateChecker.swift for Windows.
// Downloads ccglance_windows.zip, verifies it against the .sha256 asset,
// renames the running exe aside, copies the new files in and relaunches.
// There is no code-signature check on Windows (no Authenticode); SHA-256
// against the release's own checksum is the integrity guarantee.
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;

namespace CcGlance;

internal sealed class UpdateChecker
{
    public const string Repo = "hatoya/ccglance";
    public const string ZipAssetName = "ccglance_windows.zip";
    public const string UpdateTempPrefix = "ccglance-update-";
    private const double CheckInterval = 24 * 3600;

    public enum Phase
    {
        Idle,
        Downloading,
        Installing,
        Failed,
    }

    public sealed record Release(string Version, Uri PageUrl, Uri? ZipUrl, Uri? ShaUrl);

    private static readonly HttpClient Http = CreateClient();

    public Release? Available { get; private set; }
    public Phase CurrentPhase { get; private set; } = Phase.Idle;
    public string? FailureMessage { get; private set; }

    public event Action<Release>? UpdateAvailable;
    public event Action? PhaseChanged;

    public static string CurrentVersion => App.Version;

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        // GitHub answers 403 to requests without a User-Agent
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"ccglance/{App.Version}");
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        return client;
    }

    // First check 5s after launch unless one ran in the last 24h, then daily
    public void Start()
    {
        Task.Run(async () =>
        {
            var last = Settings.Current.LastUpdateCheck ?? 0;
            var wait = SessionStore.Now - last >= CheckInterval ? 5 : Math.Max(5, CheckInterval - (SessionStore.Now - last));
            await Task.Delay(TimeSpan.FromSeconds(wait));
            while (true)
            {
                try
                {
                    await CheckAsync();
                }
                catch (Exception ex)
                {
                    App.Log(ex);
                }
                await Task.Delay(TimeSpan.FromSeconds(CheckInterval));
            }
        });
    }

    // Returns the newer release, or null when up to date / unreachable
    public async Task<Release?> CheckAsync()
    {
        Release? found = null;
        try
        {
            using var response = await Http.GetAsync($"https://api.github.com/repos/{Repo}/releases/latest");
            if ((int)response.StatusCode != 200) return null;
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStreamAsync());
            var root = doc.RootElement;
            var tag = root.GetProperty("tag_name").GetString() ?? "";
            var version = tag.StartsWith('v') ? tag[1..] : tag;
            var page = new Uri(root.GetProperty("html_url").GetString()!);
            Uri? zip = null, sha = null;
            if (root.TryGetProperty("assets", out var assets))
            {
                foreach (var asset in assets.EnumerateArray())
                {
                    var name = asset.GetProperty("name").GetString();
                    var url = asset.GetProperty("browser_download_url").GetString();
                    if (name == null || url == null || !Uri.TryCreate(url, UriKind.Absolute, out var uri) || !IsTrustedAssetUrl(uri))
                        continue;
                    if (name == ZipAssetName) zip = uri;
                    else if (name == ZipAssetName + ".sha256") sha = uri;
                }
            }
            if (IsNewer(version, CurrentVersion)) found = new Release(version, page, zip, sha);
        }
        finally
        {
            Settings.Current.LastUpdateCheck = SessionStore.Now;
            Settings.Save();
        }
        if (found != null && found.Version != Available?.Version)
        {
            Available = found;
            var release = found;
            OnUi(() => UpdateAvailable?.Invoke(release));
        }
        return found;
    }

    private static bool IsTrustedAssetUrl(Uri url)
    {
        if (url.Scheme != "https") return false;
        var host = url.Host;
        return host == "github.com" || host == "githubusercontent.com" || host.EndsWith(".githubusercontent.com", StringComparison.Ordinal);
    }

    private static bool IsNewer(string a, string b)
    {
        static int[] Parts(string v) => v.Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        var pa = Parts(a);
        var pb = Parts(b);
        for (var i = 0; i < Math.Max(pa.Length, pb.Length); i++)
        {
            var x = i < pa.Length ? pa[i] : 0;
            var y = i < pb.Length ? pb[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }

    // interactive: user clicked — failures also open the release page
    public void InstallAvailable(bool interactive)
    {
        if (Available is not Release release || CurrentPhase != Phase.Idle) return;
        if (release.ZipUrl == null || release.ShaUrl == null)
        {
            if (interactive) OpenPage(release);
            return;
        }
        _ = InstallAsync(release, interactive);
    }

    private async Task InstallAsync(Release release, bool interactive)
    {
        SetPhase(Phase.Downloading);
        var workDir = Path.Combine(Path.GetTempPath(), UpdateTempPrefix + Guid.NewGuid().ToString("N"));
        try
        {
            await InstallCore(release, interactive, workDir);
        }
        catch (Exception ex)
        {
            // Anything the specific handlers below missed must not strand the phase
            Fail("Could not install the update", release, interactive, ex);
        }
        finally
        {
            // Files were copied, not moved, so nothing here is needed after Swap
            try
            {
                Directory.Delete(workDir, recursive: true);
            }
            catch
            {
            }
        }
    }

    private async Task InstallCore(Release release, bool interactive, string workDir)
    {
        Directory.CreateDirectory(workDir);
        var zipPath = Path.Combine(workDir, "update.zip");
        try
        {
            // HttpClient.Timeout covers only the headers; bound the body too
            using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(5));
            using var response = await Http.GetAsync(release.ZipUrl!, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            if ((int)response.StatusCode != 200) throw new IOException("status " + (int)response.StatusCode);
            await using var file = File.Create(zipPath);
            await response.Content.CopyToAsync(file, cts.Token);
        }
        catch (Exception ex)
        {
            Fail("Download failed", release, interactive, ex);
            return;
        }

        string expected;
        try
        {
            var shaText = await Http.GetStringAsync(release.ShaUrl!);
            if (shaText.Length >= 4096) throw new IOException("checksum body too large");
            expected = shaText.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.ToLowerInvariant() ?? "";
            if (expected.Length != 64 || !expected.All(Uri.IsHexDigit)) throw new IOException("malformed checksum");
        }
        catch (Exception ex)
        {
            Fail("Update failed checksum verification", release, interactive, ex);
            return;
        }
        string actual;
        await using (var stream = File.OpenRead(zipPath))
            actual = Convert.ToHexString(await SHA256.HashDataAsync(stream)).ToLowerInvariant();
        if (actual != expected)
        {
            Fail("Update failed checksum verification", release, interactive, null);
            return;
        }

        SetPhase(Phase.Installing);
        var extractDir = Path.Combine(workDir, "extract");
        // Off the UI thread: unpacking and copying ~150MB would freeze the panel
        try
        {
            await Task.Run(() => ZipFile.ExtractToDirectory(zipPath, extractDir));
        }
        catch (Exception ex)
        {
            Fail("Could not unpack the update", release, interactive, ex);
            return;
        }
        var newExe = FindExe(extractDir);
        if (newExe == null)
        {
            Fail("Update package looks broken", release, interactive, null);
            return;
        }

        try
        {
            await Task.Run(() => Swap(Path.GetDirectoryName(newExe)!));
        }
        catch (UnauthorizedAccessException ex)
        {
            Fail("No permission to replace the app", release, interactive, ex);
            return;
        }
        catch (Exception ex)
        {
            Fail("Could not install the update", release, interactive, ex);
            return;
        }

        Relaunch();
    }

    private static string? FindExe(string dir)
    {
        var top = Path.Combine(dir, "ccglance.exe");
        if (File.Exists(top)) return top;
        foreach (var sub in Directory.GetDirectories(dir))
        {
            var nested = Path.Combine(sub, "ccglance.exe");
            if (File.Exists(nested)) return nested;
        }
        return null;
    }

    // Renaming a running image is allowed on Windows; overwriting it is not
    private static void Swap(string newDir)
    {
        var exeDir = App.ExeDir.TrimEnd(Path.DirectorySeparatorChar);
        var current = App.ExePath;
        var old = current + ".old";
        try
        {
            if (File.Exists(old)) File.Delete(old);
        }
        catch
        {
            old = $"{current}.old-{DateTime.UtcNow.Ticks}";
        }
        File.Move(current, old);
        try
        {
            foreach (var src in Directory.EnumerateFiles(newDir, "*", SearchOption.AllDirectories))
            {
                var rel = Path.GetRelativePath(newDir, src);
                var dest = Path.Combine(exeDir, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                File.Copy(src, dest, overwrite: true);
            }
        }
        catch
        {
            // Roll back so the app still starts next time
            try
            {
                if (File.Exists(current)) File.Delete(current);
                File.Move(old, current);
            }
            catch
            {
            }
            throw;
        }
    }

    private static void Relaunch()
    {
        OnUi(() =>
        {
            (Application.Current as App)?.ReleaseInstance();
            try
            {
                Process.Start(new ProcessStartInfo(App.ExePath) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                App.Log(ex);
            }
            Application.Current.Shutdown();
        });
    }

    private void Fail(string message, Release release, bool interactive, Exception? ex)
    {
        if (ex != null) App.Log($"update: {message}: {ex}");
        FailureMessage = interactive ? message + " — opening release page" : message;
        SetPhase(Phase.Failed);
        if (interactive) OpenPage(release);
        Task.Run(async () =>
        {
            await Task.Delay(5000);
            FailureMessage = null;
            SetPhase(Phase.Idle);
        });
    }

    private static void OpenPage(Release release)
    {
        if (release.PageUrl.Scheme != "https") return;
        try
        {
            Process.Start(new ProcessStartInfo(release.PageUrl.ToString()) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            App.Log(ex);
        }
    }

    private void SetPhase(Phase phase)
    {
        CurrentPhase = phase;
        OnUi(() => PhaseChanged?.Invoke());
    }

    private static void OnUi(Action action)
    {
        var dispatcher = Application.Current?.Dispatcher;
        if (dispatcher == null || dispatcher.CheckAccess()) action();
        else dispatcher.BeginInvoke(action);
    }
}
