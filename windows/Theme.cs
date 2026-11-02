// Colors, fonts and glyphs — the Theme enum of Sources/main.swift. The panel
// is always dark, so the dynamic macOS label colors are pinned to their
// darkAqua values.
using System.Windows.Media;

namespace CcGlance;

internal static class Theme
{
    public static readonly SolidColorBrush Orange = Brush(0xD9, 0x77, 0x57);
    public static readonly SolidColorBrush Yellow = Brush(0xE8, 0xC4, 0x4A);
    public static readonly SolidColorBrush Label = Brush(0xFF, 0xFF, 0xFF);
    public static readonly SolidColorBrush SecondaryLabel = Brush(0xFF, 0xFF, 0xFF, 0.55);
    public static readonly SolidColorBrush TertiaryLabel = Brush(0xFF, 0xFF, 0xFF, 0.25);
    public static readonly SolidColorBrush Idle = TertiaryLabel;
    public static readonly SolidColorBrush Separator = Brush(0xFF, 0xFF, 0xFF, 0.10);
    public static readonly SolidColorBrush Border = Brush(0xFF, 0xFF, 0xFF, 0.18);
    // Black at 35% over the acrylic, matching the macOS tint layer
    public static readonly SolidColorBrush Tint = Brush(0x00, 0x00, 0x00, 0.35);
    // Solid stand-in when no system backdrop is available
    public static readonly SolidColorBrush Fallback = Brush(0x1C, 0x1C, 0x1E, 0.92);

    // PR state colors matching GitHub's dark palette
    public static readonly SolidColorBrush PrOpen = Brush(0x3F, 0xB9, 0x50);
    public static readonly SolidColorBrush PrMerged = Brush(0xA3, 0x71, 0xF7);
    public static readonly SolidColorBrush PrClosed = Brush(0xF8, 0x51, 0x49);
    public static readonly SolidColorBrush PrDraft = TertiaryLabel;
    public static readonly SolidColorBrush ModePlan = Brush(0x58, 0xA6, 0xFF);

    public static readonly string[] SparkFrames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"];

    // Font Awesome 6 Free Solid glyphs (font bundled as a resource)
    public const string FaPullRequest = "";
    public const string FaMerge = "";
    public const string FaHand = "";
    public const string FaCheck = "";

    public static readonly FontFamily UiFont = new("Segoe UI");
    public static readonly FontFamily MonoFont = new("Consolas, Segoe UI Symbol, Segoe UI");
    public static readonly FontFamily FaFont =
        new(new Uri("pack://application:,,,/"), "./Assets/#Font Awesome 6 Free Solid");

    private static SolidColorBrush Brush(byte r, byte g, byte b, double alpha = 1)
    {
        var brush = new SolidColorBrush(Color.FromArgb((byte)Math.Round(alpha * 255), r, g, b));
        brush.Freeze();
        return brush;
    }
}
