// Claude Desktop side channel — the title edited in the Desktop app and the
// PR chips dismissed there live in its own store, not in the transcript:
//   %APPDATA%\Claude\claude-code-sessions\<ws>\<x>\local_<id>.json
//   { "title", "cliSessionId", "bridgeSessionIds": [...], "prs": [{ "url", "dismissed" }] }
// Port of StateStore's desktop* functions and DesktopStoreWatcher in
// main.swift; FileSystemWatcher stands in for FSEvents.
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;

namespace CcGlance;

internal static class DesktopStore
{
    private sealed class Info
    {
        public string? Title;
        public List<string>? DismissedPrs;
    }

    private const int DismissedPrLimit = 32;
    // Store walks are serialized: launch sweep, watcher, untitled poll and the
    // menu can all fire at once, and each walk reads every store file
    private static readonly SemaphoreSlim Gate = new(1, 1);

    private static string ProfilesDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".context-switcher-claude", "profiles");

    // The default store plus one per claude-desktop-switcher profile. Mirrors
    // desktopStoreRoots() in ccglance-hook.js; only existing roots are returned
    public static List<string> Roots()
    {
        var roots = new List<string>();
        void Add(string root)
        {
            if (Directory.Exists(root) &&
                !roots.Any(r => string.Equals(Path.GetFullPath(r), Path.GetFullPath(root), StringComparison.OrdinalIgnoreCase)))
                roots.Add(root);
        }
        Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude", "claude-code-sessions"));

        string[] profiles;
        try
        {
            profiles = Directory.GetDirectories(ProfilesDir);
        }
        catch
        {
            return roots;
        }
        foreach (var profile in profiles.OrderBy(p => p, StringComparer.Ordinal))
        {
            string? dataDir = null;
            var value = ProfileDataDir(Path.Combine(profile, "profile.toml"));
            if (value != null)
            {
                var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
                if (value.Length > 1 && value[0] == '~' && (value[1] == '/' || value[1] == '\\'))
                    value = Path.Combine(home, value[2..]);
                if (!Path.IsPathRooted(value)) value = Path.Combine(profile, value);
                if (Directory.Exists(value)) dataDir = value;
            }
            if (dataDir == null)
            {
                var fallback = Path.Combine(profile, "desktop-data");
                if (Directory.Exists(fallback)) dataDir = fallback;
            }
            if (dataDir != null) Add(Path.Combine(dataDir, "claude-code-sessions"));
        }
        return roots;
    }

    // First well-formed `desktop_user_data_dir = "…"` (or '…') line
    private static string? ProfileDataDir(string tomlPath)
    {
        string[] lines;
        try
        {
            lines = File.ReadAllLines(tomlPath);
        }
        catch
        {
            return null;
        }
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (!line.StartsWith("desktop_user_data_dir", StringComparison.Ordinal)) continue;
            var rest = line["desktop_user_data_dir".Length..].TrimStart(' ', '\t');
            if (rest.Length == 0 || rest[0] != '=') continue;
            rest = rest[1..].TrimStart(' ', '\t');
            if (rest.Length < 2) continue;
            var quote = rest[0];
            if (quote != '"' && quote != '\'') continue;
            var end = rest.IndexOf(quote, 1);
            if (end <= 1) continue;
            var value = rest[1..end];
            if (quote == '"') value = value.Replace("\\\\", "\\").Replace("\\\"", "\"");
            return value.Length > 0 ? value : null;
        }
        return null;
    }

    private static (List<string> ids, Info info)? ParseStoreFile(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var doc = JsonDocument.Parse(stream);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            var ids = new List<string>();
            foreach (var key in new[] { "cliSessionId", "sessionId", "id" })
                if (root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String) ids.Add(v.GetString()!);
            if (root.TryGetProperty("bridgeSessionIds", out var bridged) && bridged.ValueKind == JsonValueKind.Array)
                foreach (var b in bridged.EnumerateArray())
                    if (b.ValueKind == JsonValueKind.String) ids.Add(b.GetString()!);
            if (ids.Count == 0) return null;

            var info = new Info();
            if (root.TryGetProperty("title", out var t) && t.ValueKind == JsonValueKind.String)
            {
                var title = t.GetString()!.Trim();
                if (title.Length > 0) info.Title = title;
            }
            // Read only when present so an older store never blanks dismissals
            // resolved from another file. Keyed by url: it is what both the
            // store entry and gh's output always carry
            if (root.TryGetProperty("prs", out var prs) && prs.ValueKind == JsonValueKind.Array)
            {
                var urls = new List<string>();
                foreach (var pr in prs.EnumerateArray())
                {
                    if (pr.ValueKind != JsonValueKind.Object) continue;
                    if (!pr.TryGetProperty("dismissed", out var d) || d.ValueKind != JsonValueKind.True) continue;
                    if (pr.TryGetProperty("url", out var u) && u.ValueKind == JsonValueKind.String && !urls.Contains(u.GetString()!))
                        urls.Add(u.GetString()!);
                }
                info.DismissedPrs = urls.TakeLast(DismissedPrLimit).OrderBy(x => x, StringComparer.Ordinal).ToList();
            }
            return (ids, info);
        }
        catch
        {
            return null;
        }
    }

    // Title and dismissals resolve independently: each takes the newest file
    // that carries it, so a fresher file missing one half never blanks the other
    private static Dictionary<string, Info> InfoFor(HashSet<string> sessionIds)
    {
        var titles = new Dictionary<string, (string value, DateTime mtime)>();
        var dismissed = new Dictionary<string, (List<string> value, DateTime mtime)>();
        foreach (var root in Roots())
        {
            IEnumerable<string> files;
            try
            {
                files = Directory.EnumerateFiles(root, "*.json", SearchOption.AllDirectories);
            }
            catch
            {
                continue;
            }
            foreach (var file in files)
            {
                if (ParseStoreFile(file) is not var (ids, info)) continue;
                DateTime mtime;
                try
                {
                    mtime = File.GetLastWriteTimeUtc(file);
                }
                catch
                {
                    mtime = DateTime.MinValue;
                }
                foreach (var id in ids)
                {
                    if (!sessionIds.Contains(id)) continue;
                    if (info.Title != null && (!titles.TryGetValue(id, out var ct) || mtime > ct.mtime))
                        titles[id] = (info.Title, mtime);
                    if (info.DismissedPrs != null && (!dismissed.TryGetValue(id, out var cd) || mtime > cd.mtime))
                        dismissed[id] = (info.DismissedPrs, mtime);
                }
            }
        }
        var result = new Dictionary<string, Info>();
        foreach (var (id, e) in titles) (result[id] = result.GetValueOrDefault(id) ?? new Info()).Title = e.value;
        foreach (var (id, e) in dismissed) (result[id] = result.GetValueOrDefault(id) ?? new Info()).DismissedPrs = e.value;
        return result;
    }

    // Off-UI entry point for every caller; completion runs on the UI thread
    public static void EnqueueRefresh(HashSet<string>? only = null, Action? completion = null)
    {
        Task.Run(async () =>
        {
            await Gate.WaitAsync();
            try
            {
                Refresh(only);
            }
            catch (Exception ex)
            {
                App.Log(ex);
            }
            finally
            {
                Gate.Release();
            }
            if (completion != null) Application.Current?.Dispatcher.BeginInvoke(completion);
        });
    }

    // Catch-up for renames and dismissals made while the app was down, scoped
    // to sessions that can change on screen; delayed past the watcher's first
    // callback for the same files
    public static void SweepAtLaunch()
    {
        Task.Run(async () =>
        {
            await Task.Delay(3000);
            var targets = SessionStore.Load()
                .Where(s => s.Pr != null || string.IsNullOrEmpty(s.Title))
                .Select(s => s.SessionId)
                .ToHashSet();
            if (targets.Count > 0) EnqueueRefresh(targets);
        });
    }

    private static void Refresh(HashSet<string>? only)
    {
        string[] files;
        try
        {
            files = Directory.GetFiles(SessionStore.SessionsDir, "*.json");
        }
        catch
        {
            return;
        }
        var targets = files.Select(Path.GetFileNameWithoutExtension).OfType<string>().ToHashSet();
        if (only != null) targets.IntersectWith(only);
        if (targets.Count == 0) return;
        Persist(InfoFor(targets));
    }

    // Changed store files → the sessions they name → store-wide newest rule,
    // so a touched stale file never wins over a fresher one
    public static void ApplyFromStoreFiles(IEnumerable<string> paths)
    {
        var ids = new HashSet<string>();
        foreach (var p in paths)
            if (ParseStoreFile(p) is var (fileIds, _)) ids.UnionWith(fileIds);
        if (ids.Count > 0) EnqueueRefresh(ids);
    }

    // Patch the raw JSON: the hooks own fields this app doesn't model, and a
    // round-trip through SessionState would drop them
    private static void Persist(Dictionary<string, Info> info)
    {
        if (info.Count == 0) return;
        foreach (var (id, found) in info)
        {
            var file = SessionStore.FileFor(id);
            var obj = ReadObject(file);
            if (obj == null) continue;
            var changed = false;
            if (found.Title != null && !(obj["title"] is JsonValue tv && tv.TryGetValue<string>(out var cur) && cur == found.Title))
            {
                obj["title"] = found.Title;
                changed = true;
            }
            // The store is authoritative: an emptied list clears the field
            if (found.DismissedPrs is List<string> dismissed)
            {
                var current = ReadStrings(obj["prDismissed"]);
                if (dismissed.Count == 0)
                {
                    if (current != null)
                    {
                        obj.Remove("prDismissed");
                        changed = true;
                    }
                }
                else if (current == null || !current.SequenceEqual(dismissed))
                {
                    obj["prDismissed"] = ToArray(dismissed);
                    changed = true;
                }
            }
            if (!changed) continue;
            WriteObject(file, obj);
            // A hook's read-modify-write can land between our read and write. A
            // lost title heals at the next turn boundary; a lost dismissal never
            // does (the hook doesn't read the store's PR list), so verify once
            if (found.DismissedPrs is not { Count: > 0 } want) continue;
            var reread = ReadObject(file);
            if (reread == null) continue;
            if (ReadStrings(reread["prDismissed"]) is List<string> got && got.SequenceEqual(want)) continue;
            reread["prDismissed"] = ToArray(want);
            WriteObject(file, reread);
        }
    }

    private static JsonObject? ReadObject(string file)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return JsonNode.Parse(stream) as JsonObject;
        }
        catch
        {
            return null;
        }
    }

    private static readonly JsonSerializerOptions WriteOptions = new()
    {
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    // tmp + rename like the hook; a hook process holding the target makes the
    // rename fail transiently, so retry briefly and never leave the tmp behind
    private static void WriteObject(string file, JsonObject obj)
    {
        var tmp = $"{file}.{Environment.ProcessId}.tmp";
        try
        {
            File.WriteAllText(tmp, obj.ToJsonString(WriteOptions));
            for (var attempt = 0; ; attempt++)
            {
                try
                {
                    File.Move(tmp, file, overwrite: true);
                    return;
                }
                catch (IOException) when (attempt < 4)
                {
                    Thread.Sleep(20);
                }
            }
        }
        catch (Exception ex)
        {
            App.Log(ex);
            try
            {
                File.Delete(tmp);
            }
            catch
            {
            }
        }
    }

    private static List<string>? ReadStrings(JsonNode? node)
    {
        if (node is not JsonArray arr) return null;
        var list = new List<string>();
        foreach (var item in arr)
            if (item is JsonValue v && v.TryGetValue<string>(out var s)) list.Add(s);
        return list;
    }

    private static JsonArray ToArray(IEnumerable<string> values) =>
        new(values.Select(v => (JsonNode)JsonValue.Create(v)).ToArray());
}

