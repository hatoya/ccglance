// Row views — GroupHeaderView, SessionRowView and ChildRowView in main.swift.
// A manual visual tree updated in place each tick, not bindings: the work per
// row is a few strings and one brush, and the pulse is per-tick imperative.
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace CcGlance;

internal static class RowText
{
    public static string Elapsed(double? start, double now)
    {
        if (start is not double s) return "";
        var sec = Math.Max(0, (int)(now - s));
        return sec >= 60 ? $"{sec / 60}m {sec % 60}s" : $"{sec}s";
    }

    public static string Title(SessionState s, double now)
    {
        if (!string.IsNullOrEmpty(s.Title)) return s.Title;
        if (s.CreatedAt is double created && now - created < 30) return "New session…";
        return "Session " + s.SessionId[..Math.Min(8, s.SessionId.Length)];
    }

    public static TextBlock Label(FontFamily family, double size, FontWeight weight, Brush color)
    {
        var block = new TextBlock
        {
            FontFamily = family,
            FontSize = size,
            FontWeight = weight,
            Foreground = color,
            VerticalAlignment = VerticalAlignment.Center,
            Focusable = false,
        };
        TextOptions.SetTextFormattingMode(block, TextFormattingMode.Display);
        return block;
    }

    public static TextBlock Glyph(Brush color)
    {
        var block = Label(Theme.MonoFont, 13, FontWeights.Normal, color);
        block.Width = 16;
        block.TextAlignment = TextAlignment.Center;
        return block;
    }

    public static TextBlock TimeLabel(Brush color)
    {
        var block = Label(Theme.UiFont, 11, FontWeights.Medium, color);
        block.TextAlignment = TextAlignment.Right;
        // Mirrors monospacedDigitSystemFont so the counter doesn't jitter
        block.SetValue(System.Windows.Documents.Typography.NumeralAlignmentProperty, FontNumeralAlignment.Tabular);
        return block;
    }

    public static Rectangle Separator()
    {
        return new Rectangle
        {
            Height = 1,
            Fill = Theme.Separator,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(4, 0, 4, 0),
            IsHitTestVisible = false,
        };
    }
}

internal sealed class GroupHeaderRow : Grid
{
    public const double RowHeight = 24;
    private readonly TextBlock _label;

    public GroupHeaderRow(string name)
    {
        Height = RowHeight;
        _label = RowText.Label(Theme.UiFont, 10, FontWeights.SemiBold, Theme.SecondaryLabel);
        _label.TextTrimming = TextTrimming.CharacterEllipsis;
        // Bottom-aligned so the space above doubles as the inter-group gap
        _label.VerticalAlignment = VerticalAlignment.Bottom;
        _label.Margin = new Thickness(10, 0, 10, 4);
        _label.Text = name;
        Children.Add(_label);
    }
}

internal sealed class SessionRow : Grid
{
    public const double RowHeight = 28;

    private readonly Rectangle _highlight;
    private readonly SolidColorBrush _pulse = new(Colors.Transparent);
    private readonly TextBlock _glyph;
    private readonly TextBlock _title;
    private readonly TextBlock _planBadge;
    private readonly TextBlock _modeBadge;
    private readonly TextBlock _right;
    private readonly Rectangle _separator;

    private string? _modeRaw;
    private bool _planShown;
    private bool _glyphIsFa;

    public SessionRow()
    {
        Height = RowHeight;
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        _highlight = new Rectangle { RadiusX = 4, RadiusY = 4, Fill = _pulse, IsHitTestVisible = false };
        SetColumnSpan(_highlight, 5);
        Children.Add(_highlight);

        _glyph = RowText.Glyph(Theme.Idle);
        _glyph.Margin = new Thickness(8, 0, 0, 0);
        SetColumn(_glyph, 0);
        Children.Add(_glyph);

        _title = RowText.Label(Theme.UiFont, 12, FontWeights.SemiBold, Theme.Label);
        _title.TextTrimming = TextTrimming.CharacterEllipsis;
        _title.Margin = new Thickness(8, 0, 8, 0);
        SetColumn(_title, 1);
        Children.Add(_title);

        _planBadge = RowText.Label(Theme.FaFont, 11, FontWeights.Bold, Theme.PrOpen);
        _planBadge.Visibility = Visibility.Collapsed;
        SetColumn(_planBadge, 2);
        Children.Add(_planBadge);

        _modeBadge = RowText.Label(Theme.UiFont, 9, FontWeights.Bold, Theme.Idle);
        _modeBadge.Visibility = Visibility.Collapsed;
        SetColumn(_modeBadge, 3);
        Children.Add(_modeBadge);

        _right = RowText.TimeLabel(Theme.Label);
        _right.MinWidth = 54;
        _right.Margin = new Thickness(0, 0, 12, 0);
        SetColumn(_right, 4);
        Children.Add(_right);

        _separator = RowText.Separator();
        SetColumnSpan(_separator, 5);
        Children.Add(_separator);
    }

