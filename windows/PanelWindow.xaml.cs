// The floating panel — AppDelegate / StatusPanel / RootView in main.swift.
// Never activates (WS_EX_NOACTIVATE + MA_NOACTIVATE), stays topmost, hidden
// from the taskbar; a 0.1s timer drives reloads, animation and layout.
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace CcGlance;

public partial class PanelWindow : Window
{
    private const double DefaultWidth = 300;
    private const double MinPanelWidth = 220;
    private const double MaxPanelWidth = 900;
    private const double BannerHeight = 24;
    private const double EmptyBlockHeight = 30;
    private const double RowsBottomPadding = 8;

    private readonly bool _acrylic;
    private readonly System.Windows.Threading.DispatcherTimer _timer = new();
    private readonly UpdateChecker _updater = new();
    private readonly DesktopWatcher _desktopWatcher = new();

    private List<SessionState> _sessions = new();
    private readonly List<SessionRow> _rows = new();
    private readonly List<ChildRow> _childRows = new();
    private string _signature = "";
    private int _tick;
    private int _sparkIndex;
    private int _crabFrame;
    private bool _refreshingUntitled;

    private nint _hwnd;
    private MenuItem? _updateItem;

    // Drag / resize state, in device pixels
    private enum DragMode
    {
        None,
        Move,
        ResizeLeft,
        ResizeRight,
    }

    private DragMode _drag;
    private Native.POINT _dragStart;
    private double _dragLeft, _dragTop, _dragWidth;
    private bool _menuButtonWasDown;

    public PanelWindow()
    {
        // Windows 11 22H2 has DWM backdrops; older builds get a solid panel.
        // AllowsTransparency is fixed once the handle exists, so decide now
        _acrylic = Environment.OSVersion.Version.Build >= 22621;
        if (!_acrylic)
        {
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
        }
        InitializeComponent();

        Root.BorderBrush = Theme.Border;
        Root.Background = _acrylic ? Theme.Tint : Theme.Fallback;
        // DWM rounds at ~8px; match it so the tint covers the whole surface
        if (_acrylic) Root.CornerRadius = new CornerRadius(8);
        EmptyLabel.FontFamily = Theme.UiFont;
        EmptyLabel.Foreground = Theme.TertiaryLabel;
        UpdateBanner.FontFamily = Theme.UiFont;
        UpdateBanner.Foreground = Theme.Orange;
        UpdateBanner.MouseLeftButtonUp += (_, _) => _updater.InstallAvailable(interactive: true);

        var width = Settings.Current.PanelWidth is double w && w >= MinPanelWidth ? Math.Min(w, MaxPanelWidth) : DefaultWidth;
        Width = width;
        RestorePosition(width);

        Root.MouseLeftButtonDown += OnRootMouseDown;
        LeftGrip.MouseLeftButtonDown += (_, e) => BeginDrag(DragMode.ResizeLeft, e);
        RightGrip.MouseLeftButtonDown += (_, e) => BeginDrag(DragMode.ResizeRight, e);
        MouseMove += (_, _) => ApplyDrag();
        MouseLeftButtonUp += (_, _) => EndDrag();
        LostMouseCapture += (_, _) => EndDrag();

        Root.ContextMenu = BuildMenu();

        _updater.UpdateAvailable += OnUpdateAvailable;
        _updater.PhaseChanged += RefreshBanner;

        SourceInitialized += OnSourceInitialized;
        Loaded += OnLoaded;
        _timer.Interval = TimeSpan.FromMilliseconds(100);
        _timer.Tick += (_, _) => Tick();
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _hwnd = new WindowInteropHelper(this).Handle;
        Native.MakeNonActivating(_hwnd);
        var source = HwndSource.FromHwnd(_hwnd);
        source?.AddHook(WndProc);
        if (_acrylic)
        {
            var margins = new Native.MARGINS { Left = -1, Right = -1, Top = -1, Bottom = -1 };
            Native.DwmExtendFrameIntoClientArea(_hwnd, ref margins);
            if (source?.CompositionTarget != null) source.CompositionTarget.BackgroundColor = Colors.Transparent;
            Native.SetAttribute(_hwnd, Native.DWMWA_USE_IMMERSIVE_DARK_MODE, 1);
            Native.SetAttribute(_hwnd, Native.DWMWA_WINDOW_CORNER_PREFERENCE, Native.DWMWCP_ROUND);
            if (Native.SetAttribute(_hwnd, Native.DWMWA_SYSTEMBACKDROP_TYPE, Native.DWMSBT_TRANSIENTWINDOW) != 0)
                Root.Background = Theme.Fallback;
        }
    }

