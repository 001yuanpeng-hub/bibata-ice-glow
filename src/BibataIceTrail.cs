using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BibataIceTrail
{
    internal enum PresetKind
    {
        Light = 0,
        Standard = 1,
        Vivid = 2
    }

    internal enum PaletteKind
    {
        Ice = 0,
        Cyan = 1,
        Frost = 2,
        Custom = 3,
        PinkBlue = 4,
        Rainbow = 5
    }

    internal enum PaletteMode
    {
        Solid = 0,
        PinkBlue = 1,
        Rainbow = 2
    }

    internal struct TrailPreset
    {
        public float LifetimeMs;
        public float CoreRadius;
        public float HaloRadius;
        public float HaloAlpha;
        public float CoreAlpha;
        public float RippleDurationMs;
        public float RippleMaxRadius;
        public float RippleBoost;
    }

    internal struct ColorPalette
    {
        public PaletteMode Mode;
        public float HaloR, HaloG, HaloB;
        public float CoreR, CoreG, CoreB;
    }

    internal struct TrailSample
    {
        public int X;
        public int Y;
        public long Ticks;
        public int StrokeId;
    }

    internal struct ClickRipple
    {
        public int X;
        public int Y;
        public long Ticks;
        public int Kind; // 0 = left/middle click, 1 = right click
    }

    internal struct SplineNode
    {
        public float X;
        public float Y;
        public float U;
        public float Env;
    }

    internal sealed class AppConfig
    {
        public bool Enabled;
        public bool TrailEnabled;
        public bool ClickRippleEnabled;
        public bool DragGlowEnabled;
        public bool ShakeLocateEnabled;
        public bool ScrollGlowEnabled;
        public bool HotkeyEnabled;
        public PresetKind Preset;
        public PaletteKind Palette;
        public string CustomColorHex;
        public bool AutoPauseFullscreen;
        public bool ShowTrayIcon;

        private readonly string _path;

        public AppConfig(string path)
        {
            _path = path;
            Enabled = true;
            TrailEnabled = true;
            ClickRippleEnabled = true;
            DragGlowEnabled = true;
            ShakeLocateEnabled = true;
            ScrollGlowEnabled = true;
            HotkeyEnabled = true;
            Preset = PresetKind.Standard;
            Palette = PaletteKind.Ice;
            CustomColorHex = "#A78BFA";
            AutoPauseFullscreen = true;
            ShowTrayIcon = false;
        }

        public void Load()
        {
            try
            {
                if (!File.Exists(_path)) return;
                string[] lines = File.ReadAllLines(_path, Encoding.UTF8);
                for (int i = 0; i < lines.Length; i++)
                {
                    string line = lines[i].Trim();
                    if (line.Length == 0 || line[0] == '#' || line[0] == ';') continue;
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    string key = line.Substring(0, eq).Trim();
                    string val = line.Substring(eq + 1).Trim();
                    if (string.Equals(key, "Enabled", StringComparison.OrdinalIgnoreCase))
                    {
                        bool b;
                        if (bool.TryParse(val, out b)) Enabled = b;
                    }
                    else if (string.Equals(key, "TrailEnabled", StringComparison.OrdinalIgnoreCase))
                    {
                        bool t;
                        if (bool.TryParse(val, out t)) TrailEnabled = t;
                    }
                    else if (string.Equals(key, "ClickRippleEnabled", StringComparison.OrdinalIgnoreCase))
                    {
                        bool r;
                        if (bool.TryParse(val, out r)) ClickRippleEnabled = r;
                    }
                    else if (string.Equals(key, "DragGlowEnabled", StringComparison.OrdinalIgnoreCase))
                    {
                        bool d;
                        if (bool.TryParse(val, out d)) DragGlowEnabled = d;
                    }
                    else if (string.Equals(key, "ShakeLocateEnabled", StringComparison.OrdinalIgnoreCase))
                    {
                        bool s;
                        if (bool.TryParse(val, out s)) ShakeLocateEnabled = s;
                    }
                    else if (string.Equals(key, "ScrollGlowEnabled", StringComparison.OrdinalIgnoreCase))
                    {
                        bool sg;
                        if (bool.TryParse(val, out sg)) ScrollGlowEnabled = sg;
                    }
                    else if (string.Equals(key, "HotkeyEnabled", StringComparison.OrdinalIgnoreCase))
                    {
                        bool h;
                        if (bool.TryParse(val, out h)) HotkeyEnabled = h;
                    }
                    else if (string.Equals(key, "Preset", StringComparison.OrdinalIgnoreCase))
                    {
                        int p;
                        if (int.TryParse(val, NumberStyles.Integer, CultureInfo.InvariantCulture, out p) && p >= 0 && p <= 2)
                        {
                            Preset = (PresetKind)p;
                        }
                    }
                    else if (string.Equals(key, "Palette", StringComparison.OrdinalIgnoreCase))
                    {
                        int c;
                        if (int.TryParse(val, NumberStyles.Integer, CultureInfo.InvariantCulture, out c) && c >= 0 && c <= 5)
                        {
                            Palette = (PaletteKind)c;
                        }
                        else if (string.Equals(val, "Ice", StringComparison.OrdinalIgnoreCase)) Palette = PaletteKind.Ice;
                        else if (string.Equals(val, "Cyan", StringComparison.OrdinalIgnoreCase)) Palette = PaletteKind.Cyan;
                        else if (string.Equals(val, "Frost", StringComparison.OrdinalIgnoreCase)) Palette = PaletteKind.Frost;
                        else if (string.Equals(val, "Custom", StringComparison.OrdinalIgnoreCase)) Palette = PaletteKind.Custom;
                        else if (string.Equals(val, "PinkBlue", StringComparison.OrdinalIgnoreCase)) Palette = PaletteKind.PinkBlue;
                        else if (string.Equals(val, "Rainbow", StringComparison.OrdinalIgnoreCase)) Palette = PaletteKind.Rainbow;
                    }
                    else if (string.Equals(key, "CustomColor", StringComparison.OrdinalIgnoreCase))
                    {
                        byte cr, cg, cb;
                        if (TryParseHexColor(val, out cr, out cg, out cb))
                        {
                            CustomColorHex = string.Format(CultureInfo.InvariantCulture, "#{0:X2}{1:X2}{2:X2}", cr, cg, cb);
                        }
                    }
                    else if (string.Equals(key, "AutoPauseFullscreen", StringComparison.OrdinalIgnoreCase))
                    {
                        bool a;
                        if (bool.TryParse(val, out a)) AutoPauseFullscreen = a;
                    }
                    else if (string.Equals(key, "ShowTrayIcon", StringComparison.OrdinalIgnoreCase))
                    {
                        bool st;
                        if (bool.TryParse(val, out st)) ShowTrayIcon = st;
                    }
                }
            }
            catch
            {
            }
        }

        public void Save()
        {
            try
            {
                string dir = Path.GetDirectoryName(_path);
                if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                {
                    Directory.CreateDirectory(dir);
                }
                StringBuilder sb = new StringBuilder();
                sb.AppendLine("[BibataIceTrail]");
                sb.AppendLine("Enabled=" + (Enabled ? "true" : "false"));
                sb.AppendLine("TrailEnabled=" + (TrailEnabled ? "true" : "false"));
                sb.AppendLine("ClickRippleEnabled=" + (ClickRippleEnabled ? "true" : "false"));
                sb.AppendLine("DragGlowEnabled=" + (DragGlowEnabled ? "true" : "false"));
                sb.AppendLine("ShakeLocateEnabled=" + (ShakeLocateEnabled ? "true" : "false"));
                sb.AppendLine("ScrollGlowEnabled=" + (ScrollGlowEnabled ? "true" : "false"));
                sb.AppendLine("HotkeyEnabled=" + (HotkeyEnabled ? "true" : "false"));
                sb.AppendLine("Preset=" + ((int)Preset).ToString(CultureInfo.InvariantCulture));
                sb.AppendLine("Palette=" + ((int)Palette).ToString(CultureInfo.InvariantCulture));
                sb.AppendLine("CustomColor=" + CustomColorHex);
                sb.AppendLine("AutoPauseFullscreen=" + (AutoPauseFullscreen ? "true" : "false"));
                sb.AppendLine("ShowTrayIcon=" + (ShowTrayIcon ? "true" : "false"));
                File.WriteAllText(_path, sb.ToString(), Encoding.UTF8);
            }
            catch
            {
            }
        }

        public static TrailPreset GetPreset(PresetKind kind)
        {
            TrailPreset p = new TrailPreset();
            if (kind == PresetKind.Light)
            {
                p.LifetimeMs = 140f;
                p.CoreRadius = 2.8f;
                p.HaloRadius = 10.5f;
                p.HaloAlpha = 0.40f;
                p.CoreAlpha = 0.60f;
                p.RippleDurationMs = 240f;
                p.RippleMaxRadius = 22f;
                p.RippleBoost = 0.85f;
            }
            else if (kind == PresetKind.Vivid)
            {
                p.LifetimeMs = 250f;
                p.CoreRadius = 4.5f;
                p.HaloRadius = 18.5f;
                p.HaloAlpha = 0.72f;
                p.CoreAlpha = 0.90f;
                p.RippleDurationMs = 350f;
                p.RippleMaxRadius = 38f;
                p.RippleBoost = 1.20f;
            }
            else
            {
                p.LifetimeMs = 190f;
                p.CoreRadius = 3.6f;
                p.HaloRadius = 14.0f;
                p.HaloAlpha = 0.58f;
                p.CoreAlpha = 0.78f;
                p.RippleDurationMs = 290f;
                p.RippleMaxRadius = 30f;
                p.RippleBoost = 1.05f;
            }
            return p;
        }

        public static bool TryParseHexColor(string hex, out byte r, out byte g, out byte b)
        {
            r = 167;
            g = 139;
            b = 250;
            if (string.IsNullOrEmpty(hex)) return false;
            string s = hex.Trim();
            if (s.StartsWith("#", StringComparison.Ordinal)) s = s.Substring(1);
            if (s.Length != 6) return false;
            int rgb;
            if (!int.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out rgb)) return false;
            r = (byte)((rgb >> 16) & 0xFF);
            g = (byte)((rgb >> 8) & 0xFF);
            b = (byte)(rgb & 0xFF);
            return true;
        }

        public static ColorPalette GetPalette(PaletteKind kind, string customHex)
        {
            ColorPalette c = new ColorPalette();
            c.Mode = PaletteMode.Solid;
            if (kind == PaletteKind.Custom)
            {
                byte hr, hg, hb;
                TryParseHexColor(customHex, out hr, out hg, out hb);
                c.HaloR = (float)hr / 255f;
                c.HaloG = (float)hg / 255f;
                c.HaloB = (float)hb / 255f;
                c.CoreR = c.HaloR + (1.0f - c.HaloR) * 0.82f;
                c.CoreG = c.HaloG + (1.0f - c.HaloG) * 0.82f;
                c.CoreB = c.HaloB + (1.0f - c.HaloB) * 0.82f;
            }
            else if (kind == PaletteKind.Cyan)
            {
                c.HaloR = 56f / 255f;
                c.HaloG = 232f / 255f;
                c.HaloB = 216f / 255f;
                c.CoreR = 240f / 255f;
                c.CoreG = 255f / 255f;
                c.CoreB = 253f / 255f;
            }
            else if (kind == PaletteKind.Frost)
            {
                c.HaloR = 184f / 255f;
                c.HaloG = 216f / 255f;
                c.HaloB = 255f / 255f;
                c.CoreR = 1.0f;
                c.CoreG = 1.0f;
                c.CoreB = 1.0f;
            }
            else if (kind == PaletteKind.PinkBlue)
            {
                c.Mode = PaletteMode.PinkBlue;
                c.HaloR = 0.62f;
                c.HaloG = 0.56f;
                c.HaloB = 0.89f;
                c.CoreR = 0.92f;
                c.CoreG = 0.91f;
                c.CoreB = 0.98f;
            }
            else if (kind == PaletteKind.Rainbow)
            {
                c.Mode = PaletteMode.Rainbow;
                c.HaloR = 0.40f;
                c.HaloG = 0.85f;
                c.HaloB = 1.00f;
                c.CoreR = 0.90f;
                c.CoreG = 0.98f;
                c.CoreB = 1.00f;
            }
            else
            {
                c.HaloR = 56f / 255f;
                c.HaloG = 178f / 255f;
                c.HaloB = 255f / 255f;
                c.CoreR = 238f / 255f;
                c.CoreG = 250f / 255f;
                c.CoreB = 255f / 255f;
            }
            return c;
        }
    }

    internal static class NativeMethods
    {
        public const int WS_POPUP = unchecked((int)0x80000000);
        public const int WS_EX_LAYERED = 0x00080000;
        public const int WS_EX_TRANSPARENT = 0x00000020;
        public const int WS_EX_TOPMOST = 0x00000008;
        public const int WS_EX_TOOLWINDOW = 0x00000080;
        public const int WS_EX_NOACTIVATE = 0x08000000;

        public const int WM_DESTROY = 0x0002;
        public const int WM_MOUSEACTIVATE = 0x0021;
        public const int WM_NCHITTEST = 0x0084;
        public const int WM_INPUT = 0x00FF;
        public const int WM_HOTKEY = 0x0312;

        public const int VK_LBUTTON = 0x01;
        public const uint MOD_ALT = 0x0001;
        public const uint MOD_CONTROL = 0x0002;
        public const uint MOD_SHIFT = 0x0004;
        public const uint MOD_NOREPEAT = 0x4000;
        public const uint VK_C = 0x43;
        public const uint VK_G = 0x47;

        public const int HTTRANSPARENT = -1;
        public const int MA_NOACTIVATE = 3;

        public const int SW_HIDE = 0;

        public static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
        public const uint SWP_NOSIZE = 0x0001;
        public const uint SWP_NOMOVE = 0x0002;
        public const uint SWP_NOACTIVATE = 0x0010;
        public const uint SWP_SHOWWINDOW = 0x0040;

        public const uint ULW_ALPHA = 0x00000002;
        public const byte AC_SRC_OVER = 0x00;
        public const byte AC_SRC_ALPHA = 0x01;

        public const uint RIDEV_INPUTSINK = 0x00000100;
        public const uint RID_INPUT = 0x10000003;
        public const int RIM_TYPEMOUSE = 0;
        public const ushort RI_MOUSE_LEFT_BUTTON_DOWN = 0x0001;
        public const ushort RI_MOUSE_LEFT_BUTTON_UP = 0x0002;
        public const ushort RI_MOUSE_RIGHT_BUTTON_DOWN = 0x0004;
        public const ushort RI_MOUSE_MIDDLE_BUTTON_DOWN = 0x0010;
        public const ushort RI_MOUSE_WHEEL = 0x0400;
        public const uint MONITOR_DEFAULTTONEAREST = 0x00000002;
        public const int MDT_EFFECTIVE_DPI = 0;

        public const uint PM_REMOVE = 0x0001;
        public const uint QS_ALLINPUT = 0x04FF;
        public const uint INFINITE = 0xFFFFFFFF;
        public const uint WAIT_OBJECT_0 = 0x00000000;

        public delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int X;
            public int Y;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct SIZE
        {
            public int cx;
            public int cy;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct BLENDFUNCTION
        {
            public byte BlendOp;
            public byte BlendFlags;
            public byte SourceConstantAlpha;
            public byte AlphaFormat;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct WNDCLASSEXW
        {
            public uint cbSize;
            public uint style;
            public WndProcDelegate lpfnWndProc;
            public int cbClsExtra;
            public int cbWndExtra;
            public IntPtr hInstance;
            public IntPtr hIcon;
            public IntPtr hCursor;
            public IntPtr hbrBackground;
            public string lpszMenuName;
            public string lpszClassName;
            public IntPtr hIconSm;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public POINT pt;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct RAWINPUTDEVICE
        {
            public ushort usUsagePage;
            public ushort usUsage;
            public uint dwFlags;
            public IntPtr hwndTarget;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct RAWINPUTHEADER
        {
            public uint dwType;
            public uint dwSize;
            public IntPtr hDevice;
            public IntPtr wParam;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct BITMAPINFOHEADER
        {
            public uint biSize;
            public int biWidth;
            public int biHeight;
            public ushort biPlanes;
            public ushort biBitCount;
            public uint biCompression;
            public uint biSizeImage;
            public int biXPelsPerMeter;
            public int biYPelsPerMeter;
            public uint biClrUsed;
            public uint biClrImportant;
        }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT lpPoint);

        [DllImport("user32.dll")]
        public static extern IntPtr MonitorFromPoint(POINT pt, uint dwFlags);

        [DllImport("shcore.dll")]
        public static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterRawInputDevices(
            [MarshalAs(UnmanagedType.LPArray)] RAWINPUTDEVICE[] pRawInputDevices,
            uint uiNumDevices,
            uint cbSize);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint GetRawInputData(
            IntPtr hRawInput,
            uint uiCommand,
            [Out] byte[] pData,
            ref uint pcbSize,
            uint cbSizeHeader);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr GetModuleHandleW(string lpModuleName);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern ushort RegisterClassExW(ref WNDCLASSEXW lpwcx);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateWindowExW(
            int dwExStyle,
            string lpClassName,
            string lpWindowName,
            int dwStyle,
            int x,
            int y,
            int nWidth,
            int nHeight,
            IntPtr hWndParent,
            IntPtr hMenu,
            IntPtr hInstance,
            IntPtr lpParam);

        [DllImport("user32.dll")]
        public static extern bool DestroyWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern IntPtr DefWindowProcW(IntPtr hWnd, uint uMsg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern void PostQuitMessage(int nExitCode);

        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UpdateLayeredWindow(
            IntPtr hwnd,
            IntPtr hdcDst,
            ref POINT pptDst,
            ref SIZE psize,
            IntPtr hdcSrc,
            ref POINT pptSrc,
            uint crKey,
            ref BLENDFUNCTION pblend,
            uint dwFlags);

        [DllImport("user32.dll")]
        public static extern uint MsgWaitForMultipleObjects(
            uint nCount,
            IntPtr[] pHandles,
            bool fWaitAll,
            uint dwMilliseconds,
            uint dwWakeMask);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern bool PeekMessageW(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

        [DllImport("user32.dll")]
        public static extern bool TranslateMessage(ref MSG lpMsg);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr DispatchMessageW(ref MSG lpMsg);

        [DllImport("user32.dll")]
        public static extern bool PostMessageW(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern IntPtr GetDC(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

        [DllImport("gdi32.dll")]
        public static extern IntPtr CreateCompatibleDC(IntPtr hdc);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteDC(IntPtr hdc);

        [DllImport("gdi32.dll")]
        public static extern IntPtr CreateDIBSection(
            IntPtr hdc,
            ref BITMAPINFOHEADER pbmi,
            uint usage,
            out IntPtr ppvBits,
            IntPtr hSection,
            uint offset);

        [DllImport("gdi32.dll")]
        public static extern IntPtr SelectObject(IntPtr hdc, IntPtr h);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteObject(IntPtr ho);

        [DllImport("dwmapi.dll")]
        public static extern int DwmFlush();

        [DllImport("shell32.dll")]
        public static extern int SHQueryUserNotificationState(out int pquns);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool DestroyIcon(IntPtr hIcon);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SetWindowPos(
            IntPtr hWnd,
            IntPtr hWndInsertAfter,
            int X,
            int Y,
            int cx,
            int cy,
            uint uFlags);

        [DllImport("user32.dll")]
        public static extern short GetAsyncKeyState(int vKey);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        public static void EnablePerMonitorDpi()
        {
            try
            {
                if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return;
            }
            catch
            {
            }
            try
            {
                SetProcessDPIAware();
            }
            catch
            {
            }
        }

        public static uint GetDpiAtPoint(int x, int y)
        {
            try
            {
                POINT pt = new POINT();
                pt.X = x;
                pt.Y = y;
                IntPtr hMon = MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
                if (hMon != IntPtr.Zero)
                {
                    uint dx, dy;
                    if (GetDpiForMonitor(hMon, MDT_EFFECTIVE_DPI, out dx, out dy) == 0 && dx >= 72 && dx <= 480)
                    {
                        return dx;
                    }
                }
            }
            catch
            {
            }
            return 96;
        }

        public static bool IsFullscreenBusy()
        {
            try
            {
                int state;
                if (SHQueryUserNotificationState(out state) == 0)
                {
                    // Only pause for exclusive Direct3D fullscreen games (3 = QUNS_RUNNING_D3D_FULL_SCREEN).
                    // Do NOT pause on QUNS_BUSY (2), which triggers on Windows 11 Focus Assist / multi-monitor desktop apps.
                    return state == 3;
                }
            }
            catch
            {
            }
            return false;
        }
    }

    internal sealed class SampleRingBuffer
    {
        private readonly TrailSample[] _items;
        private readonly object _lock = new object();
        private int _head;
        private int _count;
        private int _lastX;
        private int _lastY;
        private long _lastTicks;
        private int _strokeId;
        private bool _hasLast;

        public SampleRingBuffer(int capacity)
        {
            _items = new TrailSample[capacity];
        }

        public void Push(int x, int y, long ticks)
        {
            lock (_lock)
            {
                if (_hasLast)
                {
                    if (x == _lastX && y == _lastY) return;
                    double dtMs = (ticks - _lastTicks) * 1000.0 / (double)Stopwatch.Frequency;
                    long dx = (long)x - (long)_lastX;
                    long dy = (long)y - (long)_lastY;
                    long distSq = dx * dx + dy * dy;
                    if (distSq < 4L && dtMs < 3.0) return;
                    if (dtMs > 120.0 || distSq > 250000L)
                    {
                        _strokeId++;
                    }
                }
                else
                {
                    _hasLast = true;
                }

                _lastX = x;
                _lastY = y;
                _lastTicks = ticks;

                TrailSample s = new TrailSample();
                s.X = x;
                s.Y = y;
                s.Ticks = ticks;
                s.StrokeId = _strokeId;

                int idx = (_head + _count) % _items.Length;
                if (_count == _items.Length)
                {
                    _items[_head] = s;
                    _head = (_head + 1) % _items.Length;
                }
                else
                {
                    _items[idx] = s;
                    _count++;
                }
            }
        }

        public int CopyActive(long nowTicks, double lifetimeMs, TrailSample[] dest)
        {
            long maxAgeTicks = (long)(lifetimeMs * Stopwatch.Frequency / 1000.0);
            lock (_lock)
            {
                int write = 0;
                for (int i = 0; i < _count && write < dest.Length; i++)
                {
                    TrailSample s = _items[(_head + i) % _items.Length];
                    if ((nowTicks - s.Ticks) <= maxAgeTicks)
                    {
                        dest[write++] = s;
                    }
                }
                return write;
            }
        }

        public void Clear()
        {
            lock (_lock)
            {
                _head = 0;
                _count = 0;
                _hasLast = false;
            }
        }
    }

    internal sealed class ClickRippleBuffer
    {
        private readonly ClickRipple[] _items;
        private readonly object _lock = new object();
        private int _head;
        private int _count;

        public ClickRippleBuffer(int capacity)
        {
            _items = new ClickRipple[capacity];
        }

        public void Push(int x, int y, long ticks, int kind)
        {
            lock (_lock)
            {
                ClickRipple r = new ClickRipple();
                r.X = x;
                r.Y = y;
                r.Ticks = ticks;
                r.Kind = kind;

                int idx = (_head + _count) % _items.Length;
                if (_count == _items.Length)
                {
                    _items[_head] = r;
                    _head = (_head + 1) % _items.Length;
                }
                else
                {
                    _items[idx] = r;
                    _count++;
                }
            }
        }

        public int CopyActive(long nowTicks, double durationMs, ClickRipple[] dest)
        {
            long maxAgeTicks = (long)(durationMs * Stopwatch.Frequency / 1000.0);
            lock (_lock)
            {
                int write = 0;
                for (int i = 0; i < _count && write < dest.Length; i++)
                {
                    ClickRipple r = _items[(_head + i) % _items.Length];
                    long age = nowTicks - r.Ticks;
                    if (age >= 0 && age <= maxAgeTicks)
                    {
                        dest[write++] = r;
                    }
                }
                return write;
            }
        }

        public void Clear()
        {
            lock (_lock)
            {
                _head = 0;
                _count = 0;
            }
        }
    }

    internal sealed class InteractionState
    {
        private const double ShakeWindowMs = 420.0;
        private const double ShakeMinLegPx = 35.0;
        private const double ShakeMinTotalPx = 220.0;
        private const double ShakeBeaconMs = 650.0;
        private const double ShakeCooldownMs = 700.0;
        private const double DragThresholdLogicalPx = 8.0;
        private const double DragFadeInMs = 90.0;
        private const double DragFadeOutMs = 110.0;
        private const double ScrollDurationMs = 190.0;
        private const double ScrollThrottleMs = 45.0;
        private const double PreviewDurationMs = 320.0;

        private readonly object _lock = new object();

        // Shake state
        private int _shakeLastX;
        private long _shakeLastTicks;
        private bool _shakeHasLast;
        private int _legDir;
        private double _legDistLogical;
        private readonly long[] _revTicks = new long[8];
        private readonly double[] _revDist = new double[8];
        private int _revHead;
        private int _revCount;
        private long _shakeStartTicks;
        private long _lastShakeTriggerTicks;

        // Drag state
        private bool _leftDown;
        private int _downX;
        private int _downY;
        private bool _dragActive;
        private long _dragStartTicks;
        private long _dragReleaseTicks;

        // Scroll wheel & palette preview state
        private int _scrollDir;
        private long _scrollStartTicks;
        private long _scrollLastEventTicks;
        private long _previewStartTicks;

        public void OnWheelScroll(int dir, long ticks)
        {
            if (dir == 0) return;
            lock (_lock)
            {
                if (dir == _scrollDir && _scrollLastEventTicks > 0)
                {
                    double dtMs = (double)(ticks - _scrollLastEventTicks) * 1000.0 / (double)Stopwatch.Frequency;
                    if (dtMs >= 0.0 && dtMs < ScrollThrottleMs)
                    {
                        return;
                    }
                }
                _scrollDir = dir;
                _scrollStartTicks = ticks;
                _scrollLastEventTicks = ticks;
            }
        }

        public void TriggerPalettePreview(long ticks)
        {
            lock (_lock)
            {
                _previewStartTicks = ticks;
            }
        }

        public void OnLeftDown(int x, int y, long ticks)
        {
            lock (_lock)
            {
                _leftDown = true;
                _downX = x;
                _downY = y;
                _dragActive = false;
            }
        }

        public void OnLeftUp(long ticks)
        {
            lock (_lock)
            {
                _leftDown = false;
                if (_dragActive)
                {
                    _dragActive = false;
                    _dragReleaseTicks = ticks;
                }
            }
        }

        public bool OnCursorMove(int x, int y, long ticks, uint dpi, bool shakeEnabled, bool dragEnabled)
        {
            bool shakeTriggered = false;
            double logicalScale = 96.0 / (double)dpi;
            double freq = (double)Stopwatch.Frequency;

            lock (_lock)
            {
                if (dragEnabled && _leftDown && !_dragActive)
                {
                    double dx = (double)(x - _downX) * logicalScale;
                    double dy = (double)(y - _downY) * logicalScale;
                    if ((dx * dx + dy * dy) >= (DragThresholdLogicalPx * DragThresholdLogicalPx))
                    {
                        _dragActive = true;
                        _dragStartTicks = ticks;
                    }
                }
                else if (!dragEnabled)
                {
                    _dragActive = false;
                }

                if (!shakeEnabled)
                {
                    _shakeHasLast = false;
                    _legDir = 0;
                    _legDistLogical = 0.0;
                    _revHead = 0;
                    _revCount = 0;
                    return false;
                }

                if (!_shakeHasLast)
                {
                    _shakeHasLast = true;
                    _shakeLastX = x;
                    _shakeLastTicks = ticks;
                    return false;
                }

                double dtMs = (double)(ticks - _shakeLastTicks) * 1000.0 / freq;
                if (dtMs > 180.0 || dtMs < 0.0)
                {
                    _shakeLastX = x;
                    _shakeLastTicks = ticks;
                    _legDir = 0;
                    _legDistLogical = 0.0;
                    _revHead = 0;
                    _revCount = 0;
                    return false;
                }

                double stepX = (double)(x - _shakeLastX) * logicalScale;
                _shakeLastX = x;
                _shakeLastTicks = ticks;

                if (Math.Abs(stepX) < 0.5)
                {
                    return false;
                }

                int dir = stepX > 0.0 ? 1 : -1;
                double absStep = Math.Abs(stepX);

                if (_legDir == 0)
                {
                    _legDir = dir;
                    _legDistLogical = absStep;
                }
                else if (dir == _legDir)
                {
                    _legDistLogical += absStep;
                }
                else
                {
                    if (_legDistLogical >= ShakeMinLegPx)
                    {
                        PushReversal(ticks, _legDistLogical);
                    }
                    _legDir = dir;
                    _legDistLogical = absStep;
                }

                PruneOldReversals(ticks, freq);
                if (_revCount >= 3)
                {
                    double totalTravel = _legDistLogical;
                    for (int i = 0; i < _revCount; i++)
                    {
                        totalTravel += _revDist[(_revHead + i) % _revDist.Length];
                    }

                    if (totalTravel >= ShakeMinTotalPx)
                    {
                        double sinceLastMs = _lastShakeTriggerTicks == 0
                            ? ShakeCooldownMs + 1.0
                            : (double)(ticks - _lastShakeTriggerTicks) * 1000.0 / freq;
                        if (sinceLastMs >= ShakeCooldownMs)
                        {
                            _shakeStartTicks = ticks;
                            _lastShakeTriggerTicks = ticks;
                            _revHead = 0;
                            _revCount = 0;
                            _legDir = 0;
                            _legDistLogical = 0.0;
                            shakeTriggered = true;
                        }
                    }
                }
            }

            return shakeTriggered;
        }

        private void PushReversal(long ticks, double legDist)
        {
            int idx = (_revHead + _revCount) % _revTicks.Length;
            if (_revCount == _revTicks.Length)
            {
                _revTicks[_revHead] = ticks;
                _revDist[_revHead] = legDist;
                _revHead = (_revHead + 1) % _revTicks.Length;
            }
            else
            {
                _revTicks[idx] = ticks;
                _revDist[idx] = legDist;
                _revCount++;
            }
        }

        private void PruneOldReversals(long nowTicks, double freq)
        {
            long maxAge = (long)(ShakeWindowMs * freq / 1000.0);
            while (_revCount > 0 && (nowTicks - _revTicks[_revHead]) > maxAge)
            {
                _revHead = (_revHead + 1) % _revTicks.Length;
                _revCount--;
            }
        }

        public void SampleVisualState(
            long nowTicks,
            bool leftKeyStillDown,
            bool shakeEnabled,
            bool dragEnabled,
            bool scrollEnabled,
            out float shakeProgress,
            out float dragAlpha,
            out float dragPhaseSec,
            out int scrollDir,
            out float scrollProgress,
            out float previewProgress)
        {
            shakeProgress = -1.0f;
            dragAlpha = 0.0f;
            dragPhaseSec = 0.0f;
            scrollDir = 0;
            scrollProgress = -1.0f;
            previewProgress = -1.0f;
            double freq = (double)Stopwatch.Frequency;

            lock (_lock)
            {
                if (_leftDown && !leftKeyStillDown)
                {
                    _leftDown = false;
                    if (_dragActive)
                    {
                        _dragActive = false;
                        _dragReleaseTicks = nowTicks;
                    }
                }

                if (shakeEnabled && _shakeStartTicks > 0)
                {
                    double ageMs = (double)(nowTicks - _shakeStartTicks) * 1000.0 / freq;
                    if (ageMs >= 0.0 && ageMs < ShakeBeaconMs)
                    {
                        shakeProgress = (float)(ageMs / ShakeBeaconMs);
                    }
                    else
                    {
                        _shakeStartTicks = 0;
                    }
                }

                if (dragEnabled)
                {
                    if (_dragActive)
                    {
                        double activeMs = (double)(nowTicks - _dragStartTicks) * 1000.0 / freq;
                        if (activeMs < 0.0) activeMs = 0.0;
                        double t = activeMs / DragFadeInMs;
                        if (t > 1.0) t = 1.0;
                        dragAlpha = (float)(t * t * (3.0 - 2.0 * t));
                        dragPhaseSec = (float)(activeMs / 1000.0);
                    }
                    else if (_dragReleaseTicks > 0)
                    {
                        double relMs = (double)(nowTicks - _dragReleaseTicks) * 1000.0 / freq;
                        if (relMs >= 0.0 && relMs < DragFadeOutMs)
                        {
                            double inv = 1.0 - relMs / DragFadeOutMs;
                            dragAlpha = (float)(inv * inv);
                            dragPhaseSec = (float)((double)(nowTicks - _dragStartTicks) * 1000.0 / freq / 1000.0);
                        }
                        else
                        {
                            _dragReleaseTicks = 0;
                        }
                    }
                }

                if (scrollEnabled && _scrollStartTicks > 0)
                {
                    double scrollAgeMs = (double)(nowTicks - _scrollStartTicks) * 1000.0 / freq;
                    if (scrollAgeMs >= 0.0 && scrollAgeMs < ScrollDurationMs)
                    {
                        scrollDir = _scrollDir;
                        scrollProgress = (float)(scrollAgeMs / ScrollDurationMs);
                    }
                    else
                    {
                        _scrollStartTicks = 0;
                    }
                }

                if (_previewStartTicks > 0)
                {
                    double previewAgeMs = (double)(nowTicks - _previewStartTicks) * 1000.0 / freq;
                    if (previewAgeMs >= 0.0 && previewAgeMs < PreviewDurationMs)
                    {
                        previewProgress = (float)(previewAgeMs / PreviewDurationMs);
                    }
                    else
                    {
                        _previewStartTicks = 0;
                    }
                }
            }
        }

        public void Clear()
        {
            lock (_lock)
            {
                _shakeHasLast = false;
                _legDir = 0;
                _legDistLogical = 0.0;
                _revHead = 0;
                _revCount = 0;
                _shakeStartTicks = 0;
                _leftDown = false;
                _dragActive = false;
                _dragReleaseTicks = 0;
                _scrollDir = 0;
                _scrollStartTicks = 0;
                _scrollLastEventTicks = 0;
                _previewStartTicks = 0;
            }
        }
    }

    internal sealed class TrailRenderer : IDisposable
    {
        private IntPtr _memDC;
        private IntPtr _dibBitmap;
        private IntPtr _oldBitmap;
        private IntPtr _dibBits;
        private int _dibWidth;
        private int _dibHeight;

        private float[] _haloBuf = new float[0];
        private float[] _coreBuf = new float[0];
        private float[] _colorBuf = new float[0];
        private readonly List<SplineNode> _strokeNodes = new List<SplineNode>(256);
        private readonly List<SplineNode> _subdivNodes = new List<SplineNode>(1024);

        public int DibWidth { get { return _dibWidth; } }
        public int DibHeight { get { return _dibHeight; } }
        public IntPtr MemDC { get { return _memDC; } }
        public IntPtr DibBits { get { return _dibBits; } }

        public bool RenderFrame(
            TrailSample[] samples,
            int sampleCount,
            bool trailEnabled,
            ClickRipple[] ripples,
            int rippleCount,
            bool rippleEnabled,
            int cursorX,
            int cursorY,
            float shakeProgress,
            float dragAlpha,
            float dragPhaseSec,
            int scrollDir,
            float scrollProgress,
            float previewProgress,
            long nowTicks,
            uint dpi,
            TrailPreset preset,
            ColorPalette palette,
            out int outX,
            out int outY,
            out int outW,
            out int outH)
        {
            outX = 0;
            outY = 0;
            outW = 0;
            outH = 0;

            float scale = dpi / 96.0f;
            float baseCoreR = preset.CoreRadius * scale;
            float baseHaloR = preset.HaloRadius * scale;
            float trailPad = (float)Math.Ceiling(baseHaloR) + 2.0f;

            float bMinX = float.MaxValue;
            float bMinY = float.MaxValue;
            float bMaxX = float.MinValue;
            float bMaxY = float.MinValue;

            bool hasTrail = false;
            _subdivNodes.Clear();
            double freq = (double)Stopwatch.Frequency;

            if (trailEnabled && samples != null && sampleCount >= 2)
            {
                float minX = float.MaxValue;
                float minY = float.MaxValue;
                float maxX = float.MinValue;
                float maxY = float.MinValue;

                int start = 0;
                while (start < sampleCount)
                {
                    int end = start + 1;
                    int strokeId = samples[start].StrokeId;
                    while (end < sampleCount && samples[end].StrokeId == strokeId)
                    {
                        long dx = (long)samples[end].X - (long)samples[end - 1].X;
                        long dy = (long)samples[end].Y - (long)samples[end - 1].Y;
                        double dtMs = (samples[end].Ticks - samples[end - 1].Ticks) * 1000.0 / freq;
                        if (dtMs > 120.0 || (dx * dx + dy * dy) > 250000L) break;
                        end++;
                    }

                    int len = end - start;
                    if (len >= 2)
                    {
                        BuildStrokeNodes(samples, start, len, nowTicks, preset.LifetimeMs, dpi);
                        if (_strokeNodes.Count >= 2)
                        {
                            int before = _subdivNodes.Count;
                            SubdivideCentripetalCatmullRom(_strokeNodes, _subdivNodes);
                            for (int i = before; i < _subdivNodes.Count; i++)
                            {
                                SplineNode n = _subdivNodes[i];
                                if (n.Env < 0.0f) continue;
                                if (n.X < minX) minX = n.X;
                                if (n.Y < minY) minY = n.Y;
                                if (n.X > maxX) maxX = n.X;
                                if (n.Y > maxY) maxY = n.Y;
                            }
                        }
                    }
                    start = end;
                }

                if (_subdivNodes.Count >= 2 && maxX >= minX)
                {
                    for (int i = 0; i < _subdivNodes.Count; i++)
                    {
                        if (_subdivNodes[i].Env > 0.01f && _subdivNodes[i].U > 0.01f)
                        {
                            hasTrail = true;
                            break;
                        }
                    }
                    if (hasTrail)
                    {
                        if (minX - trailPad < bMinX) bMinX = minX - trailPad;
                        if (minY - trailPad < bMinY) bMinY = minY - trailPad;
                        if (maxX + trailPad > bMaxX) bMaxX = maxX + trailPad;
                        if (maxY + trailPad > bMaxY) bMaxY = maxY + trailPad;
                    }
                }
            }

            bool hasAnyRipple = false;
            if (rippleEnabled && ripples != null && rippleCount > 0)
            {
                for (int i = 0; i < rippleCount; i++)
                {
                    double ageMs = (double)(nowTicks - ripples[i].Ticks) * 1000.0 / freq;
                    float p = (float)(ageMs / (double)preset.RippleDurationMs);
                    if (p < 0.0f || p >= 1.0f) continue;

                    float invP = 1.0f - p;
                    float ease = 1.0f - invP * invP * invP;
                    float rOuter = (4.0f + (preset.RippleMaxRadius - 4.0f) * ease) * scale;
                    float ringHaloW = (7.0f - 1.5f * p) * scale;
                    float reach = rOuter + ringHaloW + 2.0f;
                    float rx = (float)ripples[i].X;
                    float ry = (float)ripples[i].Y;

                    if (rx - reach < bMinX) bMinX = rx - reach;
                    if (ry - reach < bMinY) bMinY = ry - reach;
                    if (rx + reach > bMaxX) bMaxX = rx + reach;
                    if (ry + reach > bMaxY) bMaxY = ry + reach;
                    hasAnyRipple = true;
                }
            }

            bool hasShake = (shakeProgress >= 0.0f && shakeProgress < 1.0f);
            if (hasShake)
            {
                float shakeReach = 60.0f * scale;
                float sx = (float)cursorX;
                float sy = (float)cursorY;
                if (sx - shakeReach < bMinX) bMinX = sx - shakeReach;
                if (sy - shakeReach < bMinY) bMinY = sy - shakeReach;
                if (sx + shakeReach > bMaxX) bMaxX = sx + shakeReach;
                if (sy + shakeReach > bMaxY) bMaxY = sy + shakeReach;
            }

            bool hasDrag = (dragAlpha > 0.005f);
            if (hasDrag)
            {
                float dragReach = 24.0f * scale;
                float dx = (float)cursorX;
                float dy = (float)cursorY;
                if (dx - dragReach < bMinX) bMinX = dx - dragReach;
                if (dy - dragReach < bMinY) bMinY = dy - dragReach;
                if (dx + dragReach > bMaxX) bMaxX = dx + dragReach;
                if (dy + dragReach > bMaxY) bMaxY = dy + dragReach;
            }

            bool hasScroll = (scrollDir != 0 && scrollProgress >= 0.0f && scrollProgress < 1.0f);
            if (hasScroll)
            {
                float scrollReach = 28.0f * scale;
                float sx = (float)cursorX;
                float sy = (float)cursorY;
                if (sx - scrollReach < bMinX) bMinX = sx - scrollReach;
                if (sy - scrollReach < bMinY) bMinY = sy - scrollReach;
                if (sx + scrollReach > bMaxX) bMaxX = sx + scrollReach;
                if (sy + scrollReach > bMaxY) bMaxY = sy + scrollReach;
            }

            bool hasPreview = (previewProgress >= 0.0f && previewProgress < 1.0f);
            if (hasPreview)
            {
                float prevReach = 36.0f * scale;
                float px = (float)cursorX;
                float py = (float)cursorY;
                if (px - prevReach < bMinX) bMinX = px - prevReach;
                if (py - prevReach < bMinY) bMinY = py - prevReach;
                if (px + prevReach > bMaxX) bMaxX = px + prevReach;
                if (py + prevReach > bMaxY) bMaxY = py + prevReach;
            }

            if (!hasTrail && !hasAnyRipple && !hasShake && !hasDrag && !hasScroll && !hasPreview) return false;

            outX = (int)Math.Floor(bMinX);
            outY = (int)Math.Floor(bMinY);
            int right = (int)Math.Ceiling(bMaxX);
            int bottom = (int)Math.Ceiling(bMaxY);
            outW = right - outX;
            outH = bottom - outY;

            if (outW <= 0 || outH <= 0) return false;
            if (outW > 4096) outW = 4096;
            if (outH > 4096) outH = 4096;

            EnsureBuffers(outW, outH);
            EnsureDib(outW, outH);
            if (_dibBits == IntPtr.Zero) return false;

            bool trackColor = (palette.Mode != PaletteMode.Solid);
            if (hasTrail)
            {
                AccumulateSdf(outX, outY, outW, outH, baseCoreR, baseHaloR, trackColor);
            }
            if (hasAnyRipple)
            {
                AccumulateRipples(outX, outY, outW, outH, ripples, rippleCount, nowTicks, scale, preset, trackColor);
            }
            if (hasShake)
            {
                AccumulateShakeBeacon(outX, outY, outW, outH, cursorX, cursorY, shakeProgress, scale, trackColor);
            }
            if (hasDrag)
            {
                AccumulateDragGlow(outX, outY, outW, outH, cursorX, cursorY, dragAlpha, dragPhaseSec, scale, trackColor);
            }
            if (hasScroll)
            {
                AccumulateScrollArc(outX, outY, outW, outH, cursorX, cursorY, scrollDir, scrollProgress, scale, trackColor);
            }
            if (hasPreview)
            {
                AccumulatePalettePreview(outX, outY, outW, outH, cursorX, cursorY, previewProgress, scale, trackColor);
            }
            float timeSec = (float)((double)(nowTicks % (Stopwatch.Frequency * 3600L)) / (double)Stopwatch.Frequency);
            int nonZero = CompositePremultiplied(outW, outH, preset, palette, timeSec);
            return nonZero > 0;
        }

        private void BuildStrokeNodes(TrailSample[] samples, int start, int len, long nowTicks, float lifetimeMs, uint dpi)
        {
            _strokeNodes.Clear();
            double freq = (double)Stopwatch.Frequency;
            double logicalScale = 96.0 / (double)dpi;
            double smoothedSpeed = 0.0;

            for (int i = 0; i < len; i++)
            {
                TrailSample cur = samples[start + i];
                if (i > 0)
                {
                    TrailSample prev = samples[start + i - 1];
                    double dx = (double)(cur.X - prev.X);
                    double dy = (double)(cur.Y - prev.Y);
                    double dist = Math.Sqrt(dx * dx + dy * dy);
                    if (dist < 0.5 && i < len - 1) continue;

                    double dtSec = (double)(cur.Ticks - prev.Ticks) / freq;
                    if (dtSec > 0.0001)
                    {
                        double speed = (dist * logicalScale) / dtSec;
                        double alpha = speed > smoothedSpeed ? 0.55 : 0.25;
                        smoothedSpeed = smoothedSpeed + (speed - smoothedSpeed) * alpha;
                    }
                }

                double ageMs = (double)(nowTicks - cur.Ticks) * 1000.0 / freq;
                float u = (float)(1.0 - ageMs / (double)lifetimeMs);
                if (u < 0.0f) u = 0.0f;
                if (u > 1.0f) u = 1.0f;

                float env = SmoothStep(20.0f, 280.0f, (float)smoothedSpeed);
                if (i == 0 && len > 1)
                {
                    // Peek forward so the stroke start inherits initial motion energy cleanly
                    TrailSample next = samples[start + 1];
                    double ndx = (double)(next.X - cur.X);
                    double ndy = (double)(next.Y - cur.Y);
                    double ndt = (double)(next.Ticks - cur.Ticks) / freq;
                    if (ndt > 0.0001)
                    {
                        double nSpeed = (Math.Sqrt(ndx * ndx + ndy * ndy) * logicalScale) / ndt;
                        env = SmoothStep(20.0f, 280.0f, (float)(nSpeed * 0.55));
                        smoothedSpeed = nSpeed * 0.55;
                    }
                }

                SplineNode node = new SplineNode();
                node.X = (float)cur.X;
                node.Y = (float)cur.Y;
                node.U = u;
                node.Env = env;
                _strokeNodes.Add(node);
            }
        }

        private static void SubdivideCentripetalCatmullRom(List<SplineNode> pts, List<SplineNode> output)
        {
            int n = pts.Count;
            if (n < 2) return;

            for (int i = 0; i < n - 1; i++)
            {
                SplineNode p0 = i > 0 ? pts[i - 1] : MirrorStart(pts[0], pts[1]);
                SplineNode p1 = pts[i];
                SplineNode p2 = pts[i + 1];
                SplineNode p3 = (i + 2 < n) ? pts[i + 2] : MirrorEnd(pts[n - 2], pts[n - 1]);

                float dx = p2.X - p1.X;
                float dy = p2.Y - p1.Y;
                float segLen = (float)Math.Sqrt(dx * dx + dy * dy);
                int steps = (int)Math.Ceiling(segLen / 4.0f);
                if (steps < 1) steps = 1;
                if (steps > 16) steps = 16;

                float t0 = 0.0f;
                float t1 = t0 + CentripetalStep(p0, p1);
                float t2 = t1 + CentripetalStep(p1, p2);
                float t3 = t2 + CentripetalStep(p2, p3);

                if (i == 0)
                {
                    output.Add(p1);
                }

                for (int s = 1; s <= steps; s++)
                {
                    float frac = (float)s / (float)steps;
                    float t = t1 + (t2 - t1) * frac;

                    float a1x = ((t1 - t) * p0.X + (t - t0) * p1.X) / (t1 - t0);
                    float a1y = ((t1 - t) * p0.Y + (t - t0) * p1.Y) / (t1 - t0);
                    float a2x = ((t2 - t) * p1.X + (t - t1) * p2.X) / (t2 - t1);
                    float a2y = ((t2 - t) * p1.Y + (t - t1) * p2.Y) / (t2 - t1);
                    float a3x = ((t3 - t) * p2.X + (t - t2) * p3.X) / (t3 - t2);
                    float a3y = ((t3 - t) * p2.Y + (t - t2) * p3.Y) / (t3 - t2);

                    float b1x = ((t2 - t) * a1x + (t - t0) * a2x) / (t2 - t0);
                    float b1y = ((t2 - t) * a1y + (t - t0) * a2y) / (t2 - t0);
                    float b2x = ((t3 - t) * a2x + (t - t1) * a3x) / (t3 - t1);
                    float b2y = ((t3 - t) * a2y + (t - t1) * a3y) / (t3 - t1);

                    float cx = ((t2 - t) * b1x + (t - t1) * b2x) / (t2 - t1);
                    float cy = ((t2 - t) * b1y + (t - t1) * b2y) / (t2 - t1);

                    SplineNode sn = new SplineNode();
                    sn.X = cx;
                    sn.Y = cy;
                    sn.U = p1.U + (p2.U - p1.U) * frac;
                    sn.Env = p1.Env + (p2.Env - p1.Env) * frac;
                    output.Add(sn);
                }
            }

            // Sentinel marker with Env = -1 to separate distinct strokes inside _subdivNodes
            SplineNode sep = new SplineNode();
            sep.Env = -1.0f;
            output.Add(sep);
        }

        private static float CentripetalStep(SplineNode a, SplineNode b)
        {
            float dx = b.X - a.X;
            float dy = b.Y - a.Y;
            float d2 = dx * dx + dy * dy;
            if (d2 < 0.0001f) return 0.1f;
            float step = (float)Math.Pow(d2, 0.25);
            return step < 0.05f ? 0.05f : step;
        }

        private static SplineNode MirrorStart(SplineNode a, SplineNode b)
        {
            SplineNode m = new SplineNode();
            m.X = 2.0f * a.X - b.X;
            m.Y = 2.0f * a.Y - b.Y;
            m.U = a.U;
            m.Env = a.Env;
            return m;
        }

        private static SplineNode MirrorEnd(SplineNode a, SplineNode b)
        {
            SplineNode m = new SplineNode();
            m.X = 2.0f * b.X - a.X;
            m.Y = 2.0f * b.Y - a.Y;
            m.U = b.U;
            m.Env = b.Env;
            return m;
        }

        private static float SmoothStep(float edge0, float edge1, float x)
        {
            if (x <= edge0) return 0.0f;
            if (x >= edge1) return 1.0f;
            float t = (x - edge0) / (edge1 - edge0);
            return t * t * (3.0f - 2.0f * t);
        }

        private void EnsureBuffers(int w, int h)
        {
            int needed = w * h;
            if (_haloBuf.Length < needed)
            {
                int newCap = Math.Max(needed, 65536);
                _haloBuf = new float[newCap];
                _coreBuf = new float[newCap];
                _colorBuf = new float[newCap];
            }
        }

        private void EnsureDib(int w, int h)
        {
            if (_memDC != IntPtr.Zero && w <= _dibWidth && h <= _dibHeight)
            {
                return;
            }

            int newW = Math.Max(w, _dibWidth);
            int newH = Math.Max(h, _dibHeight);
            if (newW < 256) newW = 256;
            if (newH < 256) newH = 256;

            DisposeDibOnly();

            IntPtr screenDC = NativeMethods.GetDC(IntPtr.Zero);
            _memDC = NativeMethods.CreateCompatibleDC(screenDC);
            NativeMethods.ReleaseDC(IntPtr.Zero, screenDC);

            NativeMethods.BITMAPINFOHEADER bmi = new NativeMethods.BITMAPINFOHEADER();
            bmi.biSize = (uint)Marshal.SizeOf(typeof(NativeMethods.BITMAPINFOHEADER));
            bmi.biWidth = newW;
            bmi.biHeight = -newH; // top-down DIB
            bmi.biPlanes = 1;
            bmi.biBitCount = 32;
            bmi.biCompression = 0; // BI_RGB

            _dibBitmap = NativeMethods.CreateDIBSection(_memDC, ref bmi, 0, out _dibBits, IntPtr.Zero, 0);
            if (_dibBitmap != IntPtr.Zero)
            {
                _oldBitmap = NativeMethods.SelectObject(_memDC, _dibBitmap);
                _dibWidth = newW;
                _dibHeight = newH;
            }
        }

        private unsafe void AccumulateSdf(int originX, int originY, int bboxW, int bboxH, float baseCoreR, float baseHaloR, bool trackColor)
        {
            fixed (float* pHalo = _haloBuf)
            fixed (float* pCore = _coreBuf)
            fixed (float* pColor = _colorBuf)
            {
                int count = _subdivNodes.Count;
                for (int i = 0; i < count - 1; i++)
                {
                    SplineNode a = _subdivNodes[i];
                    SplineNode b = _subdivNodes[i + 1];
                    if (a.Env < 0.0f || b.Env < 0.0f) continue;

                    float maxEnv = a.Env > b.Env ? a.Env : b.Env;
                    float maxU = a.U > b.U ? a.U : b.U;
                    if (maxEnv <= 0.005f || maxU <= 0.005f) continue;

                    float ax = a.X - originX;
                    float ay = a.Y - originY;
                    float bx = b.X - originX;
                    float by = b.Y - originY;

                    float abx = bx - ax;
                    float aby = by - ay;
                    float abLenSq = abx * abx + aby * aby;

                    float segMaxHaloR = baseHaloR * (0.45f + 0.55f * maxU);
                    int rPad = (int)Math.Ceiling(segMaxHaloR) + 1;

                    int x0 = (int)Math.Floor(ax < bx ? ax : bx) - rPad;
                    int y0 = (int)Math.Floor(ay < by ? ay : by) - rPad;
                    int x1 = (int)Math.Ceiling(ax > bx ? ax : bx) + rPad;
                    int y1 = (int)Math.Ceiling(ay > by ? ay : by) + rPad;

                    if (x0 < 0) x0 = 0;
                    if (y0 < 0) y0 = 0;
                    if (x1 >= bboxW) x1 = bboxW - 1;
                    if (y1 >= bboxH) y1 = bboxH - 1;

                    for (int py = y0; py <= y1; py++)
                    {
                        float pyC = py + 0.5f;
                        int rowOffset = py * bboxW;
                        for (int px = x0; px <= x1; px++)
                        {
                            float pxC = px + 0.5f;
                            float t = 0.0f;
                            if (abLenSq > 0.0001f)
                            {
                                t = ((pxC - ax) * abx + (pyC - ay) * aby) / abLenSq;
                                if (t < 0.0f) t = 0.0f;
                                else if (t > 1.0f) t = 1.0f;
                            }

                            float u = a.U + (b.U - a.U) * t;
                            if (u <= 0.005f) continue;
                            float env = a.Env + (b.Env - a.Env) * t;
                            if (env <= 0.005f) continue;

                            float localHaloR = baseHaloR * (0.45f + 0.55f * u);
                            float dx = pxC - (ax + t * abx);
                            float dy = pyC - (ay + t * aby);
                            float distSq = dx * dx + dy * dy;
                            if (distSq >= localHaloR * localHaloR) continue;

                            float dist = (float)Math.Sqrt(distSq);
                            float nh = 1.0f - dist / localHaloR;
                            float u2 = u * u;
                            float hVal = nh * nh * nh * u2 * env;

                            int idx = rowOffset + px;
                            if (hVal > pHalo[idx])
                            {
                                pHalo[idx] = hVal;
                                if (trackColor) pColor[idx] = u * 0.55f;
                            }

                            float localCoreR = baseCoreR * (0.35f + 0.65f * u);
                            if (dist < localCoreR)
                            {
                                float nc = 1.0f - dist / localCoreR;
                                float uCore = u * (float)Math.Sqrt(u); // ~u^1.5, close to u^1.35 and faster
                                float cVal = (nc * nc * (3.0f - 2.0f * nc)) * uCore * env;
                                if (cVal > pCore[idx]) pCore[idx] = cVal;
                            }
                        }
                    }
                }
            }
        }

        private unsafe void AccumulateRipples(
            int originX,
            int originY,
            int bboxW,
            int bboxH,
            ClickRipple[] ripples,
            int rippleCount,
            long nowTicks,
            float scale,
            TrailPreset preset,
            bool trackColor)
        {
            double freq = (double)Stopwatch.Frequency;
            fixed (float* pHalo = _haloBuf)
            fixed (float* pCore = _coreBuf)
            fixed (float* pColor = _colorBuf)
            {
                for (int i = 0; i < rippleCount; i++)
                {
                    ClickRipple rp = ripples[i];
                    double ageMs = (double)(nowTicks - rp.Ticks) * 1000.0 / freq;
                    float p = (float)(ageMs / (double)preset.RippleDurationMs);
                    if (p < 0.0f || p >= 1.0f) continue;

                    float invP = 1.0f - p;
                    float ease = 1.0f - invP * invP * invP;
                    float rOuter = (4.0f + (preset.RippleMaxRadius - 4.0f) * ease) * scale;
                    float ringCoreW = (1.9f - 0.6f * p) * scale;
                    float ringHaloW = (7.0f - 1.5f * p) * scale;
                    float fade = invP * invP * preset.RippleBoost;

                    bool hasInner = (rp.Kind == 1) && (p > 0.08f);
                    float rInner = 0.0f;
                    float ringCoreW2 = 0.0f;
                    float ringHaloW2 = 0.0f;
                    float fade2 = 0.0f;
                    if (hasInner)
                    {
                        float p2 = (p - 0.08f) / 0.92f;
                        float invP2 = 1.0f - p2;
                        float ease2 = 1.0f - invP2 * invP2 * invP2;
                        rInner = (3.0f + (preset.RippleMaxRadius * 0.62f - 3.0f) * ease2) * scale;
                        ringCoreW2 = (1.6f - 0.5f * p2) * scale;
                        ringHaloW2 = (5.5f - 1.2f * p2) * scale;
                        fade2 = invP2 * invP2 * 0.85f * preset.RippleBoost;
                    }

                    bool hasFlash = p < 0.35f;
                    float flashR = 0.0f;
                    float flashCoreR = 0.0f;
                    float flashFade = 0.0f;
                    if (hasFlash)
                    {
                        float pf = 1.0f - p / 0.35f;
                        flashR = 8.0f * (0.6f + 0.4f * ease) * scale;
                        flashCoreR = 3.2f * (0.6f + 0.4f * ease) * scale;
                        flashFade = pf * pf * preset.RippleBoost;
                    }

                    float rx = (float)(rp.X - originX);
                    float ry = (float)(rp.Y - originY);
                    float reach = rOuter + ringHaloW + 1.0f;

                    int x0 = (int)Math.Floor(rx - reach);
                    int y0 = (int)Math.Floor(ry - reach);
                    int x1 = (int)Math.Ceiling(rx + reach);
                    int y1 = (int)Math.Ceiling(ry + reach);

                    if (x0 < 0) x0 = 0;
                    if (y0 < 0) y0 = 0;
                    if (x1 >= bboxW) x1 = bboxW - 1;
                    if (y1 >= bboxH) y1 = bboxH - 1;

                    for (int py = y0; py <= y1; py++)
                    {
                        float dy = (py + 0.5f) - ry;
                        float dy2 = dy * dy;
                        int rowOffset = py * bboxW;
                        for (int px = x0; px <= x1; px++)
                        {
                            float dx = (px + 0.5f) - rx;
                            float dist = (float)Math.Sqrt(dx * dx + dy2);
                            int idx = rowOffset + px;
                            bool updated = false;
                            bool useInnerOffset = false;

                            float d1 = dist - rOuter;
                            if (d1 < 0.0f) d1 = -d1;
                            if (d1 < ringHaloW)
                            {
                                float nh = 1.0f - d1 / ringHaloW;
                                float hVal = nh * nh * nh * fade;
                                if (hVal > pHalo[idx])
                                {
                                    pHalo[idx] = hVal;
                                    updated = true;
                                }

                                if (d1 < ringCoreW)
                                {
                                    float nc = 1.0f - d1 / ringCoreW;
                                    float cVal = (nc * nc * (3.0f - 2.0f * nc)) * fade;
                                    if (cVal > pCore[idx]) pCore[idx] = cVal;
                                }
                            }

                            if (hasInner)
                            {
                                float d2 = dist - rInner;
                                if (d2 < 0.0f) d2 = -d2;
                                if (d2 < ringHaloW2)
                                {
                                    float nh2 = 1.0f - d2 / ringHaloW2;
                                    float hVal2 = nh2 * nh2 * nh2 * fade2;
                                    if (hVal2 > pHalo[idx])
                                    {
                                        pHalo[idx] = hVal2;
                                        updated = true;
                                        useInnerOffset = true;
                                    }

                                    if (d2 < ringCoreW2)
                                    {
                                        float nc2 = 1.0f - d2 / ringCoreW2;
                                        float cVal2 = (nc2 * nc2 * (3.0f - 2.0f * nc2)) * fade2;
                                        if (cVal2 > pCore[idx]) pCore[idx] = cVal2;
                                    }
                                }
                            }

                            if (hasFlash && dist < flashR)
                            {
                                float nf = 1.0f - dist / flashR;
                                float fhVal = nf * nf * nf * flashFade * 0.85f;
                                if (fhVal > pHalo[idx])
                                {
                                    pHalo[idx] = fhVal;
                                    updated = true;
                                    useInnerOffset = false;
                                }

                                if (dist < flashCoreR)
                                {
                                    float nfc = 1.0f - dist / flashCoreR;
                                    float fcVal = (nfc * nfc * (3.0f - 2.0f * nfc)) * flashFade * 0.90f;
                                    if (fcVal > pCore[idx]) pCore[idx] = fcVal;
                                }
                            }

                            if (trackColor && updated)
                            {
                                float ap = (float)(Math.Atan2((double)dy, (double)dx) * (1.0 / (2.0 * Math.PI)) + 0.5);
                                if (useInnerOffset) ap += 0.5f;
                                pColor[idx] = ap;
                            }
                        }
                    }
                }
            }
        }

        private unsafe void AccumulateShakeBeacon(
            int originX,
            int originY,
            int bboxW,
            int bboxH,
            int cursorX,
            int cursorY,
            float progress,
            float scale,
            bool trackColor)
        {
            float fadeIn = SmoothStep(0.0f, 0.14f, progress);
            float inv = 1.0f - progress;
            float fadeOut = inv * inv;
            float alphaEnv = fadeIn * fadeOut * 1.15f;
            if (alphaEnv <= 0.005f) return;

            float easeOut = 1.0f - inv * inv * inv;
            float pulse = (float)Math.Sin((double)progress * Math.PI * 3.0);
            float ringR = (26.0f + 16.0f * easeOut + 3.5f * pulse) * scale;
            float ringHaloW = 10.5f * scale;
            float ringCoreW = 2.8f * scale;
            float auraR = ringR * 0.72f;

            float cx = (float)(cursorX - originX);
            float cy = (float)(cursorY - originY);
            float reach = ringR + ringHaloW + 1.0f;

            int x0 = (int)Math.Floor(cx - reach);
            int y0 = (int)Math.Floor(cy - reach);
            int x1 = (int)Math.Ceiling(cx + reach);
            int y1 = (int)Math.Ceiling(cy + reach);

            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 >= bboxW) x1 = bboxW - 1;
            if (y1 >= bboxH) y1 = bboxH - 1;

            fixed (float* pHalo = _haloBuf)
            fixed (float* pCore = _coreBuf)
            fixed (float* pColor = _colorBuf)
            {
                for (int py = y0; py <= y1; py++)
                {
                    float dy = (py + 0.5f) - cy;
                    float dy2 = dy * dy;
                    int rowOffset = py * bboxW;
                    for (int px = x0; px <= x1; px++)
                    {
                        float dx = (px + 0.5f) - cx;
                        float dist = (float)Math.Sqrt(dx * dx + dy2);
                        int idx = rowOffset + px;
                        bool updated = false;

                        float dRing = dist - ringR;
                        if (dRing < 0.0f) dRing = -dRing;
                        if (dRing < ringHaloW)
                        {
                            float nh = 1.0f - dRing / ringHaloW;
                            float hVal = nh * nh * nh * alphaEnv;
                            if (hVal > pHalo[idx])
                            {
                                pHalo[idx] = hVal;
                                updated = true;
                            }

                            if (dRing < ringCoreW)
                            {
                                float nc = 1.0f - dRing / ringCoreW;
                                float cVal = (nc * nc * (3.0f - 2.0f * nc)) * alphaEnv;
                                if (cVal > pCore[idx]) pCore[idx] = cVal;
                            }
                        }

                        if (dist < auraR)
                        {
                            float na = 1.0f - dist / auraR;
                            float auraVal = na * na * alphaEnv * 0.24f;
                            if (auraVal > pHalo[idx])
                            {
                                pHalo[idx] = auraVal;
                                updated = true;
                            }
                        }

                        if (trackColor && updated)
                        {
                            pColor[idx] = (float)(Math.Atan2((double)dy, (double)dx) * (1.0 / (2.0 * Math.PI)) + 0.5);
                        }
                    }
                }
            }
        }

        private unsafe void AccumulateDragGlow(
            int originX,
            int originY,
            int bboxW,
            int bboxH,
            int cursorX,
            int cursorY,
            float dragAlpha,
            float phaseSec,
            float scale,
            bool trackColor)
        {
            float breath = 0.86f + 0.14f * (float)Math.Sin((double)phaseSec * 6.0);
            float haloR = 15.5f * scale * breath;
            float coreR = 5.5f * scale * breath;

            float cx = (float)(cursorX - originX);
            float cy = (float)(cursorY - originY);
            float reach = haloR + 1.0f;

            int x0 = (int)Math.Floor(cx - reach);
            int y0 = (int)Math.Floor(cy - reach);
            int x1 = (int)Math.Ceiling(cx + reach);
            int y1 = (int)Math.Ceiling(cy + reach);

            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 >= bboxW) x1 = bboxW - 1;
            if (y1 >= bboxH) y1 = bboxH - 1;

            float haloMax = 0.72f * dragAlpha;
            float coreMax = 0.44f * dragAlpha;

            fixed (float* pHalo = _haloBuf)
            fixed (float* pCore = _coreBuf)
            fixed (float* pColor = _colorBuf)
            {
                for (int py = y0; py <= y1; py++)
                {
                    float dy = (py + 0.5f) - cy;
                    float dy2 = dy * dy;
                    int rowOffset = py * bboxW;
                    for (int px = x0; px <= x1; px++)
                    {
                        float dx = (px + 0.5f) - cx;
                        float dist2 = dx * dx + dy2;
                        if (dist2 >= haloR * haloR) continue;

                        float dist = (float)Math.Sqrt(dist2);
                        int idx = rowOffset + px;

                        float nh = 1.0f - dist / haloR;
                        float hVal = nh * nh * nh * haloMax;
                        if (hVal > pHalo[idx])
                        {
                            pHalo[idx] = hVal;
                            if (trackColor)
                            {
                                pColor[idx] = (float)(Math.Atan2((double)dy, (double)dx) * (1.0 / (2.0 * Math.PI)) + 0.5);
                            }
                        }

                        if (dist < coreR)
                        {
                            float nc = 1.0f - dist / coreR;
                            float cVal = (nc * nc * (3.0f - 2.0f * nc)) * coreMax;
                            if (cVal > pCore[idx]) pCore[idx] = cVal;
                        }
                    }
                }
            }
        }

        private unsafe void AccumulateScrollArc(
            int originX,
            int originY,
            int bboxW,
            int bboxH,
            int cursorX,
            int cursorY,
            int scrollDir,
            float progress,
            float scale,
            bool trackColor)
        {
            float inv = 1.0f - progress;
            float ease = 1.0f - inv * inv;
            float rArc = (13.0f + 5.5f * ease) * scale;
            float arcHaloW = 4.5f * scale;
            float arcCoreW = 1.3f * scale;
            float fade = inv * inv * 0.72f;
            if (fade <= 0.005f) return;

            float dirY = scrollDir > 0 ? -1.0f : 1.0f;
            float cx = (float)(cursorX - originX);
            float cy = (float)(cursorY - originY);
            float reach = rArc + arcHaloW + 1.0f;

            int x0 = (int)Math.Floor(cx - reach);
            int y0 = (int)Math.Floor(cy - reach);
            int x1 = (int)Math.Ceiling(cx + reach);
            int y1 = (int)Math.Ceiling(cy + reach);

            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 >= bboxW) x1 = bboxW - 1;
            if (y1 >= bboxH) y1 = bboxH - 1;

            fixed (float* pHalo = _haloBuf)
            fixed (float* pCore = _coreBuf)
            fixed (float* pColor = _colorBuf)
            {
                for (int py = y0; py <= y1; py++)
                {
                    float dy = (py + 0.5f) - cy;
                    float dy2 = dy * dy;
                    int rowOffset = py * bboxW;
                    for (int px = x0; px <= x1; px++)
                    {
                        float dx = (px + 0.5f) - cx;
                        float dist = (float)Math.Sqrt(dx * dx + dy2);
                        if (dist <= 1.0f) continue;

                        float dArc = dist - rArc;
                        if (dArc < 0.0f) dArc = -dArc;
                        if (dArc >= arcHaloW) continue;

                        float cosTheta = (dy * dirY) / dist;
                        if (cosTheta <= 0.64f) continue;

                        float angW = SmoothStep(0.64f, 0.96f, cosTheta);
                        float nh = 1.0f - dArc / arcHaloW;
                        float hVal = nh * nh * nh * fade * angW;
                        int idx = rowOffset + px;
                        if (hVal > pHalo[idx])
                        {
                            pHalo[idx] = hVal;
                            if (trackColor) pColor[idx] = 0.5f + 0.35f * (dx / rArc);
                        }

                        if (dArc < arcCoreW)
                        {
                            float nc = 1.0f - dArc / arcCoreW;
                            float cVal = (nc * nc * (3.0f - 2.0f * nc)) * fade * angW;
                            if (cVal > pCore[idx]) pCore[idx] = cVal;
                        }
                    }
                }
            }
        }

        private unsafe void AccumulatePalettePreview(
            int originX,
            int originY,
            int bboxW,
            int bboxH,
            int cursorX,
            int cursorY,
            float progress,
            float scale,
            bool trackColor)
        {
            float inv = 1.0f - progress;
            float ease = 1.0f - inv * inv * inv;
            float rRing = (9.0f + 17.0f * ease) * scale;
            float ringHaloW = 7.5f * scale;
            float ringCoreW = 2.0f * scale;
            float fade = inv * inv;
            if (fade <= 0.005f) return;

            float cx = (float)(cursorX - originX);
            float cy = (float)(cursorY - originY);
            float reach = rRing + ringHaloW + 1.0f;

            int x0 = (int)Math.Floor(cx - reach);
            int y0 = (int)Math.Floor(cy - reach);
            int x1 = (int)Math.Ceiling(cx + reach);
            int y1 = (int)Math.Ceiling(cy + reach);

            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 >= bboxW) x1 = bboxW - 1;
            if (y1 >= bboxH) y1 = bboxH - 1;

            fixed (float* pHalo = _haloBuf)
            fixed (float* pCore = _coreBuf)
            fixed (float* pColor = _colorBuf)
            {
                for (int py = y0; py <= y1; py++)
                {
                    float dy = (py + 0.5f) - cy;
                    float dy2 = dy * dy;
                    int rowOffset = py * bboxW;
                    for (int px = x0; px <= x1; px++)
                    {
                        float dx = (px + 0.5f) - cx;
                        float dist = (float)Math.Sqrt(dx * dx + dy2);
                        float dRing = dist - rRing;
                        if (dRing < 0.0f) dRing = -dRing;
                        if (dRing >= ringHaloW) continue;

                        float nh = 1.0f - dRing / ringHaloW;
                        float hVal = nh * nh * nh * fade;
                        int idx = rowOffset + px;
                        if (hVal > pHalo[idx])
                        {
                            pHalo[idx] = hVal;
                            if (trackColor)
                            {
                                pColor[idx] = (float)(Math.Atan2((double)dy, (double)dx) * (1.0 / (2.0 * Math.PI)) + 0.5);
                            }
                        }

                        if (dRing < ringCoreW)
                        {
                            float nc = 1.0f - dRing / ringCoreW;
                            float cVal = (nc * nc * (3.0f - 2.0f * nc)) * fade;
                            if (cVal > pCore[idx]) pCore[idx] = cVal;
                        }
                    }
                }
            }
        }

        private unsafe int CompositePremultiplied(int bboxW, int bboxH, TrailPreset preset, ColorPalette palette, float timeSec)
        {
            uint* dibBase = (uint*)_dibBits.ToPointer();
            int dibStride = _dibWidth;
            int nonZeroCount = 0;
            bool isDynamic = (palette.Mode != PaletteMode.Solid);

            fixed (float* pHalo = _haloBuf)
            fixed (float* pCore = _coreBuf)
            fixed (float* pColor = _colorBuf)
            {
                for (int y = 0; y < bboxH; y++)
                {
                    uint* dibRow = dibBase + y * dibStride;
                    int bufRow = y * bboxW;
                    for (int x = 0; x < bboxW; x++)
                    {
                        int idx = bufRow + x;
                        float h = pHalo[idx];
                        float c = pCore[idx];
                        float colorParam = isDynamic ? pColor[idx] : 0.0f;
                        pHalo[idx] = 0.0f;
                        pCore[idx] = 0.0f;
                        if (isDynamic) pColor[idx] = 0.0f;

                        if (h <= 0.001f && c <= 0.001f)
                        {
                            dibRow[x] = 0u;
                            continue;
                        }

                        float ah = h * preset.HaloAlpha;
                        if (ah > 1.0f) ah = 1.0f;
                        float ac = c * preset.CoreAlpha;
                        if (ac > 1.0f) ac = 1.0f;

                        float oneMinusAc = 1.0f - ac;
                        float aOut = ac + ah * oneMinusAc;
                        if (aOut <= 0.002f)
                        {
                            dibRow[x] = 0u;
                            continue;
                        }

                        float hr = palette.HaloR;
                        float hg = palette.HaloG;
                        float hb = palette.HaloB;
                        float cr = palette.CoreR;
                        float cg = palette.CoreG;
                        float cb = palette.CoreB;
                        if (isDynamic)
                        {
                            EvaluateDynamicColor(palette.Mode, colorParam, timeSec, out hr, out hg, out hb, out cr, out cg, out cb);
                        }

                        float invA = 1.0f / aOut;
                        float r = (cr * ac + hr * ah * oneMinusAc) * invA;
                        float g = (cg * ac + hg * ah * oneMinusAc) * invA;
                        float b = (cb * ac + hb * ah * oneMinusAc) * invA;

                        int aInt = (int)(aOut * 255.0f + 0.5f);
                        if (aInt > 255) aInt = 255;
                        byte aB = (byte)aInt;

                        int rInt = (int)(r * aB + 0.5f);
                        int gInt = (int)(g * aB + 0.5f);
                        int bInt = (int)(b * aB + 0.5f);

                        if (rInt > aB) rInt = aB; else if (rInt < 0) rInt = 0;
                        if (gInt > aB) gInt = aB; else if (gInt < 0) gInt = 0;
                        if (bInt > aB) bInt = aB; else if (bInt < 0) bInt = 0;

                        dibRow[x] = ((uint)aB << 24) | ((uint)(byte)rInt << 16) | ((uint)(byte)gInt << 8) | (uint)(byte)bInt;
                        nonZeroCount++;
                    }
                }
            }
            return nonZeroCount;
        }

        private static void EvaluateDynamicColor(
            PaletteMode mode,
            float colorParam,
            float timeSec,
            out float hr,
            out float hg,
            out float hb,
            out float cr,
            out float cg,
            out float cb)
        {
            if (mode == PaletteMode.PinkBlue)
            {
                float s = 0.5f + 0.5f * (float)Math.Sin((double)(colorParam + timeSec * 0.22f) * 2.0 * Math.PI);
                hr = 0.22f + 0.78f * s;
                hg = 0.72f - 0.32f * s;
                hb = 1.00f - 0.22f * s;
                cr = hr + (1.0f - hr) * 0.78f;
                cg = hg + (1.0f - hg) * 0.78f;
                cb = hb + (1.0f - hb) * 0.78f;
                return;
            }

            float hue = colorParam + timeSec * 0.28f;
            hue = hue - (float)Math.Floor((double)hue);
            HsvToRgb(hue, 0.76f, 1.0f, out hr, out hg, out hb);
            cr = hr + (1.0f - hr) * 0.74f;
            cg = hg + (1.0f - hg) * 0.74f;
            cb = hb + (1.0f - hb) * 0.74f;
        }

        private static void HsvToRgb(float h, float s, float v, out float r, out float g, out float b)
        {
            float scaled = h * 6.0f;
            int sector = (int)Math.Floor((double)scaled);
            float f = scaled - (float)sector;
            float p = v * (1.0f - s);
            float q = v * (1.0f - f * s);
            float t = v * (1.0f - (1.0f - f) * s);
            switch (sector % 6)
            {
                case 0: r = v; g = t; b = p; break;
                case 1: r = q; g = v; b = p; break;
                case 2: r = p; g = v; b = t; break;
                case 3: r = p; g = q; b = v; break;
                case 4: r = t; g = p; b = v; break;
                default: r = v; g = p; b = q; break;
            }
        }

        private void DisposeDibOnly()
        {
            if (_memDC != IntPtr.Zero)
            {
                if (_oldBitmap != IntPtr.Zero)
                {
                    NativeMethods.SelectObject(_memDC, _oldBitmap);
                    _oldBitmap = IntPtr.Zero;
                }
                if (_dibBitmap != IntPtr.Zero)
                {
                    NativeMethods.DeleteObject(_dibBitmap);
                    _dibBitmap = IntPtr.Zero;
                }
                NativeMethods.DeleteDC(_memDC);
                _memDC = IntPtr.Zero;
            }
            _dibBits = IntPtr.Zero;
            _dibWidth = 0;
            _dibHeight = 0;
        }

        public void Dispose()
        {
            DisposeDibOnly();
        }
    }

    internal sealed class OverlayEngine : IDisposable
    {
        private readonly SampleRingBuffer _buffer;
        private readonly ClickRippleBuffer _ripples;
        private readonly InteractionState _interaction;
        private readonly AutoResetEvent _wakeEvent;
        private readonly ManualResetEvent _stopEvent;
        private readonly object _configLock = new object();
        private bool _enabled;
        private bool _trailEnabled;
        private bool _clickRippleEnabled;
        private bool _dragGlowEnabled;
        private bool _shakeLocateEnabled;
        private bool _scrollGlowEnabled;
        private TrailPreset _preset;
        private ColorPalette _palette;
        private bool _autoPauseFullscreen;

        private Thread _renderThread;
        private IntPtr _hwnd;
        private NativeMethods.WndProcDelegate _wndProcDelegate;

        public OverlayEngine(SampleRingBuffer buffer, ClickRippleBuffer ripples, InteractionState interaction, AppConfig config)
        {
            _buffer = buffer;
            _ripples = ripples;
            _interaction = interaction;
            _wakeEvent = new AutoResetEvent(false);
            _stopEvent = new ManualResetEvent(false);
            ApplyConfig(config);
        }

        public void ApplyConfig(AppConfig config)
        {
            lock (_configLock)
            {
                _enabled = config.Enabled;
                _trailEnabled = config.TrailEnabled;
                _clickRippleEnabled = config.ClickRippleEnabled;
                _dragGlowEnabled = config.DragGlowEnabled;
                _shakeLocateEnabled = config.ShakeLocateEnabled;
                _scrollGlowEnabled = config.ScrollGlowEnabled;
                _preset = AppConfig.GetPreset(config.Preset);
                _palette = AppConfig.GetPalette(config.Palette, config.CustomColorHex);
                _autoPauseFullscreen = config.AutoPauseFullscreen;
            }
            _wakeEvent.Set();
        }

        public void NotifyInput()
        {
            _wakeEvent.Set();
        }

        public void Start()
        {
            _renderThread = new Thread(RenderLoop);
            _renderThread.IsBackground = true;
            _renderThread.Priority = ThreadPriority.AboveNormal;
            _renderThread.Name = "BibataIceTrailRender";
            _renderThread.Start();
        }

        private IntPtr OverlayWndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
        {
            if (msg == NativeMethods.WM_NCHITTEST)
            {
                return new IntPtr(NativeMethods.HTTRANSPARENT);
            }
            if (msg == NativeMethods.WM_MOUSEACTIVATE)
            {
                return new IntPtr(NativeMethods.MA_NOACTIVATE);
            }
            if (msg == NativeMethods.WM_DESTROY)
            {
                NativeMethods.PostQuitMessage(0);
                return IntPtr.Zero;
            }
            return NativeMethods.DefWindowProcW(hWnd, msg, wParam, lParam);
        }

        private bool CreateOverlayWindow()
        {
            _wndProcDelegate = new NativeMethods.WndProcDelegate(OverlayWndProc);
            IntPtr hInstance = NativeMethods.GetModuleHandleW(null);
            string className = "BibataIceTrailOverlayClass";

            NativeMethods.WNDCLASSEXW wcex = new NativeMethods.WNDCLASSEXW();
            wcex.cbSize = (uint)Marshal.SizeOf(typeof(NativeMethods.WNDCLASSEXW));
            wcex.lpfnWndProc = _wndProcDelegate;
            wcex.hInstance = hInstance;
            wcex.lpszClassName = className;

            NativeMethods.RegisterClassExW(ref wcex);

            int exStyle = NativeMethods.WS_EX_LAYERED
                        | NativeMethods.WS_EX_TRANSPARENT
                        | NativeMethods.WS_EX_TOPMOST
                        | NativeMethods.WS_EX_TOOLWINDOW
                        | NativeMethods.WS_EX_NOACTIVATE;

            _hwnd = NativeMethods.CreateWindowExW(
                exStyle,
                className,
                "BibataIceTrailOverlay",
                NativeMethods.WS_POPUP,
                0, 0, 1, 1,
                IntPtr.Zero,
                IntPtr.Zero,
                hInstance,
                IntPtr.Zero);

            return _hwnd != IntPtr.Zero;
        }

        private void PumpThreadMessages()
        {
            NativeMethods.MSG msg;
            while (NativeMethods.PeekMessageW(out msg, IntPtr.Zero, 0, 0, NativeMethods.PM_REMOVE))
            {
                NativeMethods.TranslateMessage(ref msg);
                NativeMethods.DispatchMessageW(ref msg);
            }
        }

        private void RenderLoop()
        {
            if (!CreateOverlayWindow()) return;

            using (TrailRenderer renderer = new TrailRenderer())
            {
                TrailSample[] snapshot = new TrailSample[512];
                ClickRipple[] rippleSnapshot = new ClickRipple[16];
                bool isShown = false;
                long lastFullscreenCheck = 0;
                bool fullscreenPaused = false;
                long fullscreenInterval = (long)(0.30 * Stopwatch.Frequency);
                int lastIdleX = int.MinValue;
                int lastIdleY = int.MinValue;

                IntPtr[] waitHandles = new IntPtr[2];
                waitHandles[0] = _wakeEvent.SafeWaitHandle.DangerousGetHandle();
                waitHandles[1] = _stopEvent.SafeWaitHandle.DangerousGetHandle();

                while (!_stopEvent.WaitOne(0))
                {
                    PumpThreadMessages();

                    bool enabled;
                    bool trailEnabled;
                    bool rippleEnabled;
                    bool dragEnabled;
                    bool shakeEnabled;
                    bool scrollEnabled;
                    TrailPreset preset;
                    ColorPalette palette;
                    bool autoPause;
                    lock (_configLock)
                    {
                        enabled = _enabled;
                        trailEnabled = _trailEnabled;
                        rippleEnabled = _clickRippleEnabled;
                        dragEnabled = _dragGlowEnabled;
                        shakeEnabled = _shakeLocateEnabled;
                        scrollEnabled = _scrollGlowEnabled;
                        preset = _preset;
                        palette = _palette;
                        autoPause = _autoPauseFullscreen;
                    }

                    long nowTicks = Stopwatch.GetTimestamp();

                    if (autoPause && (nowTicks - lastFullscreenCheck) >= fullscreenInterval)
                    {
                        lastFullscreenCheck = nowTicks;
                        fullscreenPaused = NativeMethods.IsFullscreenBusy();
                    }
                    else if (!autoPause)
                    {
                        fullscreenPaused = false;
                    }

                    if (!enabled || (!trailEnabled && !rippleEnabled && !dragEnabled && !shakeEnabled && !scrollEnabled) || fullscreenPaused)
                    {
                        if (isShown)
                        {
                            NativeMethods.ShowWindow(_hwnd, NativeMethods.SW_HIDE);
                            isShown = false;
                        }
                        _buffer.Clear();
                        _ripples.Clear();
                        _interaction.Clear();
                        uint waitRes = NativeMethods.MsgWaitForMultipleObjects(2, waitHandles, false, NativeMethods.INFINITE, NativeMethods.QS_ALLINPUT);
                        if (waitRes == NativeMethods.WAIT_OBJECT_0 + 1) break;
                        continue;
                    }

                    NativeMethods.POINT curPt;
                    bool gotCursor = NativeMethods.GetCursorPos(out curPt);
                    if (gotCursor)
                    {
                        if (trailEnabled)
                        {
                            _buffer.Push(curPt.X, curPt.Y, nowTicks);
                        }
                        lastIdleX = curPt.X;
                        lastIdleY = curPt.Y;
                    }

                    bool leftStillDown = dragEnabled && ((NativeMethods.GetAsyncKeyState(NativeMethods.VK_LBUTTON) & 0x8000) != 0);
                    float shakeProgress;
                    float dragAlpha;
                    float dragPhaseSec;
                    int scrollDir;
                    float scrollProgress;
                    float previewProgress;
                    _interaction.SampleVisualState(
                        nowTicks, leftStillDown, shakeEnabled, dragEnabled, scrollEnabled,
                        out shakeProgress, out dragAlpha, out dragPhaseSec,
                        out scrollDir, out scrollProgress, out previewProgress);

                    int count = trailEnabled ? _buffer.CopyActive(nowTicks, preset.LifetimeMs, snapshot) : 0;
                    int rippleCount = rippleEnabled ? _ripples.CopyActive(nowTicks, preset.RippleDurationMs, rippleSnapshot) : 0;
                    bool hasShake = shakeProgress >= 0.0f && shakeProgress < 1.0f;
                    bool hasDrag = dragAlpha > 0.005f;
                    bool hasScroll = scrollDir != 0 && scrollProgress >= 0.0f && scrollProgress < 1.0f;
                    bool hasPreview = previewProgress >= 0.0f && previewProgress < 1.0f;

                    if (count < 2 && rippleCount == 0 && !hasShake && !hasDrag && !hasScroll && !hasPreview)
                    {
                        if (isShown)
                        {
                            NativeMethods.ShowWindow(_hwnd, NativeMethods.SW_HIDE);
                            isShown = false;
                        }
                        uint waitRes = NativeMethods.MsgWaitForMultipleObjects(2, waitHandles, false, 25, NativeMethods.QS_ALLINPUT);
                        if (waitRes == NativeMethods.WAIT_OBJECT_0 + 1) break;
                        NativeMethods.POINT idlePt;
                        if (NativeMethods.GetCursorPos(out idlePt) && (idlePt.X != lastIdleX || idlePt.Y != lastIdleY))
                        {
                            long idleTicks = Stopwatch.GetTimestamp();
                            lastIdleX = idlePt.X;
                            lastIdleY = idlePt.Y;
                            if (trailEnabled)
                            {
                                _buffer.Push(idlePt.X, idlePt.Y, idleTicks);
                            }
                            if (shakeEnabled || dragEnabled)
                            {
                                uint idleDpi = NativeMethods.GetDpiAtPoint(idlePt.X, idlePt.Y);
                                _interaction.OnCursorMove(idlePt.X, idlePt.Y, idleTicks, idleDpi, shakeEnabled, dragEnabled);
                            }
                        }
                        continue;
                    }

                    int dpiX = gotCursor ? curPt.X : ((count >= 2) ? snapshot[count - 1].X : rippleSnapshot[rippleCount - 1].X);
                    int dpiY = gotCursor ? curPt.Y : ((count >= 2) ? snapshot[count - 1].Y : rippleSnapshot[rippleCount - 1].Y);
                    uint dpi = NativeMethods.GetDpiAtPoint(dpiX, dpiY);

                    int bx, by, bw, bh;
                    bool hasPixels = renderer.RenderFrame(
                        snapshot, count, trailEnabled,
                        rippleSnapshot, rippleCount, rippleEnabled,
                        dpiX, dpiY, shakeProgress, dragAlpha, dragPhaseSec,
                        scrollDir, scrollProgress, previewProgress,
                        nowTicks, dpi, preset, palette,
                        out bx, out by, out bw, out bh);

                    if (!hasPixels)
                    {
                        if (isShown)
                        {
                            NativeMethods.ShowWindow(_hwnd, NativeMethods.SW_HIDE);
                            isShown = false;
                        }
                        uint waitRes = NativeMethods.MsgWaitForMultipleObjects(2, waitHandles, false, 25, NativeMethods.QS_ALLINPUT);
                        if (waitRes == NativeMethods.WAIT_OBJECT_0 + 1) break;
                        NativeMethods.POINT idlePt;
                        if (NativeMethods.GetCursorPos(out idlePt) && (idlePt.X != lastIdleX || idlePt.Y != lastIdleY))
                        {
                            long idleTicks = Stopwatch.GetTimestamp();
                            lastIdleX = idlePt.X;
                            lastIdleY = idlePt.Y;
                            if (trailEnabled)
                            {
                                _buffer.Push(idlePt.X, idlePt.Y, idleTicks);
                            }
                            if (shakeEnabled || dragEnabled)
                            {
                                uint idleDpi = NativeMethods.GetDpiAtPoint(idlePt.X, idlePt.Y);
                                _interaction.OnCursorMove(idlePt.X, idlePt.Y, idleTicks, idleDpi, shakeEnabled, dragEnabled);
                            }
                        }
                        continue;
                    }

                    NativeMethods.POINT ptDst = new NativeMethods.POINT();
                    ptDst.X = bx;
                    ptDst.Y = by;
                    NativeMethods.SIZE sz = new NativeMethods.SIZE();
                    sz.cx = bw;
                    sz.cy = bh;
                    NativeMethods.POINT ptSrc = new NativeMethods.POINT();
                    ptSrc.X = 0;
                    ptSrc.Y = 0;
                    NativeMethods.BLENDFUNCTION blend = new NativeMethods.BLENDFUNCTION();
                    blend.BlendOp = NativeMethods.AC_SRC_OVER;
                    blend.BlendFlags = 0;
                    blend.SourceConstantAlpha = 255;
                    blend.AlphaFormat = NativeMethods.AC_SRC_ALPHA;

                    NativeMethods.UpdateLayeredWindow(
                        _hwnd,
                        IntPtr.Zero,
                        ref ptDst,
                        ref sz,
                        renderer.MemDC,
                        ref ptSrc,
                        0,
                        ref blend,
                        NativeMethods.ULW_ALPHA);

                    if (!isShown)
                    {
                        NativeMethods.SetWindowPos(
                            _hwnd,
                            NativeMethods.HWND_TOPMOST,
                            0, 0, 0, 0,
                            NativeMethods.SWP_NOMOVE | NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOACTIVATE | NativeMethods.SWP_SHOWWINDOW);
                        isShown = true;
                    }

                    int hr = 0;
                    try
                    {
                        hr = NativeMethods.DwmFlush();
                    }
                    catch
                    {
                        hr = -1;
                    }
                    if (hr != 0)
                    {
                        Thread.Sleep(4);
                    }
                }
            }

            if (_hwnd != IntPtr.Zero)
            {
                NativeMethods.DestroyWindow(_hwnd);
                _hwnd = IntPtr.Zero;
            }
        }

        public void Dispose()
        {
            _stopEvent.Set();
            _wakeEvent.Set();
            if (_renderThread != null && _renderThread.IsAlive)
            {
                _renderThread.Join(1000);
            }
            _wakeEvent.Dispose();
            _stopEvent.Dispose();
        }
    }

    internal sealed class RawInputMessageWindow : NativeWindow, IDisposable
    {
        private const int HotkeyId = 1;
        private const int PaletteHotkeyId = 2;

        private readonly SampleRingBuffer _buffer;
        private readonly ClickRippleBuffer _ripples;
        private readonly InteractionState _interaction;
        private readonly OverlayEngine _engine;
        private readonly Action _onHotkeyToggle;
        private readonly Action _onCyclePalette;
        private readonly byte[] _rawBuf = new byte[128];
        private readonly uint _rawHeaderSize;
        private bool _hotkeyRegistered;
        private bool _paletteHotkeyRegistered;
        private volatile bool _shakeEnabled = true;
        private volatile bool _dragEnabled = true;
        private volatile bool _scrollEnabled = true;

        public RawInputMessageWindow(
            SampleRingBuffer buffer,
            ClickRippleBuffer ripples,
            InteractionState interaction,
            OverlayEngine engine,
            Action onHotkeyToggle,
            Action onCyclePalette)
        {
            _buffer = buffer;
            _ripples = ripples;
            _interaction = interaction;
            _engine = engine;
            _onHotkeyToggle = onHotkeyToggle;
            _onCyclePalette = onCyclePalette;
            _rawHeaderSize = (uint)Marshal.SizeOf(typeof(NativeMethods.RAWINPUTHEADER));

            CreateParams cp = new CreateParams();
            cp.Caption = "BibataIceTrailRawInputSink";
            cp.Style = 0;
            cp.ExStyle = 0;
            cp.Parent = new IntPtr(-3); // HWND_MESSAGE
            CreateHandle(cp);

            NativeMethods.RAWINPUTDEVICE[] rid = new NativeMethods.RAWINPUTDEVICE[1];
            rid[0].usUsagePage = 0x01; // Generic Desktop Controls
            rid[0].usUsage = 0x02;     // Mouse
            rid[0].dwFlags = NativeMethods.RIDEV_INPUTSINK;
            rid[0].hwndTarget = Handle;

            NativeMethods.RegisterRawInputDevices(rid, 1, (uint)Marshal.SizeOf(typeof(NativeMethods.RAWINPUTDEVICE)));
        }

        public void SetTrackingOptions(bool shakeEnabled, bool dragEnabled, bool scrollEnabled, bool hotkeyEnabled)
        {
            _shakeEnabled = shakeEnabled;
            _dragEnabled = dragEnabled;
            _scrollEnabled = scrollEnabled;
            SetHotkeyEnabled(hotkeyEnabled);
        }

        private void SetHotkeyEnabled(bool enable)
        {
            if (Handle == IntPtr.Zero) return;
            uint mods = NativeMethods.MOD_CONTROL | NativeMethods.MOD_ALT | NativeMethods.MOD_SHIFT | NativeMethods.MOD_NOREPEAT;
            if (enable)
            {
                if (!_hotkeyRegistered)
                {
                    _hotkeyRegistered = NativeMethods.RegisterHotKey(Handle, HotkeyId, mods, NativeMethods.VK_G);
                }
                if (!_paletteHotkeyRegistered)
                {
                    _paletteHotkeyRegistered = NativeMethods.RegisterHotKey(Handle, PaletteHotkeyId, mods, NativeMethods.VK_C);
                }
            }
            else
            {
                if (_hotkeyRegistered)
                {
                    NativeMethods.UnregisterHotKey(Handle, HotkeyId);
                    _hotkeyRegistered = false;
                }
                if (_paletteHotkeyRegistered)
                {
                    NativeMethods.UnregisterHotKey(Handle, PaletteHotkeyId);
                    _paletteHotkeyRegistered = false;
                }
            }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == NativeMethods.WM_HOTKEY)
            {
                int hkId = m.WParam.ToInt32();
                if (hkId == HotkeyId && _onHotkeyToggle != null)
                {
                    _onHotkeyToggle();
                }
                else if (hkId == PaletteHotkeyId && _onCyclePalette != null)
                {
                    _onCyclePalette();
                }
            }
            else if (m.Msg == NativeMethods.WM_INPUT)
            {
                long nowTicks = Stopwatch.GetTimestamp();
                NativeMethods.POINT pt;
                if (NativeMethods.GetCursorPos(out pt))
                {
                    uint sz = (uint)_rawBuf.Length;
                    uint got = NativeMethods.GetRawInputData(m.LParam, NativeMethods.RID_INPUT, _rawBuf, ref sz, _rawHeaderSize);
                    if (got != uint.MaxValue && got >= 30)
                    {
                        int dwType = BitConverter.ToInt32(_rawBuf, 0);
                        if (dwType == NativeMethods.RIM_TYPEMOUSE)
                        {
                            ushort btnFlags = BitConverter.ToUInt16(_rawBuf, 28);
                            if ((btnFlags & NativeMethods.RI_MOUSE_LEFT_BUTTON_DOWN) != 0)
                            {
                                _ripples.Push(pt.X, pt.Y, nowTicks, 0);
                                _interaction.OnLeftDown(pt.X, pt.Y, nowTicks);
                            }
                            else if ((btnFlags & NativeMethods.RI_MOUSE_MIDDLE_BUTTON_DOWN) != 0)
                            {
                                _ripples.Push(pt.X, pt.Y, nowTicks, 0);
                            }
                            if ((btnFlags & NativeMethods.RI_MOUSE_LEFT_BUTTON_UP) != 0)
                            {
                                _interaction.OnLeftUp(nowTicks);
                            }
                            if ((btnFlags & NativeMethods.RI_MOUSE_RIGHT_BUTTON_DOWN) != 0)
                            {
                                _ripples.Push(pt.X, pt.Y, nowTicks, 1);
                            }
                            if ((btnFlags & NativeMethods.RI_MOUSE_WHEEL) != 0 && got >= 32 && _scrollEnabled)
                            {
                                short wheelDelta = BitConverter.ToInt16(_rawBuf, 30);
                                if (wheelDelta != 0)
                                {
                                    _interaction.OnWheelScroll(wheelDelta > 0 ? 1 : -1, nowTicks);
                                }
                            }
                        }
                    }

                    bool shakeOn = _shakeEnabled;
                    bool dragOn = _dragEnabled;
                    if (shakeOn || dragOn)
                    {
                        uint dpi = NativeMethods.GetDpiAtPoint(pt.X, pt.Y);
                        _interaction.OnCursorMove(pt.X, pt.Y, nowTicks, dpi, shakeOn, dragOn);
                    }

                    _buffer.Push(pt.X, pt.Y, nowTicks);
                    _engine.NotifyInput();
                }
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            SetHotkeyEnabled(false);
            if (Handle != IntPtr.Zero)
            {
                DestroyHandle();
            }
        }
    }

    internal sealed class TrayApplicationContext : ApplicationContext
    {
        private const string RunRegPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string RunValueName = "BibataIceTrail";

        private readonly AppConfig _config;
        private readonly SampleRingBuffer _buffer;
        private readonly ClickRippleBuffer _ripples;
        private readonly InteractionState _interaction;
        private readonly OverlayEngine _engine;
        private readonly RawInputMessageWindow _inputSink;
        private readonly NotifyIcon _notifyIcon;
        private readonly Icon _activeIcon;
        private readonly Icon _pausedIcon;
        private bool _colorDialogOpen;

        private ToolStripMenuItem _itemEnabled;
        private ToolStripMenuItem _itemTrailEnabled;
        private ToolStripMenuItem _itemClickEnabled;
        private ToolStripMenuItem _itemDragEnabled;
        private ToolStripMenuItem _itemShakeEnabled;
        private ToolStripMenuItem _itemScrollEnabled;
        private ToolStripMenuItem _itemPresetLight;
        private ToolStripMenuItem _itemPresetStd;
        private ToolStripMenuItem _itemPresetVivid;
        private ToolStripMenuItem _itemColorIce;
        private ToolStripMenuItem _itemColorCyan;
        private ToolStripMenuItem _itemColorFrost;
        private ToolStripMenuItem _itemColorPinkBlue;
        private ToolStripMenuItem _itemColorRainbow;
        private ToolStripMenuItem _itemColorCustom;
        private ToolStripMenuItem _itemFullscreen;
        private ToolStripMenuItem _itemHotkeyEnabled;
        private ToolStripMenuItem _itemAutoStart;

        public TrayApplicationContext(AppConfig config, bool showTrayIcon)
        {
            _config = config;
            _buffer = new SampleRingBuffer(512);
            _ripples = new ClickRippleBuffer(16);
            _interaction = new InteractionState();
            _engine = new OverlayEngine(_buffer, _ripples, _interaction, _config);
            _engine.Start();
            _inputSink = new RawInputMessageWindow(
                _buffer, _ripples, _interaction, _engine,
                new Action(ToggleEnabled),
                new Action(CyclePalette));
            _inputSink.SetTrackingOptions(_config.ShakeLocateEnabled, _config.DragGlowEnabled, _config.ScrollGlowEnabled, _config.HotkeyEnabled);

            if (showTrayIcon)
            {
                _activeIcon = CreateTrayIcon(true);
                _pausedIcon = CreateTrayIcon(false);

                _notifyIcon = new NotifyIcon();
                _notifyIcon.ContextMenuStrip = BuildMenu();
                _notifyIcon.MouseClick += OnTrayMouseClick;
                SyncMenuAndIcon();
                _notifyIcon.Visible = true;
            }
        }

        private ContextMenuStrip BuildMenu()
        {
            ContextMenuStrip menu = new ContextMenuStrip();

            _itemEnabled = new ToolStripMenuItem("启用光影总开关");
            _itemEnabled.Click += delegate { ToggleEnabled(); };
            menu.Items.Add(_itemEnabled);

            _itemTrailEnabled = new ToolStripMenuItem("滑动流光拖尾");
            _itemTrailEnabled.Click += delegate { ToggleTrailEnabled(); };
            menu.Items.Add(_itemTrailEnabled);

            _itemClickEnabled = new ToolStripMenuItem("点击冰蓝波纹");
            _itemClickEnabled.Click += delegate { ToggleClickRippleEnabled(); };
            menu.Items.Add(_itemClickEnabled);

            _itemDragEnabled = new ToolStripMenuItem("拖拽柔光反馈");
            _itemDragEnabled.Click += delegate { ToggleDragGlowEnabled(); };
            menu.Items.Add(_itemDragEnabled);

            _itemShakeEnabled = new ToolStripMenuItem("甩动定位指针");
            _itemShakeEnabled.Click += delegate { ToggleShakeLocateEnabled(); };
            menu.Items.Add(_itemShakeEnabled);

            _itemScrollEnabled = new ToolStripMenuItem("滚轮方向微光");
            _itemScrollEnabled.Click += delegate { ToggleScrollGlowEnabled(); };
            menu.Items.Add(_itemScrollEnabled);

            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem presetRoot = new ToolStripMenuItem("风格预设");
            _itemPresetLight = new ToolStripMenuItem("轻盈冰光");
            _itemPresetLight.Click += delegate { SetPreset(PresetKind.Light); };
            _itemPresetStd = new ToolStripMenuItem("标准冰蓝（推荐）");
            _itemPresetStd.Click += delegate { SetPreset(PresetKind.Standard); };
            _itemPresetVivid = new ToolStripMenuItem("灵动流光");
            _itemPresetVivid.Click += delegate { SetPreset(PresetKind.Vivid); };
            presetRoot.DropDownItems.Add(_itemPresetLight);
            presetRoot.DropDownItems.Add(_itemPresetStd);
            presetRoot.DropDownItems.Add(_itemPresetVivid);
            menu.Items.Add(presetRoot);

            ToolStripMenuItem colorRoot = new ToolStripMenuItem("光影配色");
            _itemColorIce = new ToolStripMenuItem("冰蓝 Ice（默认）");
            _itemColorIce.Click += delegate { SetPalette(PaletteKind.Ice); };
            _itemColorCyan = new ToolStripMenuItem("极光青 Cyan");
            _itemColorCyan.Click += delegate { SetPalette(PaletteKind.Cyan); };
            _itemColorFrost = new ToolStripMenuItem("霜白 Frost");
            _itemColorFrost.Click += delegate { SetPalette(PaletteKind.Frost); };
            _itemColorPinkBlue = new ToolStripMenuItem("粉蓝幻梦 Pink-Blue");
            _itemColorPinkBlue.Click += delegate { SetPalette(PaletteKind.PinkBlue); };
            _itemColorRainbow = new ToolStripMenuItem("流光七彩 Rainbow");
            _itemColorRainbow.Click += delegate { SetPalette(PaletteKind.Rainbow); };
            _itemColorCustom = new ToolStripMenuItem("自定义颜色...");
            _itemColorCustom.Click += delegate { PickCustomColor(); };
            colorRoot.DropDownItems.Add(_itemColorIce);
            colorRoot.DropDownItems.Add(_itemColorCyan);
            colorRoot.DropDownItems.Add(_itemColorFrost);
            colorRoot.DropDownItems.Add(_itemColorPinkBlue);
            colorRoot.DropDownItems.Add(_itemColorRainbow);
            colorRoot.DropDownItems.Add(new ToolStripSeparator());
            colorRoot.DropDownItems.Add(_itemColorCustom);
            menu.Items.Add(colorRoot);

            _itemFullscreen = new ToolStripMenuItem("全屏应用自动暂停");
            _itemFullscreen.Click += delegate { ToggleFullscreenPause(); };
            menu.Items.Add(_itemFullscreen);

            _itemHotkeyEnabled = new ToolStripMenuItem("快捷键开关 (G开关 / C换色)");
            _itemHotkeyEnabled.Click += delegate { ToggleHotkeyEnabled(); };
            menu.Items.Add(_itemHotkeyEnabled);

            _itemAutoStart = new ToolStripMenuItem("开机自动启动");
            _itemAutoStart.Click += delegate { ToggleAutoStart(); };
            menu.Items.Add(_itemAutoStart);

            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem itemExit = new ToolStripMenuItem("退出");
            itemExit.Click += delegate { ExitApp(); };
            menu.Items.Add(itemExit);

            return menu;
        }

        private void OnTrayMouseClick(object sender, MouseEventArgs e)
        {
            if (e.Button == MouseButtons.Left)
            {
                ToggleEnabled();
            }
        }

        private void ToggleEnabled()
        {
            _config.Enabled = !_config.Enabled;
            _config.Save();
            _engine.ApplyConfig(_config);
            SyncMenuAndIcon();
        }

        private void ToggleTrailEnabled()
        {
            _config.TrailEnabled = !_config.TrailEnabled;
            _config.Save();
            _engine.ApplyConfig(_config);
            SyncMenuAndIcon();
        }

        private void ToggleClickRippleEnabled()
        {
            _config.ClickRippleEnabled = !_config.ClickRippleEnabled;
            _config.Save();
            _engine.ApplyConfig(_config);
            SyncMenuAndIcon();
        }

        private void ToggleDragGlowEnabled()
        {
            _config.DragGlowEnabled = !_config.DragGlowEnabled;
            _config.Save();
            _inputSink.SetTrackingOptions(_config.ShakeLocateEnabled, _config.DragGlowEnabled, _config.ScrollGlowEnabled, _config.HotkeyEnabled);
            _engine.ApplyConfig(_config);
            SyncMenuAndIcon();
        }

        private void ToggleShakeLocateEnabled()
        {
            _config.ShakeLocateEnabled = !_config.ShakeLocateEnabled;
            _config.Save();
            _inputSink.SetTrackingOptions(_config.ShakeLocateEnabled, _config.DragGlowEnabled, _config.ScrollGlowEnabled, _config.HotkeyEnabled);
            _engine.ApplyConfig(_config);
            SyncMenuAndIcon();
        }

        private void ToggleScrollGlowEnabled()
        {
            _config.ScrollGlowEnabled = !_config.ScrollGlowEnabled;
            _config.Save();
            _inputSink.SetTrackingOptions(_config.ShakeLocateEnabled, _config.DragGlowEnabled, _config.ScrollGlowEnabled, _config.HotkeyEnabled);
            _engine.ApplyConfig(_config);
            SyncMenuAndIcon();
        }

        private void ToggleHotkeyEnabled()
        {
            _config.HotkeyEnabled = !_config.HotkeyEnabled;
            _config.Save();
            _inputSink.SetTrackingOptions(_config.ShakeLocateEnabled, _config.DragGlowEnabled, _config.ScrollGlowEnabled, _config.HotkeyEnabled);
            SyncMenuAndIcon();
        }

        private void CyclePalette()
        {
            PaletteKind next;
            if (_config.Palette == PaletteKind.Ice) next = PaletteKind.Cyan;
            else if (_config.Palette == PaletteKind.Cyan) next = PaletteKind.Frost;
            else if (_config.Palette == PaletteKind.Frost) next = PaletteKind.PinkBlue;
            else if (_config.Palette == PaletteKind.PinkBlue) next = PaletteKind.Rainbow;
            else next = PaletteKind.Ice;

            _config.Palette = next;
            _config.Save();
            _engine.ApplyConfig(_config);
            SyncMenuAndIcon();
            if (_config.Enabled)
            {
                _interaction.TriggerPalettePreview(Stopwatch.GetTimestamp());
                _engine.NotifyInput();
            }
        }

        private void PickCustomColor()
        {
            if (_colorDialogOpen) return;
            _colorDialogOpen = true;
            try
            {
                byte r, g, b;
                AppConfig.TryParseHexColor(_config.CustomColorHex, out r, out g, out b);
                using (ColorDialog dlg = new ColorDialog())
                {
                    dlg.FullOpen = true;
                    dlg.AnyColor = true;
                    dlg.Color = Color.FromArgb(r, g, b);
                    if (dlg.ShowDialog() == DialogResult.OK)
                    {
                        _config.CustomColorHex = string.Format(
                            CultureInfo.InvariantCulture,
                            "#{0:X2}{1:X2}{2:X2}",
                            dlg.Color.R,
                            dlg.Color.G,
                            dlg.Color.B);
                        _config.Palette = PaletteKind.Custom;
                        _config.Save();
                        _engine.ApplyConfig(_config);
                        SyncMenuAndIcon();
                    }
                }
            }
            finally
            {
                _colorDialogOpen = false;
            }
        }

        private void SetPreset(PresetKind preset)
        {
            _config.Preset = preset;
            _config.Save();
            _engine.ApplyConfig(_config);
            SyncMenuAndIcon();
        }

        private void SetPalette(PaletteKind palette)
        {
            _config.Palette = palette;
            _config.Save();
            _engine.ApplyConfig(_config);
            SyncMenuAndIcon();
        }

        private void ToggleFullscreenPause()
        {
            _config.AutoPauseFullscreen = !_config.AutoPauseFullscreen;
            _config.Save();
            _engine.ApplyConfig(_config);
            SyncMenuAndIcon();
        }

        private void ToggleAutoStart()
        {
            bool target = !IsAutoStartEnabled();
            SetAutoStart(target);
            SyncMenuAndIcon();
        }

        private static bool IsAutoStartEnabled()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(RunRegPath, false))
                {
                    if (key == null) return false;
                    object val = key.GetValue(RunValueName);
                    return val != null && !string.IsNullOrEmpty(val.ToString());
                }
            }
            catch
            {
                return false;
            }
        }

        private static void SetAutoStart(bool enable)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.CreateSubKey(RunRegPath))
                {
                    if (key == null) return;
                    if (enable)
                    {
                        key.SetValue(RunValueName, "\"" + Application.ExecutablePath + "\"", RegistryValueKind.String);
                    }
                    else
                    {
                        key.DeleteValue(RunValueName, false);
                    }
                }
            }
            catch
            {
            }
        }

        private void SyncMenuAndIcon()
        {
            if (_notifyIcon == null) return;
            _itemEnabled.Checked = _config.Enabled;
            _itemTrailEnabled.Checked = _config.TrailEnabled;
            _itemClickEnabled.Checked = _config.ClickRippleEnabled;
            _itemDragEnabled.Checked = _config.DragGlowEnabled;
            _itemShakeEnabled.Checked = _config.ShakeLocateEnabled;
            _itemScrollEnabled.Checked = _config.ScrollGlowEnabled;
            _itemPresetLight.Checked = _config.Preset == PresetKind.Light;
            _itemPresetStd.Checked = _config.Preset == PresetKind.Standard;
            _itemPresetVivid.Checked = _config.Preset == PresetKind.Vivid;
            _itemColorIce.Checked = _config.Palette == PaletteKind.Ice;
            _itemColorCyan.Checked = _config.Palette == PaletteKind.Cyan;
            _itemColorFrost.Checked = _config.Palette == PaletteKind.Frost;
            _itemColorPinkBlue.Checked = _config.Palette == PaletteKind.PinkBlue;
            _itemColorRainbow.Checked = _config.Palette == PaletteKind.Rainbow;
            _itemColorCustom.Checked = _config.Palette == PaletteKind.Custom;
            _itemColorCustom.Text = _config.Palette == PaletteKind.Custom
                ? string.Format(CultureInfo.InvariantCulture, "自定义颜色 ({0})...", _config.CustomColorHex)
                : "自定义颜色...";
            _itemFullscreen.Checked = _config.AutoPauseFullscreen;
            _itemHotkeyEnabled.Checked = _config.HotkeyEnabled;
            _itemAutoStart.Checked = IsAutoStartEnabled();

            _notifyIcon.Icon = _config.Enabled ? _activeIcon : _pausedIcon;
            _notifyIcon.Text = _config.Enabled
                ? "Bibata 冰蓝流光（运行中，左键暂停）"
                : "Bibata 冰蓝流光（已暂停，左键启用）";
        }

        private void ExitApp()
        {
            if (_notifyIcon != null)
            {
                _notifyIcon.Visible = false;
                _notifyIcon.Dispose();
            }
            _inputSink.Dispose();
            _engine.Dispose();
            if (_activeIcon != null) _activeIcon.Dispose();
            if (_pausedIcon != null) _pausedIcon.Dispose();
            ExitThread();
        }

        private static Icon CreateTrayIcon(bool active)
        {
            using (Bitmap bmp = new Bitmap(32, 32, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);

                    // Luminous ice glow arc behind the pointer
                    if (active)
                    {
                        using (GraphicsPath glow = new GraphicsPath())
                        {
                            glow.AddBezier(new PointF(5f, 26f), new PointF(10f, 20f), new PointF(13f, 15f), new PointF(15f, 10f));
                            using (Pen pOuter = new Pen(Color.FromArgb(115, 92, 196, 255), 8.0f))
                            {
                                pOuter.StartCap = LineCap.Round;
                                pOuter.EndCap = LineCap.Round;
                                g.DrawPath(pOuter, glow);
                            }
                            using (Pen pInner = new Pen(Color.FromArgb(215, 220, 245, 255), 3.4f))
                            {
                                pInner.StartCap = LineCap.Round;
                                pInner.EndCap = LineCap.Round;
                                g.DrawPath(pInner, glow);
                            }
                        }
                    }

                    // Bibata-style rounded cursor silhouette
                    PointF[] cursorPts = new PointF[]
                    {
                        new PointF(11f, 4f),
                        new PointF(26f, 17f),
                        new PointF(18f, 18.5f),
                        new PointF(21.5f, 26f),
                        new PointF(18f, 27.5f),
                        new PointF(14.5f, 20f),
                        new PointF(9.5f, 24f)
                    };
                    using (GraphicsPath cursorPath = new GraphicsPath())
                    {
                        cursorPath.AddPolygon(cursorPts);
                        using (SolidBrush fill = new SolidBrush(active ? Color.White : Color.FromArgb(190, 200, 210)))
                        using (Pen outline = new Pen(Color.FromArgb(24, 28, 36), 2.1f))
                        {
                            outline.LineJoin = LineJoin.Round;
                            g.FillPath(fill, cursorPath);
                            g.DrawPath(outline, cursorPath);
                        }
                    }
                }

                IntPtr hIcon = bmp.GetHicon();
                try
                {
                    using (Icon tmp = Icon.FromHandle(hIcon))
                    {
                        return (Icon)tmp.Clone();
                    }
                }
                finally
                {
                    NativeMethods.DestroyIcon(hIcon);
                }
            }
        }
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            NativeMethods.EnablePerMonitorDpi();

            if (args != null && args.Length >= 1 && string.Equals(args[0], "--self-test", StringComparison.OrdinalIgnoreCase))
            {
                string logPath = args.Length >= 2 ? args[1] : null;
                return RunSelfTest(logPath);
            }

            bool createdNew;
            using (Mutex mutex = new Mutex(true, "Local\\BibataIceTrail_SingleInstance", out createdNew))
            {
                if (!createdNew)
                {
                    return 0;
                }

                bool forceShowTray = false;
                if (args != null)
                {
                    for (int i = 0; i < args.Length; i++)
                    {
                        if (string.Equals(args[i], "--show-tray", StringComparison.OrdinalIgnoreCase) ||
                            string.Equals(args[i], "--tray", StringComparison.OrdinalIgnoreCase))
                        {
                            forceShowTray = true;
                        }
                    }
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                string exeDir = Path.GetDirectoryName(Application.ExecutablePath);
                string cfgPath = Path.Combine(exeDir, "config.ini");
                AppConfig config = new AppConfig(cfgPath);
                config.Load();

                TrayApplicationContext ctx = new TrayApplicationContext(config, config.ShowTrayIcon || forceShowTray);
                Application.Run(ctx);
                GC.KeepAlive(mutex);
                return 0;
            }
        }

        private static IntPtr SelfTestWndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
        {
            return NativeMethods.DefWindowProcW(hWnd, msg, wParam, lParam);
        }

        private static unsafe int RunSelfTest(string logPath)
        {
            StringBuilder report = new StringBuilder();
            try
            {
                using (TrailRenderer renderer = new TrailRenderer())
                {
                    TrailSample[] samples = new TrailSample[20];
                    long freq = Stopwatch.Frequency;
                    long nowTicks = Stopwatch.GetTimestamp();
                    // Synthetic 140ms curved swipe across ~320px at high speed
                    for (int i = 0; i < samples.Length; i++)
                    {
                        double frac = (double)i / (double)(samples.Length - 1);
                        double ageMs = (1.0 - frac) * 140.0;
                        TrailSample s = new TrailSample();
                        s.X = 400 + (int)Math.Round(frac * 320.0);
                        s.Y = 300 + (int)Math.Round(Math.Sin(frac * Math.PI) * 75.0);
                        s.Ticks = nowTicks - (long)(ageMs * freq / 1000.0);
                        s.StrokeId = 1;
                        samples[i] = s;
                    }

                    TrailPreset preset = AppConfig.GetPreset(PresetKind.Standard);
                    ColorPalette palette = AppConfig.GetPalette(PaletteKind.Ice, "#A78BFA");

                    ClickRipple[] ripples = new ClickRipple[2];
                    ripples[0].X = 720;
                    ripples[0].Y = 300;
                    ripples[0].Ticks = nowTicks - (long)(80.0 * freq / 1000.0);
                    ripples[0].Kind = 0;
                    ripples[1].X = 760;
                    ripples[1].Y = 330;
                    ripples[1].Ticks = nowTicks - (long)(95.0 * freq / 1000.0);
                    ripples[1].Kind = 1;

                    int bx, by, bw, bh;
                    Stopwatch sw = Stopwatch.StartNew();
                    bool ok = renderer.RenderFrame(samples, samples.Length, true, ripples, ripples.Length, true, 720, 300, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, palette, out bx, out by, out bw, out bh);
                    sw.Stop();

                    int nonZeroPixels = 0;
                    int alphaViolations = 0;
                    if (ok && renderer.DibBits != IntPtr.Zero)
                    {
                        uint* dibBase = (uint*)renderer.DibBits.ToPointer();
                        int stride = renderer.DibWidth;
                        for (int y = 0; y < bh; y++)
                        {
                            uint* row = dibBase + y * stride;
                            for (int x = 0; x < bw; x++)
                            {
                                uint px = row[x];
                                byte a = (byte)(px >> 24);
                                byte r = (byte)((px >> 16) & 0xFF);
                                byte g = (byte)((px >> 8) & 0xFF);
                                byte b = (byte)(px & 0xFF);
                                if (a > 0) nonZeroPixels++;
                                if (r > a || g > a || b > a) alphaViolations++;
                            }
                        }
                    }

                    // Stationary click-only rendering check (left + right click ripples without trail samples)
                    int cbx, cby, cbw, cbh;
                    bool clickOnlyOk = renderer.RenderFrame(null, 0, true, ripples, ripples.Length, true, 720, 300, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, palette, out cbx, out cby, out cbw, out cbh);
                    int clickPixels = 0;
                    if (clickOnlyOk && renderer.DibBits != IntPtr.Zero)
                    {
                        uint* dibBase = (uint*)renderer.DibBits.ToPointer();
                        int stride = renderer.DibWidth;
                        for (int y = 0; y < cbh; y++)
                        {
                            uint* row = dibBase + y * stride;
                            for (int x = 0; x < cbw; x++)
                            {
                                uint px = row[x];
                                byte a = (byte)(px >> 24);
                                byte r = (byte)((px >> 16) & 0xFF);
                                byte g = (byte)((px >> 8) & 0xFF);
                                byte b = (byte)(px & 0xFF);
                                if (a > 0) clickPixels++;
                                if (r > a || g > a || b > a) alphaViolations++;
                            }
                        }
                    }

                    // Shake-beacon + drag-glow rendering check
                    int ebx, eby, ebw, ebh;
                    bool extraOk = renderer.RenderFrame(null, 0, false, null, 0, false, 500, 400, 0.25f, 1.0f, 0.5f, 0, -1.0f, -1.0f, nowTicks, 144, preset, palette, out ebx, out eby, out ebw, out ebh);
                    int extraPixels = 0;
                    if (extraOk && renderer.DibBits != IntPtr.Zero)
                    {
                        uint* dibBase = (uint*)renderer.DibBits.ToPointer();
                        int stride = renderer.DibWidth;
                        for (int y = 0; y < ebh; y++)
                        {
                            uint* row = dibBase + y * stride;
                            for (int x = 0; x < ebw; x++)
                            {
                                uint px = row[x];
                                byte a = (byte)(px >> 24);
                                byte r = (byte)((px >> 16) & 0xFF);
                                byte g = (byte)((px >> 8) & 0xFF);
                                byte b = (byte)(px & 0xFF);
                                if (a > 0) extraPixels++;
                                if (r > a || g > a || b > a) alphaViolations++;
                            }
                        }
                    }

                    // Shake detector positive & negative check
                    InteractionState shakePos = new InteractionState();
                    bool shakeDetected = false;
                    long simT = nowTicks;
                    int[] shakePath = new int[] { 500, 620, 480, 630, 470, 640 };
                    for (int k = 0; k < shakePath.Length; k++)
                    {
                        simT += (long)(55.0 * freq / 1000.0);
                        if (shakePos.OnCursorMove(shakePath[k], 300, simT, 144, true, false))
                        {
                            shakeDetected = true;
                        }
                    }

                    InteractionState shakeNeg = new InteractionState();
                    bool falseShake = false;
                    long simT2 = nowTicks;
                    for (int k = 0; k < 20; k++)
                    {
                        simT2 += (long)(16.0 * freq / 1000.0);
                        if (shakeNeg.OnCursorMove(200 + k * 20, 300, simT2, 144, true, false))
                        {
                            falseShake = true;
                        }
                    }

                    ColorPalette customPal = AppConfig.GetPalette(PaletteKind.Custom, "#A78BFA");
                    bool customPaletteOk = customPal.HaloR > 0.6f && customPal.HaloB > 0.9f && customPal.CoreR > customPal.HaloR;

                    int headerSize = Marshal.SizeOf(typeof(NativeMethods.RAWINPUTHEADER));
                    bool headerOk = (IntPtr.Size == 8 && headerSize == 24);
                    bool fullscreenBusy = NativeMethods.IsFullscreenBusy();

                    bool ulwOk = false;
                    int ulwErr = 0;
                    IntPtr hInst = NativeMethods.GetModuleHandleW(null);
                    NativeMethods.WndProcDelegate testWndProc = new NativeMethods.WndProcDelegate(SelfTestWndProc);
                    NativeMethods.WNDCLASSEXW wcex = new NativeMethods.WNDCLASSEXW();
                    wcex.cbSize = (uint)Marshal.SizeOf(typeof(NativeMethods.WNDCLASSEXW));
                    wcex.lpfnWndProc = testWndProc;
                    wcex.hInstance = hInst;
                    wcex.lpszClassName = "BibataIceTrailSelfTestClass";
                    NativeMethods.RegisterClassExW(ref wcex);

                    int exStyle = NativeMethods.WS_EX_LAYERED
                                | NativeMethods.WS_EX_TRANSPARENT
                                | NativeMethods.WS_EX_TOPMOST
                                | NativeMethods.WS_EX_TOOLWINDOW
                                | NativeMethods.WS_EX_NOACTIVATE;
                    IntPtr testHwnd = NativeMethods.CreateWindowExW(
                        exStyle,
                        "BibataIceTrailSelfTestClass",
                        "BibataSelfTest",
                        NativeMethods.WS_POPUP,
                        0, 0, 1, 1,
                        IntPtr.Zero, IntPtr.Zero, hInst, IntPtr.Zero);
                    if (testHwnd != IntPtr.Zero && ok)
                    {
                        NativeMethods.POINT ptDst = new NativeMethods.POINT();
                        ptDst.X = bx;
                        ptDst.Y = by;
                        NativeMethods.SIZE sz = new NativeMethods.SIZE();
                        sz.cx = bw;
                        sz.cy = bh;
                        NativeMethods.POINT ptSrc = new NativeMethods.POINT();
                        ptSrc.X = 0;
                        ptSrc.Y = 0;
                        NativeMethods.BLENDFUNCTION blend = new NativeMethods.BLENDFUNCTION();
                        blend.BlendOp = NativeMethods.AC_SRC_OVER;
                        blend.BlendFlags = 0;
                        blend.SourceConstantAlpha = 255;
                        blend.AlphaFormat = NativeMethods.AC_SRC_ALPHA;
                        ulwOk = NativeMethods.UpdateLayeredWindow(testHwnd, IntPtr.Zero, ref ptDst, ref sz, renderer.MemDC, ref ptSrc, 0, ref blend, NativeMethods.ULW_ALPHA);
                        ulwErr = Marshal.GetLastWin32Error();
                        NativeMethods.DestroyWindow(testHwnd);
                    }
                    GC.KeepAlive(testWndProc);

                    bool ridOk = false;
                    int ridErr = 0;
                    NativeWindow msgWin = new NativeWindow();
                    try
                    {
                        CreateParams cp = new CreateParams();
                        cp.Caption = "BibataSelfTestSink";
                        cp.Parent = new IntPtr(-3);
                        msgWin.CreateHandle(cp);
                        NativeMethods.RAWINPUTDEVICE[] rid = new NativeMethods.RAWINPUTDEVICE[1];
                        rid[0].usUsagePage = 0x01;
                        rid[0].usUsage = 0x02;
                        rid[0].dwFlags = NativeMethods.RIDEV_INPUTSINK;
                        rid[0].hwndTarget = msgWin.Handle;
                        ridOk = NativeMethods.RegisterRawInputDevices(rid, 1, (uint)Marshal.SizeOf(typeof(NativeMethods.RAWINPUTDEVICE)));
                        ridErr = Marshal.GetLastWin32Error();
                    }
                    finally
                    {
                        if (msgWin.Handle != IntPtr.Zero) msgWin.DestroyHandle();
                    }

                    AppConfig defaultCfg = new AppConfig(string.Empty);
                    bool silentDefaultOk = (!defaultCfg.ShowTrayIcon && defaultCfg.HotkeyEnabled && defaultCfg.ScrollGlowEnabled);

                    // PinkBlue dynamic gradient self-test
                    ColorPalette pbPal = AppConfig.GetPalette(PaletteKind.PinkBlue, "#A78BFA");
                    int pbx, pby, pbw, pbh;
                    bool pbOk = renderer.RenderFrame(samples, samples.Length, true, ripples, ripples.Length, true, 720, 300, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, pbPal, out pbx, out pby, out pbw, out pbh);
                    int pbPixels = 0;
                    bool pbHasPink = false;
                    bool pbHasBlue = false;
                    if (pbOk && renderer.DibBits != IntPtr.Zero)
                    {
                        uint* dibBase = (uint*)renderer.DibBits.ToPointer();
                        int stride = renderer.DibWidth;
                        for (int y = 0; y < pbh; y++)
                        {
                            uint* row = dibBase + y * stride;
                            for (int x = 0; x < pbw; x++)
                            {
                                uint px = row[x];
                                byte a = (byte)(px >> 24);
                                byte r = (byte)((px >> 16) & 0xFF);
                                byte g = (byte)((px >> 8) & 0xFF);
                                byte b = (byte)(px & 0xFF);
                                if (a > 0) pbPixels++;
                                if (r > a || g > a || b > a) alphaViolations++;
                                if ((int)r > (int)b + 8) pbHasPink = true;
                                if ((int)b > (int)r + 8) pbHasBlue = true;
                            }
                        }
                    }
                    bool pinkBlueGradientOk = pbOk && pbPixels >= 100 && pbHasPink && pbHasBlue;

                    // Rainbow dynamic gradient self-test
                    ColorPalette rbPal = AppConfig.GetPalette(PaletteKind.Rainbow, "#A78BFA");
                    int rbx, rby, rbw, rbh;
                    bool rbOk = renderer.RenderFrame(samples, samples.Length, true, ripples, ripples.Length, true, 720, 300, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, rbPal, out rbx, out rby, out rbw, out rbh);
                    int rbPixels = 0;
                    int maxRB = 0;
                    int maxBR = 0;
                    int maxGR = 0;
                    if (rbOk && renderer.DibBits != IntPtr.Zero)
                    {
                        uint* dibBase = (uint*)renderer.DibBits.ToPointer();
                        int stride = renderer.DibWidth;
                        for (int y = 0; y < rbh; y++)
                        {
                            uint* row = dibBase + y * stride;
                            for (int x = 0; x < rbw; x++)
                            {
                                uint px = row[x];
                                byte a = (byte)(px >> 24);
                                byte r = (byte)((px >> 16) & 0xFF);
                                byte g = (byte)((px >> 8) & 0xFF);
                                byte b = (byte)(px & 0xFF);
                                if (a > 0) rbPixels++;
                                if (r > a || g > a || b > a) alphaViolations++;
                                int diffRB = (int)r - (int)b;
                                int diffBR = (int)b - (int)r;
                                int diffGR = (int)g - (int)r;
                                if (diffRB > maxRB) maxRB = diffRB;
                                if (diffBR > maxBR) maxBR = diffBR;
                                if (diffGR > maxGR) maxGR = diffGR;
                            }
                        }
                    }
                    bool rainbowGradientOk = rbOk && rbPixels >= 100 && maxRB > 12 && maxBR > 12 && maxGR > 12;

                    // Scroll-wheel directional arc check (upward scroll -> pixels strictly above cursor Y=400)
                    int sbx, sby, sbw, sbh;
                    bool sbOk = renderer.RenderFrame(null, 0, false, null, 0, false, 500, 400, -1.0f, 0.0f, 0.0f, 1, 0.25f, -1.0f, nowTicks, 144, preset, palette, out sbx, out sby, out sbw, out sbh);
                    int scrollPixels = 0;
                    bool scrollUpperOnly = true;
                    if (sbOk && renderer.DibBits != IntPtr.Zero)
                    {
                        uint* dibBase = (uint*)renderer.DibBits.ToPointer();
                        int stride = renderer.DibWidth;
                        for (int y = 0; y < sbh; y++)
                        {
                            uint* row = dibBase + y * stride;
                            for (int x = 0; x < sbw; x++)
                            {
                                uint px = row[x];
                                byte a = (byte)(px >> 24);
                                byte r = (byte)((px >> 16) & 0xFF);
                                byte g = (byte)((px >> 8) & 0xFF);
                                byte b = (byte)(px & 0xFF);
                                if (a > 0)
                                {
                                    scrollPixels++;
                                    if (sby + y >= 400) scrollUpperOnly = false;
                                }
                                if (r > a || g > a || b > a) alphaViolations++;
                            }
                        }
                    }
                    bool scrollArcOk = sbOk && scrollPixels >= 30 && scrollUpperOnly;

                    // Palette cycle preview ring check
                    int pvx, pvy, pvw, pvh;
                    bool pvOk = renderer.RenderFrame(null, 0, false, null, 0, false, 500, 400, -1.0f, 0.0f, 0.0f, 0, -1.0f, 0.30f, nowTicks, 144, preset, pbPal, out pvx, out pvy, out pvw, out pvh);
                    int previewPixels = 0;
                    if (pvOk && renderer.DibBits != IntPtr.Zero)
                    {
                        uint* dibBase = (uint*)renderer.DibBits.ToPointer();
                        int stride = renderer.DibWidth;
                        for (int y = 0; y < pvh; y++)
                        {
                            uint* row = dibBase + y * stride;
                            for (int x = 0; x < pvw; x++)
                            {
                                uint px = row[x];
                                byte a = (byte)(px >> 24);
                                byte r = (byte)((px >> 16) & 0xFF);
                                byte g = (byte)((px >> 8) & 0xFF);
                                byte b = (byte)(px & 0xFF);
                                if (a > 0) previewPixels++;
                                if (r > a || g > a || b > a) alphaViolations++;
                            }
                        }
                    }
                    bool previewOk = pvOk && previewPixels >= 80;

                    report.AppendLine(string.Format(CultureInfo.InvariantCulture,
                        "ok={0} bbox=({1},{2},{3},{4}) nonZeroPixels={5} clickOnlyOk={6} clickPixels={7} extraOk={8} extraPixels={9} shakeDetected={10} falseShake={11} customPaletteOk={12} pinkBlueGradientOk={13} rainbowGradientOk={14} scrollArcOk={15} previewOk={16} silentDefaultOk={17} headerSize={18} alphaViolations={19} elapsedMs={20:F3} fullscreenBusy={21} ulwOk={22} ulwErr={23} ridOk={24} ridErr={25}",
                        ok, bx, by, bw, bh, nonZeroPixels, clickOnlyOk, clickPixels, extraOk, extraPixels, shakeDetected, falseShake, customPaletteOk, pinkBlueGradientOk, rainbowGradientOk, scrollArcOk, previewOk, silentDefaultOk, headerSize, alphaViolations, sw.Elapsed.TotalMilliseconds, fullscreenBusy, ulwOk, ulwErr, ridOk, ridErr));

                    if (!string.IsNullOrEmpty(logPath))
                    {
                        File.WriteAllText(logPath, report.ToString(), Encoding.UTF8);
                    }

                    if (!ok || nonZeroPixels < 100 || !clickOnlyOk || clickPixels < 100 || !extraOk || extraPixels < 100 || !shakeDetected || falseShake || !customPaletteOk || !pinkBlueGradientOk || !rainbowGradientOk || !scrollArcOk || !previewOk || !silentDefaultOk || !headerOk || alphaViolations != 0 || fullscreenBusy || !ulwOk || !ridOk)
                    {
                        return 1;
                    }
                    return 0;
                }
            }
            catch (Exception ex)
            {
                report.AppendLine("EXCEPTION: " + ex.ToString());
                if (!string.IsNullOrEmpty(logPath))
                {
                    File.WriteAllText(logPath, report.ToString(), Encoding.UTF8);
                }
                return 2;
            }
        }
    }
}
