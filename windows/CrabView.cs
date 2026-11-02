// The walking crab — ClawdView in main.swift. The window owns the frame
// counter; this element only draws.
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace CcGlance;

internal enum CrabState
{
    Idle,
    Working,
    Permission,
}

internal sealed class CrabView : FrameworkElement
{
    public const double TopMargin = 30;
    public const double BottomMargin = 30;
    private const double BounceHeadroom = 4;
    private const double BounceOffset = 3;

    private static readonly BitmapSource[] Frames = CrabFrames.Base64.Select(Decode).ToArray();

    private CrabState _state = CrabState.Idle;
    private int _frameIndex;

    public CrabView()
    {
        IsHitTestVisible = false;
        RenderOptions.SetBitmapScalingMode(this, BitmapScalingMode.HighQuality);
        SnapsToDevicePixels = true;
    }

    public static double AreaHeight => Frames[0].PixelHeight + BounceHeadroom;

    public void Update(CrabState state, int frameIndex)
    {
        if (state == _state && frameIndex == _frameIndex) return;
        _state = state;
        _frameIndex = frameIndex;
        InvalidateVisual();
    }

    protected override Size MeasureOverride(Size availableSize) =>
        new(Frames[0].PixelWidth, AreaHeight);

    protected override void OnRender(DrawingContext dc)
    {
        // The idle crab is drawn opaque: a translucent one read as see-through
        var frame = _state == CrabState.Idle ? Frames[0] : Frames[_frameIndex % Frames.Length];
        var y = _state == CrabState.Permission && _frameIndex % 2 == 1 ? BounceOffset : 0;
        dc.DrawImage(frame, new Rect(0, y, frame.PixelWidth, frame.PixelHeight));
    }

    private static BitmapSource Decode(string base64)
    {
        using var stream = new MemoryStream(Convert.FromBase64String(base64));
        var frame = BitmapFrame.Create(stream, BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
        frame.Freeze();
        return frame;
    }
}
