using System;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace BibataIceTrail
{
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

    internal sealed class RawInputMessageWindow : NativeWindow, IDisposable
    {
        private const int HotkeyId = 1;
        private const int PaletteHotkeyId = 2;
        private const int CursorSizeHotkeyId = 3;
        private const int PresetHotkeyId = 4;

        private readonly SampleRingBuffer _buffer;
        private readonly ClickRippleBuffer _ripples;
        private readonly InteractionState _interaction;
        private readonly OverlayEngine _engine;
        private readonly Action _onHotkeyToggle;
        private readonly Action _onCyclePalette;
        private readonly Action _onCycleCursorSize;
        private readonly Action _onCyclePreset;
        private readonly byte[] _rawBuf = new byte[128];
        private readonly uint _rawHeaderSize;
        private bool _hotkeyRegistered;
        private bool _paletteHotkeyRegistered;
        private bool _cursorSizeHotkeyRegistered;
        private bool _presetHotkeyRegistered;
        private volatile bool _shakeEnabled = true;
        private volatile bool _dragEnabled = true;
        private volatile bool _scrollEnabled = true;
        private uint _cachedDpi = 96;
        private int _cachedDpiX = int.MinValue;
        private int _cachedDpiY = int.MinValue;
        private long _cachedDpiTicks;

        public RawInputMessageWindow(
            SampleRingBuffer buffer,
            ClickRippleBuffer ripples,
            InteractionState interaction,
            OverlayEngine engine,
            Action onHotkeyToggle,
            Action onCyclePalette,
            Action onCycleCursorSize,
            Action onCyclePreset)
        {
            _buffer = buffer;
            _ripples = ripples;
            _interaction = interaction;
            _engine = engine;
            _onHotkeyToggle = onHotkeyToggle;
            _onCyclePalette = onCyclePalette;
            _onCycleCursorSize = onCycleCursorSize;
            _onCyclePreset = onCyclePreset;
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
                    if (!_hotkeyRegistered) AppLogger.Warn("RegisterHotKey(Ctrl+Alt+Shift+G) failed (err=" + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture) + ").");
                }
                if (!_paletteHotkeyRegistered)
                {
                    _paletteHotkeyRegistered = NativeMethods.RegisterHotKey(Handle, PaletteHotkeyId, mods, NativeMethods.VK_C);
                    if (!_paletteHotkeyRegistered) AppLogger.Warn("RegisterHotKey(Ctrl+Alt+Shift+C) failed (err=" + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture) + ").");
                }
                if (!_cursorSizeHotkeyRegistered)
                {
                    _cursorSizeHotkeyRegistered = NativeMethods.RegisterHotKey(Handle, CursorSizeHotkeyId, mods, NativeMethods.VK_S);
                    if (!_cursorSizeHotkeyRegistered) AppLogger.Warn("RegisterHotKey(Ctrl+Alt+Shift+S) failed (err=" + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture) + ").");
                }
                if (!_presetHotkeyRegistered)
                {
                    _presetHotkeyRegistered = NativeMethods.RegisterHotKey(Handle, PresetHotkeyId, mods, NativeMethods.VK_D);
                    if (!_presetHotkeyRegistered) AppLogger.Warn("RegisterHotKey(Ctrl+Alt+Shift+D) failed (err=" + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture) + ").");
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
                if (_cursorSizeHotkeyRegistered)
                {
                    NativeMethods.UnregisterHotKey(Handle, CursorSizeHotkeyId);
                    _cursorSizeHotkeyRegistered = false;
                }
                if (_presetHotkeyRegistered)
                {
                    NativeMethods.UnregisterHotKey(Handle, PresetHotkeyId);
                    _presetHotkeyRegistered = false;
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
                else if (hkId == CursorSizeHotkeyId && _onCycleCursorSize != null)
                {
                    _onCycleCursorSize();
                }
                else if (hkId == PresetHotkeyId && _onCyclePreset != null)
                {
                    _onCyclePreset();
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
                        long dpiAge = nowTicks - _cachedDpiTicks;
                        int ddx = pt.X - _cachedDpiX;
                        int ddy = pt.Y - _cachedDpiY;
                        if (_cachedDpiTicks == 0 || dpiAge < 0 || dpiAge >= (Stopwatch.Frequency / 5L) || ddx > 64 || ddx < -64 || ddy > 64 || ddy < -64)
                        {
                            _cachedDpi = NativeMethods.GetDpiAtPoint(pt.X, pt.Y);
                            _cachedDpiX = pt.X;
                            _cachedDpiY = pt.Y;
                            _cachedDpiTicks = nowTicks;
                        }
                        _interaction.OnCursorMove(pt.X, pt.Y, nowTicks, _cachedDpi, shakeOn, dragOn);
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
            try
            {
                NativeMethods.RAWINPUTDEVICE[] rid = new NativeMethods.RAWINPUTDEVICE[1];
                rid[0].usUsagePage = 0x01;
                rid[0].usUsage = 0x02;
                rid[0].dwFlags = NativeMethods.RIDEV_REMOVE;
                rid[0].hwndTarget = IntPtr.Zero;
                NativeMethods.RegisterRawInputDevices(rid, 1, (uint)Marshal.SizeOf(typeof(NativeMethods.RAWINPUTDEVICE)));
            }
            catch
            {
            }
            if (Handle != IntPtr.Zero)
            {
                DestroyHandle();
            }
        }
    }
}
