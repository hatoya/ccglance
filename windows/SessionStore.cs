// Reads ~/.claude/ccglance/sessions/*.json — StateStore.load() in main.swift.
using System.IO;
using System.Text.Json;

namespace CcGlance;

internal static class SessionStore
{
    public static readonly string SessionsDir = Path.Combine(App.ClaudeDir, "ccglance", "sessions");

    private const double StaleSeconds = 12 * 3600; // crashed sessions never get SessionEnd
    private const double ResidueSeconds = 3600; // .lock / .tmp left by a killed hook

    public static double Now => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    public static string FileFor(string sessionId) => Path.Combine(SessionsDir, sessionId + ".json");

    public static List<SessionState> Load()
    {
        var sessions = new List<SessionState>();
        string[] files;
        try
        {
            files = Directory.GetFiles(SessionsDir);
        }
        catch
        {
            return sessions;
        }
        var now = Now;
        foreach (var file in files)
        {
            if (!file.EndsWith(".json", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    if ((DateTime.UtcNow - File.GetLastWriteTimeUtc(file)).TotalSeconds > ResidueSeconds)
                        File.Delete(file);
                }
                catch
                {
                }
                continue;
            }
            var session = Read(file);
            if (session == null) continue; // mid-write or foreign file: skip, never delete
            if (now - session.UpdatedAt > StaleSeconds)
            {
                TryDelete(file);
                continue;
            }
            sessions.Add(session);
        }
        // Active first, then by project; OrderBy is stable like Swift's sort
        return sessions
            .OrderBy(s => s.IsActive ? 0 : 1)
            .ThenBy(s => s.Project ?? "", StringComparer.Ordinal)
            .ToList();
    }

    // FileShare.Delete matters: the hook replaces the file by renaming a tmp
    // over it, which Windows refuses while a reader holds the target without it
    public static SessionState? Read(string file)
    {
        try
        {
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            return JsonSerializer.Deserialize(stream, JsonContext.Default.SessionState);
        }
        catch
        {
            return null;
        }
    }

    public static void ClearIdle()
    {
        string[] files;
        try
        {
            files = Directory.GetFiles(SessionsDir, "*.json");
        }
        catch
        {
            return;
        }
        foreach (var file in files)
        {
            var session = Read(file);
            if (session != null && !session.IsActive) TryDelete(file);
        }
    }

    private static void TryDelete(string file)
    {
        try
        {
            File.Delete(file);
        }
        catch
        {
        }
    }
}