    public bool ShowSeparator
    {
        set => _separator.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
    }

    public void Update(SessionState s, int sparkIndex, double now)
    {
        var prefs = Settings.Current;
        _title.Text = RowText.Title(s, now);

        // Mode badge
        var (modeText, modeColor) = ModeBadge(prefs.HideModeBadge ? null : s.PermissionMode);
        if (s.PermissionMode != _modeRaw || (modeText.Length > 0) != (_modeBadge.Visibility == Visibility.Visible))
        {
            _modeRaw = s.PermissionMode;
            _modeBadge.Text = modeText;
            _modeBadge.Foreground = modeColor;
            _modeBadge.ToolTip = modeText.Length > 0 ? $"Permission mode: {s.PermissionMode}" : null;
            _modeBadge.Visibility = modeText.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
            _modeBadge.Margin = new Thickness(0, 0, modeText.Length > 0 ? 6 : 0, 0);
        }

        // Plan-approved check
        var showPlan = s.PlanApprovedAt != null && !prefs.HidePlanBadge;
        if (showPlan != _planShown)
        {
            _planShown = showPlan;
            _planBadge.Text = Theme.FaCheck;
            _planBadge.ToolTip = "Plan approved";
            _planBadge.Visibility = showPlan ? Visibility.Visible : Visibility.Collapsed;
            _planBadge.Margin = new Thickness(0, 0, showPlan ? 6 : 0, 0);
        }

        switch (s.Status)
        {
            case "thinking":
            case "tool":
                SetGlyph(Theme.SparkFrames[sparkIndex % Theme.SparkFrames.Length], Theme.Orange, false, null);
                var elapsed = prefs.HideElapsedTime ? "" : RowText.Elapsed(s.TurnStartedAt, now);
                _right.Text = elapsed.Length > 0
                    ? elapsed
                    : (s.Status == "thinking" ? "Thinking…" : s.Tool ?? "Using tool");
                _right.Foreground = Theme.Label;
                _pulse.Color = Colors.Transparent;
                break;

            case "permission":
                SetGlyph(Theme.FaHand, Theme.Yellow, true, "Waiting for permission");
                _right.Text = prefs.HideElapsedTime
                    ? ""
                    : RowText.Elapsed(s.WaitStartedAt ?? s.TurnStartedAt, now);
                _right.Foreground = Theme.Label;
                var alpha = 0.10 + 0.10 * (0.5 + 0.5 * Math.Sin(now * 4));
                var c = Theme.Yellow.Color;
                _pulse.Color = Color.FromArgb((byte)Math.Round(alpha * 255), c.R, c.G, c.B);
                break;

            default:
                var pr = PrGlyph(s);
                if (pr is var (glyph, color, tooltip) && glyph != null)
                    SetGlyph(glyph, color!, true, tooltip);
                else
                    SetGlyph("●", Theme.Idle, false, null);
                _right.Text = "Idle";
                _right.Foreground = Theme.TertiaryLabel;
                _pulse.Color = Colors.Transparent;
                break;
        }
    }

    private void SetGlyph(string text, Brush color, bool fa, string? tooltip)
    {
        if (fa != _glyphIsFa)
        {
            _glyphIsFa = fa;
            _glyph.FontFamily = fa ? Theme.FaFont : Theme.MonoFont;
            _glyph.FontSize = fa ? 11 : 13;
        }
        if (_glyph.Text != text) _glyph.Text = text;
        if (!ReferenceEquals(_glyph.Foreground, color)) _glyph.Foreground = color;
        if (!Equals(_glyph.ToolTip, tooltip)) _glyph.ToolTip = tooltip;
    }