// Watches every store root so renames and dismissals land on the panel
// without waiting for the next turn boundary. Event-driven; the untitled poll
// in the window remains the fallback for dropped events.
internal sealed class DesktopWatcher
{
    private readonly List<FileSystemWatcher> _watchers = new();
    private List<string> _roots = new();
    private readonly HashSet<string> _pending = new(StringComparer.OrdinalIgnoreCase);
    private readonly Timer _debounce;
    private readonly object _lock = new();

    public DesktopWatcher()
    {
        _debounce = new Timer(_ => Flush(), null, Timeout.Infinite, Timeout.Infinite);
    }

    // Idempotent while the root set is unchanged; true when (re)subscribed, in
    // which case the caller should follow up with a full refresh
    public bool Start()
    {
        var roots = DesktopStore.Roots();
        if (_watchers.Count > 0 && roots.SequenceEqual(_roots, StringComparer.OrdinalIgnoreCase)) return false;
        Stop();
        _roots = roots;
        foreach (var root in roots)
        {
            try
            {
                var w = new FileSystemWatcher(root, "*.json")
                {
                    IncludeSubdirectories = true,
                    NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size,
                    InternalBufferSize = 64 * 1024,
                };
                w.Changed += OnChanged;
                w.Created += OnChanged;
                w.Renamed += OnChanged;
                w.Error += (_, _) => DesktopStore.EnqueueRefresh(); // buffer overflow: full walk
                w.EnableRaisingEvents = true;
                _watchers.Add(w);
            }
            catch (Exception ex)
            {
                App.Log(ex);
            }
        }
        return true;
    }

    public void Stop()
    {
        foreach (var w in _watchers)
        {
            try
            {
                w.EnableRaisingEvents = false;
                w.Dispose();
            }
            catch
            {
            }
        }
        _watchers.Clear();
    }

    private void OnChanged(object sender, FileSystemEventArgs e)
    {
        lock (_lock)
        {
            _pending.Add(e.FullPath);
            // 500ms coalesces edit bursts into one walk
            _debounce.Change(500, Timeout.Infinite);
        }
    }

    private void Flush()
    {
        List<string> paths;
        lock (_lock)
        {
            paths = _pending.ToList();
            _pending.Clear();
        }
        if (paths.Count > 0) DesktopStore.ApplyFromStoreFiles(paths);
    }
}