    private nint WndProc(nint hwnd, int msg, nint wParam, nint lParam, ref bool handled)
    {
        switch (msg)
        {
            case Native.WM_MOUSEACTIVATE:
                handled = true;
                return Native.MA_NOACTIVATE;
            case Native.WM_DISPLAYCHANGE:
                Dispatcher.BeginInvoke(MoveOnScreenIfNeeded);
                break;
        }
        return 0;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        MoveOnScreenIfNeeded();
        _sessions = SessionStore.Load();
        _desktopWatcher.Start();
        DesktopStore.SweepAtLaunch();
        HookInstaller.CatchUpNewEnvironments(); // baseline
        _updater.Start();
        Tick();
        _timer.Start();
    }

    // MARK: Tick

    private void Tick()
    {
        _tick++;
        var now = SessionStore.Now;

        // A background window only gets capture events while the cursor is
        // over it, so a drag is also driven from here and ends on button-up
        if (_drag != DragMode.None)
        {
            if (Native.IsButtonDown(Native.VK_LBUTTON)) ApplyDrag();
            else EndDrag();
        }
        DismissMenuOnOutsideClick();

        if (_tick % 5 == 0) _sessions = SessionStore.Load();
        if (_tick % 3 == 0) _sparkIndex++;
        if (_tick % 150 == 0) HookInstaller.RefreshPrStatuses(_sessions, force: false);
        if (_tick % 50 == 0)
            Native.SetWindowPos(_hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0, Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
        if (_tick % 600 == 0)
        {
            HookInstaller.CatchUpNewEnvironments();
            if (_desktopWatcher.Start()) DesktopStore.EnqueueRefresh();
        }
        // Fresh sessions get their Desktop title a few seconds after the first
        // prompt; poll for it so the name lands mid-turn, capped at 5 minutes
        if (_tick % 20 == 0 && !_refreshingUntitled)
        {
            var untitled = _sessions
                .Where(s => string.IsNullOrEmpty(s.Title) && s.CreatedAt is double c && now - c < 300)
                .Select(s => s.SessionId)
                .ToHashSet();
            if (untitled.Count > 0)
            {
                _refreshingUntitled = true;
                DesktopStore.EnqueueRefresh(untitled, () => _refreshingUntitled = false);
            }
        }

        var grouped = _sessions
            .GroupBy(s => s.Project ?? "—")
            .Select(g => (Name: g.Key, Sessions: g.ToList()))
            .OrderBy(g => g.Name.ToLowerInvariant(), StringComparer.Ordinal)
            .ToList();

        // Rebuild rows only when the structure changes; otherwise update in place
        var signature = string.Join("|", grouped.Select(g =>
            $"{g.Name}#{g.Sessions.Count}#{string.Join(",", g.Sessions.Select(ChildItem.Count))}"));
        if (signature != _signature)
        {
            _signature = signature;
            Rows.Children.Clear();
            _rows.Clear();
            _childRows.Clear();
            foreach (var group in grouped)
            {
                Rows.Children.Add(new GroupHeaderRow(group.Name));
                foreach (var session in group.Sessions)
                {
                    var row = new SessionRow();
                    Rows.Children.Add(row);
                    _rows.Add(row);
                    for (var i = 0; i < ChildItem.Count(session); i++)
                    {
                        var child = new ChildRow();
                        Rows.Children.Add(child);
                        _childRows.Add(child);
                    }
                }
            }
        }

        var rowIndex = 0;
        var childIndex = 0;
        var childCount = 0;
        foreach (var group in grouped)
        {
            for (var j = 0; j < group.Sessions.Count; j++)
            {
                if (rowIndex >= _rows.Count) break;
                var session = group.Sessions[j];
                _rows[rowIndex].Update(session, _sparkIndex, now);
                var children = ChildItem.All(session);
                childCount += children.Count;
                // Hairline after every visual row except the group's last one
                var lastInGroup = j == group.Sessions.Count - 1;
                _rows[rowIndex].ShowSeparator = children.Count > 0 || !lastInGroup;
                for (var k = 0; k < children.Count; k++)
                {
                    if (childIndex >= _childRows.Count) break;
                    _childRows[childIndex].Update(children[k], _sparkIndex, now);
                    _childRows[childIndex].ShowSeparator = !(lastInGroup && k == children.Count - 1);
                    childIndex++;
                }
                rowIndex++;
            }
        }
        EmptyLabel.Visibility = _sessions.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

        // Crab reflects the most urgent status
        CrabState state;
        if (_sessions.Any(s => s.IsWaiting)) state = CrabState.Permission;
        else if (_sessions.Any(s => s.IsWorking)) state = CrabState.Working;
        else state = CrabState.Idle;
        if (state == CrabState.Working) _crabFrame++; // 0.1s per frame
        else if (state == CrabState.Permission && _tick % 3 == 0) _crabFrame++; // slower bounce
        Crab.Update(state, _crabFrame);

        // Height follows content; width is the user's
        var crabArea = CrabView.TopMargin + CrabView.AreaHeight + CrabView.BottomMargin;
        var content = crabArea + (_sessions.Count == 0
            ? EmptyBlockHeight
            : grouped.Count * GroupHeaderRow.RowHeight
              + _sessions.Count * SessionRow.RowHeight
              + childCount * ChildRow.RowHeight
              + RowsBottomPadding);
        if (UpdateBanner.Visibility == Visibility.Visible) content += BannerHeight;
        if (Math.Abs(Height - content) > 0.5) Height = content;
    }

    // MARK: Position

    private void RestorePosition(double width)
    {
        var s = Settings.Current;
        if (s.PanelLeft is double left && s.PanelTop is double top)
        {
            Left = left;
            Top = top;
            return;
        }
        var area = SystemParameters.WorkArea;
        Left = area.Right - width - 20;
        Top = area.Top + 40;
    }

    private void SavePosition()
    {
        Settings.Current.PanelLeft = Left;
        Settings.Current.PanelTop = Top;
        Settings.Current.PanelWidth = Width;
        Settings.Save();
    }

    // Clamp into the primary work area when no monitor shows a usable corner
    private void MoveOnScreenIfNeeded()
    {
        if (PresentationSource.FromVisual(this) is not HwndSource source || source.CompositionTarget == null) return;
        var toDevice = source.CompositionTarget.TransformToDevice;
        var l = Left * toDevice.M11;
        var t = Top * toDevice.M22;
        var w = Width * toDevice.M11;
        var h = Height * toDevice.M22;
        var needW = Math.Min(40 * toDevice.M11, w);
        var needH = Math.Min(40 * toDevice.M22, h);
        foreach (var area in Native.WorkAreas())
        {
            var ow = Math.Min(l + w, area.Right) - Math.Max(l, area.Left);
            var oh = Math.Min(t + h, area.Bottom) - Math.Max(t, area.Top);
            if (ow >= needW && oh >= needH) return;
        }
        var main = SystemParameters.WorkArea;
        Left = Math.Max(main.Left, Math.Min(Left, main.Right - Width));
        Top = Math.Max(main.Top, Math.Min(Top, main.Bottom - Height));
        SavePosition();
    }

    // MARK: Drag to move / edge resize (manual: DragMove goes through SC_MOVE,
    // which can activate the window)

    private void OnRootMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject d && (IsInside(d, LeftGrip) || IsInside(d, RightGrip) || IsInside(d, UpdateBanner)))
            return;
        BeginDrag(DragMode.Move, e);
    }

    private static bool IsInside(DependencyObject node, DependencyObject ancestor)
    {
        for (DependencyObject? cur = node; cur != null; cur = VisualTreeHelper.GetParent(cur))
            if (ReferenceEquals(cur, ancestor)) return true;
        return false;
    }

    private void BeginDrag(DragMode mode, MouseButtonEventArgs e)
    {
        if (!Native.GetCursorPos(out _dragStart)) return;
        _drag = mode;
        _dragLeft = Left;
        _dragTop = Top;
        _dragWidth = Width;
        CaptureMouse();
        e.Handled = true;
    }

    private void ApplyDrag()
    {
        if (_drag == DragMode.None || !Native.GetCursorPos(out var p)) return;
        if (PresentationSource.FromVisual(this) is not HwndSource source || source.CompositionTarget == null) return;
        var fromDevice = source.CompositionTarget.TransformFromDevice;
        var dx = (p.X - _dragStart.X) * fromDevice.M11;
        var dy = (p.Y - _dragStart.Y) * fromDevice.M22;
        switch (_drag)
        {
            case DragMode.Move:
                Left = _dragLeft + dx;
                Top = _dragTop + dy;
                break;
            case DragMode.ResizeRight:
                Width = Math.Clamp(_dragWidth + dx, MinPanelWidth, MaxPanelWidth);
                break;
            case DragMode.ResizeLeft:
                // Keep the right edge fixed
                var width = Math.Clamp(_dragWidth - dx, MinPanelWidth, MaxPanelWidth);
                Left = _dragLeft + (_dragWidth - width);
                Width = width;
                break;
        }
    }

    private void EndDrag()
    {
        if (_drag == DragMode.None) return;
        _drag = DragMode.None;
        if (IsMouseCaptured) ReleaseMouseCapture();
        SavePosition();
    }

    // A context menu opened by a window that never owns the foreground may
    // not see the outside click that should close it; close it from the tick
    private void DismissMenuOnOutsideClick()
    {
        var menu = Root.ContextMenu;
        if (menu == null || !menu.IsOpen)
        {
            _menuButtonWasDown = false;
            return;
        }
        var down = Native.IsButtonDown(Native.VK_LBUTTON) || Native.IsButtonDown(Native.VK_RBUTTON);
        var pressed = down && !_menuButtonWasDown;
        _menuButtonWasDown = down;
        if (!pressed || !Native.GetCursorPos(out var p)) return;
        try
        {
            var origin = menu.PointToScreen(new Point(0, 0));
            var size = menu.PointToScreen(new Point(menu.ActualWidth, menu.ActualHeight));
            if (p.X >= origin.X && p.X <= size.X && p.Y >= origin.Y && p.Y <= size.Y) return;
        }
        catch
        {
            return;
        }
        menu.IsOpen = false;
    }

    // MARK: Context menu

    private ContextMenu BuildMenu()
    {
        var menu = new ContextMenu();
        menu.Items.Add(new MenuItem { Header = $"ccglance v{UpdateChecker.CurrentVersion}", IsEnabled = false });
        _updateItem = new MenuItem { Visibility = Visibility.Collapsed };
        _updateItem.Click += (_, _) => _updater.InstallAvailable(interactive: true);
        menu.Items.Add(_updateItem);
        menu.Items.Add(Item("Check for updates…", CheckForUpdates));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Refresh session names", () =>
            DesktopStore.EnqueueRefresh(completion: () =>
            {
                _sessions = SessionStore.Load();
                HookInstaller.RefreshPrStatuses(_sessions, force: true);
                Tick();
            })));
        menu.Items.Add(Item("Clear finished sessions", () =>
        {
            SessionStore.ClearIdle();
            _sessions = SessionStore.Load();
            Tick();
        }));
        menu.Items.Add(Item("Reinstall Claude Code hooks", () => Task.Run(HookInstaller.RunInstaller)));
        menu.Items.Add(new Separator());

        var display = new MenuItem { Header = "Display" };
        display.Items.Add(Toggle("Show permission mode", () => Settings.Current.HideModeBadge, v => Settings.Current.HideModeBadge = v));
        display.Items.Add(Toggle("Show plan check", () => Settings.Current.HidePlanBadge, v => Settings.Current.HidePlanBadge = v));
        display.Items.Add(Toggle("Show elapsed time", () => Settings.Current.HideElapsedTime, v => Settings.Current.HideElapsedTime = v));
        display.Items.Add(Toggle("Show background tasks", () => Settings.Current.HideBackgroundTasks, v => Settings.Current.HideBackgroundTasks = v));
        menu.Items.Add(display);
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Quit ccglance", () => Application.Current.Shutdown()));
        return menu;
    }

    private static MenuItem Item(string header, Action action)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => action();
        return item;
    }

    // Stored as "hide" flags; checked means shown. The tick reads the prefs
    // each pass, so no explicit refresh is needed
    private static MenuItem Toggle(string header, Func<bool> hidden, Action<bool> setHidden)
    {
        var item = new MenuItem { Header = header, IsCheckable = true, IsChecked = !hidden() };
        item.Click += (_, _) =>
        {
            setHidden(!item.IsChecked);
            Settings.Save();
        };
        return item;
    }

    private async void CheckForUpdates()
    {
        UpdateChecker.Release? found;
        try
        {
            found = await _updater.CheckAsync();
        }
        catch (Exception ex)
        {
            App.Log(ex);
            return;
        }
        if (found == null)
        {
            MessageBox.Show($"Version {UpdateChecker.CurrentVersion} is the latest release.", "ccglance is up to date",
                MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }

    // MARK: Update banner

    private void OnUpdateAvailable(UpdateChecker.Release release)
    {
        if (_updateItem != null)
        {
            _updateItem.Header = $"Update to ccglance v{release.Version}…";
            _updateItem.Visibility = Visibility.Visible;
        }
        RefreshBanner();
        // Automatic install; a failure leaves the banner for a manual retry
        _updater.InstallAvailable(interactive: false);
    }

    private void RefreshBanner()
    {
        var release = _updater.Available;
        if (release == null)
        {
            UpdateBanner.Visibility = Visibility.Collapsed;
            return;
        }
        UpdateBanner.Visibility = Visibility.Visible;
        switch (_updater.CurrentPhase)
        {
            case UpdateChecker.Phase.Downloading:
                UpdateBanner.Text = "⬇ Downloading update…";
                UpdateBanner.IsHitTestVisible = false;
                break;
            case UpdateChecker.Phase.Installing:
                UpdateBanner.Text = "Installing update…";
                UpdateBanner.IsHitTestVisible = false;
                break;
            case UpdateChecker.Phase.Failed:
                UpdateBanner.Text = "⚠ " + (_updater.FailureMessage ?? "Update failed");
                UpdateBanner.IsHitTestVisible = false;
                break;
            default:
                UpdateBanner.Text = $"⬆ Update to v{release.Version}";
                UpdateBanner.IsHitTestVisible = true;
                break;
        }
    }
}
