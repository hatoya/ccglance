// %APPDATA%\ccglance\settings.json — the UserDefaults keys of the macOS app.
// Hide flags are stored as "hide" so a missing key shows everything.
using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace CcGlance;

public sealed class Settings
{
    [JsonPropertyName("panelLeft")] public double? PanelLeft { get; set; }
    [JsonPropertyName("panelTop")] public double? PanelTop { get; set; }
    [JsonPropertyName("panelWidth")] public double? PanelWidth { get; set; }
    [JsonPropertyName("hideModeBadge")] public bool HideModeBadge { get; set; }
    [JsonPropertyName("hidePlanBadge")] public bool HidePlanBadge { get; set; }
    [JsonPropertyName("hideElapsedTime")] public bool HideElapsedTime { get; set; }
    [JsonPropertyName("hideBackgroundTasks")] public bool HideBackgroundTasks { get; set; }
    [JsonPropertyName("lastUpdateCheck")] public double? LastUpdateCheck { get; set; }

    public static Settings Current { get; private set; } = new();

    private static string FilePath => Path.Combine(App.DataDir, "settings.json");

    public static void Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var loaded = JsonSerializer.Deserialize(File.ReadAllText(FilePath), JsonContext.Default.Settings);
                if (loaded != null) Current = loaded;
            }
        }
        catch (Exception ex)
        {
            App.Log(ex);
        }
    }

    private static readonly object SaveLock = new();

    // Called from the UI thread and from the update check's pool thread
    public static void Save()
    {
        lock (SaveLock)
        {
            try
            {
                Directory.CreateDirectory(App.DataDir);
                var tmp = FilePath + ".tmp";
                File.WriteAllText(tmp, JsonSerializer.Serialize(Current, JsonContext.Default.Settings));
                File.Move(tmp, FilePath, overwrite: true);
            }
            catch (Exception ex)
            {
                App.Log(ex);
            }
        }
    }
}
