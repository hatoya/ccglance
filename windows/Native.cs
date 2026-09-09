// Win32 interop for the parts WPF has no API for: a window that never
// activates, the DWM backdrop, and monitor work areas.
using System.Runtime.InteropServices;

namespace CcGlance;

internal static class Native
{
    public const int GWL_EXSTYLE = -20;
    public const long WS_EX_TOPMOST = 0x00000008;
    public const long WS_EX_TOOLWINDOW = 0x00000080;
    public const long WS_EX_NOACTIVATE = 0x08000000;

    public const int WM_MOUSEACTIVATE = 0x0021;
    public const int WM_DISPLAYCHANGE = 0x007E;
    public const nint MA_NOACTIVATE = 3;

    public const int VK_LBUTTON = 0x01;
    public const int VK_RBUTTON = 0x02;

    public static readonly nint HWND_TOPMOST = -1;
    public const uint SWP_NOSIZE = 0x0001;
    public const uint SWP_NOMOVE = 0x0002;
    public const uint SWP_NOACTIVATE = 0x0010;

    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    public const int DWMWA_WINDOW_CORNER_PREFERENCE = 33;
    public const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    public const int DWMWCP_ROUND = 2;
    // Acrylic; Mica goes flat while the window is inactive, which is always
    public const int DWMSBT_TRANSIENTWINDOW = 3;

    [StructLayout(LayoutKind.Sequential)]
    public struct MARGINS
    {
        public int Left, Right, Top, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT
    {
        public int X, Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFO
    {
        public int Size;
        public RECT Monitor;
        public RECT Work;
        public uint Flags;
    }

    public delegate bool MonitorEnumProc(nint monitor, nint hdc, ref RECT rect, nint data);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")]
    public static extern nint GetWindowLongPtr(nint hwnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    public static extern nint SetWindowLongPtr(nint hwnd, int index, nint value);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(nint hwnd, nint after, int x, int y, int cx, int cy, uint flags);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int key);

    public static bool IsButtonDown(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(nint hdc, nint clip, MonitorEnumProc proc, nint data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfo(nint monitor, ref MONITORINFO info);

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(nint hwnd, int attribute, ref int value, int size);

    [DllImport("dwmapi.dll")]
    public static extern int DwmExtendFrameIntoClientArea(nint hwnd, ref MARGINS margins);

    public static void MakeNonActivating(nint hwnd)
    {
        var style = (long)GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        style |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST;
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, (nint)style);
    }

    public static int SetAttribute(nint hwnd, int attribute, int value) =>
        DwmSetWindowAttribute(hwnd, attribute, ref value, sizeof(int));

    // Work areas of every monitor, in device pixels
    public static List<RECT> WorkAreas()
    {
        var areas = new List<RECT>();
        EnumDisplayMonitors(0, 0, (nint monitor, nint _, ref RECT _, nint _) =>
        {
            var info = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
            if (GetMonitorInfo(monitor, ref info)) areas.Add(info.Work);
            return true;
        }, 0);
        return areas;
    }
}