    private static (string, Brush) ModeBadge(string? mode) => mode switch
    {
        null or "default" => ("", Brushes.Transparent),
        "plan" => ("PLAN", Theme.ModePlan),
        "acceptEdits" => ("ACCEPT", Theme.PrOpen),
        "auto" => ("AUTO", Theme.Yellow),
        "dontAsk" => ("NO ASK", Theme.Orange),
        "bypassPermissions" => ("BYPASS", Theme.PrClosed),
        _ => (mode.ToUpperInvariant()[..Math.Min(8, mode.Length)], Theme.Idle),
    };

    // PR indicator for idle rows; null glyph means plain dot
    private static (string? glyph, Brush? color, string? tooltip) PrGlyph(SessionState s)
    {
        var pr = s.Pr;
        if (pr?.State == null) return (null, null, null);
        if (pr.Url != null && s.PrDismissed != null && s.PrDismissed.Contains(pr.Url)) return (null, null, null);
        (string glyph, Brush color, string label) = pr.State switch
        {
            "OPEN" when pr.Mergeable == "CONFLICTING" => (Theme.FaPullRequest, Theme.Orange, "conflict"),
            "OPEN" when pr.IsDraft == true => (Theme.FaPullRequest, Theme.PrDraft, "draft"),
            "OPEN" => (Theme.FaPullRequest, Theme.PrOpen, "open"),
            "MERGED" => (Theme.FaMerge, Theme.PrMerged, "merged"),
            "CLOSED" => (Theme.FaPullRequest, Theme.PrClosed, "closed"),
            _ => ("", Theme.Idle, ""),
        };
        if (glyph.Length == 0) return (null, null, null);
        var tooltip = pr.Number is int n ? $"PR #{n} · {label}" : $"PR · {label}";
        return (glyph, color, tooltip);
    }
}

internal readonly record struct ChildItem(string Label, double? StartedAt)
{
    public static int Count(SessionState s) =>
        Settings.Current.HideBackgroundTasks ? 0 : (s.Agents?.Count ?? 0) + (s.Tasks?.Count ?? 0);

    // Agents first, then background commands, as the hook orders them
    public static List<ChildItem> All(SessionState s)
    {
        var items = new List<ChildItem>();
        if (Settings.Current.HideBackgroundTasks) return items;
        if (s.Agents != null)
            foreach (var a in s.Agents)
                items.Add(new ChildItem(a.Description ?? a.Type ?? "agent", a.StartedAt));
        if (s.Tasks != null)
            foreach (var t in s.Tasks)
                items.Add(new ChildItem(t.Description ?? (t.Kind == "monitor" ? "monitor" : "command"), t.StartedAt));
        return items;
    }
}

internal sealed class ChildRow : Grid
{
    public const double RowHeight = 24;

    private readonly TextBlock _spark;
    private readonly TextBlock _desc;
    private readonly TextBlock _time;
    private readonly Rectangle _separator;

    public ChildRow()
    {
        Height = RowHeight;
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var tree = RowText.Glyph(Theme.TertiaryLabel);
        tree.Text = "└";
        tree.Margin = new Thickness(8, 0, 0, 0);
        SetColumn(tree, 0);
        Children.Add(tree);

        _spark = RowText.Glyph(Theme.Orange);
        _spark.Margin = new Thickness(4, 0, 0, 0);
        SetColumn(_spark, 1);
        Children.Add(_spark);

        _desc = RowText.Label(Theme.UiFont, 12, FontWeights.Normal, Theme.SecondaryLabel);
        _desc.TextTrimming = TextTrimming.CharacterEllipsis;
        _desc.Margin = new Thickness(5, 0, 8, 0);
        SetColumn(_desc, 2);
        Children.Add(_desc);

        _time = RowText.TimeLabel(Theme.SecondaryLabel);
        _time.Margin = new Thickness(0, 0, 12, 0);
        SetColumn(_time, 3);
        Children.Add(_time);

        _separator = RowText.Separator();
        _separator.Visibility = Visibility.Collapsed;
        SetColumnSpan(_separator, 4);
        Children.Add(_separator);
    }

    public bool ShowSeparator
    {
        set => _separator.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
    }

    public void Update(ChildItem item, int sparkIndex, double now)
    {
        var spark = Theme.SparkFrames[sparkIndex % Theme.SparkFrames.Length];
        if (_spark.Text != spark) _spark.Text = spark;
        if (_desc.Text != item.Label) _desc.Text = item.Label;
        var time = Settings.Current.HideElapsedTime ? "" : RowText.Elapsed(item.StartedAt, now);
        if (_time.Text != time) _time.Text = time;
    }
}
