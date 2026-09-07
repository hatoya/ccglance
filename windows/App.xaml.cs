using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Threading;

namespace CcGlance;

public partial class App : Application
{
    private Mutex? _mutex;

    public static string ExeDir => AppContext.BaseDirectory;
    public static string ExePath => Environment.ProcessPath ?? Path.Combine(ExeDir, "ccglance.exe");
    public static string DataDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ccglance");
    public static string ClaudeDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");
    public static string Version =>
        typeof(App).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
            is [System.Reflection.AssemblyInformationalVersionAttribute a] ? a.InformationalVersion : "0.0.0";

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // Single instance: the hook launches the app on every SessionStart, and
        // the updater's relaunch briefly overlaps the exiting instance.
        _mutex = new Mutex(false, @"Local\ccglance");
        bool owned;
        try
        {
            owned = _mutex.WaitOne(TimeSpan.FromSeconds(2));
        }
        catch (AbandonedMutexException)
        {
            owned = true;
        }
        if (!owned)
        {
            Shutdown();
            return;
        }

        DispatcherUnhandledException += OnUnhandledException;
        CleanupOldBinaries();
        RecordAppPath();
        try
        {
            Directory.CreateDirectory(SessionStore.SessionsDir);
        }
        catch (Exception ex)
        {
            Log(ex);
        }
        Settings.Load();

        // Like the macOS app, keep the hooks registered on every launch; off the
        // UI thread so a slow node startup never delays the panel.
        Task.Run(HookInstaller.RunInstaller);

        var window = new PanelWindow();
        MainWindow = window;
        window.Show();
    }

    private void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log(e.Exception);
        e.Handled = true;
    }

    // Releases the single-instance mutex so a relaunched copy can start
    public void ReleaseInstance()
    {
        try
        {
            _mutex?.ReleaseMutex();
        }
        catch
        {
        }
    }

    // The updater renames the running exe aside and may leave a work dir in
    // %TEMP% if it was killed mid-way; the next start removes both
    private static void CleanupOldBinaries()
    {
        try
        {
            foreach (var old in Directory.EnumerateFiles(ExeDir, "ccglance.exe.old*"))
            {
                try
                {
                    File.Delete(old);
                }
                catch
                {
                }
            }
        }
        catch
        {
        }
        try
        {
            foreach (var dir in Directory.EnumerateDirectories(Path.GetTempPath(), UpdateChecker.UpdateTempPrefix + "*"))
            {
                try
                {
                    Directory.Delete(dir, recursive: true);
                }
                catch
                {
                }
            }
        }
        catch
        {
        }
    }

    // The hook reads this to launch the app (see docs/session-schema.md)
    private static void RecordAppPath()
    {
        try
        {
            var dir = Path.Combine(ClaudeDir, "ccglance");
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "app-path.txt"), ExePath + "\n", new UTF8Encoding(false));
        }
        catch (Exception ex)
        {
            Log(ex);
        }
    }

    public static void Log(Exception ex) => Log(ex.ToString());

    private static readonly object LogLock = new();
    private static string? _lastLogged;

    // Bounded and de-duplicated: a persistent exception in the 10Hz tick
    // must not fill the disk
    public static void Log(string message)
    {
        lock (LogLock)
        {
            if (message == _lastLogged) return;
            _lastLogged = message;
            try
            {
                Directory.CreateDirectory(DataDir);
                var path = Path.Combine(DataDir, "ccglance.log");
                if (File.Exists(path) && new FileInfo(path).Length > 1_000_000) File.Delete(path);
                File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}\n");
            }
            catch
            {
            }
        }
    }
}
