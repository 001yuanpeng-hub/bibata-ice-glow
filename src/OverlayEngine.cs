using System;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;

namespace BibataIceTrail
{
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
            if (!CreateOverlayWindow())
            {
                AppLogger.Warn("Failed to create overlay window (err=" + Marshal.GetLastWin32Error().ToString(CultureInfo.InvariantCulture) + ").");
                return;
            }

            using (TrailRenderer renderer = new TrailRenderer())
            {
                TrailSample[] snapshot = new TrailSample[512];
                ClickRipple[] rippleSnapshot = new ClickRipple[16];
                bool isShown = false;
                long lastFullscreenCheck = 0;
                bool fullscreenPaused = false;
                long fullscreenInterval = (long)(0.30 * Stopwatch.Frequency);
                long idleSinceTicks = 0;
                long trimDelayTicks = (long)(3.0 * Stopwatch.Frequency);
                long lastZRefreshTicks = 0;
                long zRefreshInterval = (long)(0.25 * Stopwatch.Frequency);
                int lastIdleX = int.MinValue;
                int lastIdleY = int.MinValue;
                uint cachedDpi = 96;
                int cachedDpiX = int.MinValue;
                int cachedDpiY = int.MinValue;
                long cachedDpiTicks = 0;
                long dpiCacheInterval = Stopwatch.Frequency / 5L;

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
                        if (renderer.TrimIfOversized())
                        {
                            TrailRenderer.CompactManagedHeapOnce();
                        }
                        idleSinceTicks = 0;
                        _buffer.Clear();
                        _ripples.Clear();
                        _interaction.Clear();
                        if (fullscreenPaused && enabled && (trailEnabled || rippleEnabled || dragEnabled || shakeEnabled || scrollEnabled))
                        {
                            if (_stopEvent.WaitOne(250)) break;
                            continue;
                        }
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
                        if (!WaitAndHandleIdle(
                            renderer, waitHandles, nowTicks, trimDelayTicks,
                            trailEnabled, shakeEnabled, dragEnabled,
                            ref isShown, ref idleSinceTicks, ref lastIdleX, ref lastIdleY))
                        {
                            break;
                        }
                        continue;
                    }

                    int dpiX, dpiY;
                    if (!TryResolveAnchorPoint(gotCursor, curPt.X, curPt.Y, snapshot, count, rippleSnapshot, rippleCount, out dpiX, out dpiY))
                    {
                        if (!WaitAndHandleIdle(
                            renderer, waitHandles, nowTicks, trimDelayTicks,
                            trailEnabled, shakeEnabled, dragEnabled,
                            ref isShown, ref idleSinceTicks, ref lastIdleX, ref lastIdleY))
                        {
                            break;
                        }
                        continue;
                    }
                    long dpiAge = nowTicks - cachedDpiTicks;
                    int ddx = dpiX - cachedDpiX;
                    int ddy = dpiY - cachedDpiY;
                    if (cachedDpiTicks == 0 || dpiAge < 0 || dpiAge >= dpiCacheInterval || ddx > 64 || ddx < -64 || ddy > 64 || ddy < -64)
                    {
                        cachedDpi = NativeMethods.GetDpiAtPoint(dpiX, dpiY);
                        cachedDpiX = dpiX;
                        cachedDpiY = dpiY;
                        cachedDpiTicks = nowTicks;
                    }
                    uint dpi = cachedDpi;

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
                        if (!WaitAndHandleIdle(
                            renderer, waitHandles, nowTicks, trimDelayTicks,
                            trailEnabled, shakeEnabled, dragEnabled,
                            ref isShown, ref idleSinceTicks, ref lastIdleX, ref lastIdleY))
                        {
                            break;
                        }
                        continue;
                    }

                    idleSinceTicks = 0;

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
                        lastZRefreshTicks = nowTicks;
                    }
                    else if ((nowTicks - lastZRefreshTicks) >= zRefreshInterval)
                    {
                        NativeMethods.SetWindowPos(
                            _hwnd,
                            NativeMethods.HWND_TOPMOST,
                            0, 0, 0, 0,
                            NativeMethods.SWP_NOMOVE | NativeMethods.SWP_NOSIZE | NativeMethods.SWP_NOACTIVATE);
                        lastZRefreshTicks = nowTicks;
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
            NativeMethods.UnregisterClassW("BibataIceTrailOverlayClass", NativeMethods.GetModuleHandleW(null));
        }

        internal static bool TryResolveAnchorPoint(
            bool gotCursor,
            int curX,
            int curY,
            TrailSample[] snapshot,
            int count,
            ClickRipple[] ripples,
            int rippleCount,
            out int outX,
            out int outY)
        {
            if (gotCursor)
            {
                outX = curX;
                outY = curY;
                return true;
            }
            if (snapshot != null && count > 0)
            {
                outX = snapshot[count - 1].X;
                outY = snapshot[count - 1].Y;
                return true;
            }
            if (ripples != null && rippleCount > 0)
            {
                outX = ripples[rippleCount - 1].X;
                outY = ripples[rippleCount - 1].Y;
                return true;
            }
            outX = 0;
            outY = 0;
            return false;
        }

        private bool WaitAndHandleIdle(
            TrailRenderer renderer,
            IntPtr[] waitHandles,
            long nowTicks,
            long trimDelayTicks,
            bool trailEnabled,
            bool shakeEnabled,
            bool dragEnabled,
            ref bool isShown,
            ref long idleSinceTicks,
            ref int lastIdleX,
            ref int lastIdleY)
        {
            if (isShown)
            {
                NativeMethods.ShowWindow(_hwnd, NativeMethods.SW_HIDE);
                isShown = false;
            }
            if (idleSinceTicks == 0)
            {
                idleSinceTicks = nowTicks;
            }
            else if ((nowTicks - idleSinceTicks) >= trimDelayTicks)
            {
                if (renderer.TrimIfOversized())
                {
                    TrailRenderer.CompactManagedHeapOnce();
                }
                idleSinceTicks = nowTicks;
            }
            uint idleTimeoutMs = (idleSinceTicks != 0 && (nowTicks - idleSinceTicks) >= (Stopwatch.Frequency * 2L)) ? 150u : 25u;
            uint waitRes = NativeMethods.MsgWaitForMultipleObjects(2, waitHandles, false, idleTimeoutMs, NativeMethods.QS_ALLINPUT);
            if (waitRes == NativeMethods.WAIT_OBJECT_0 + 1) return false;
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
            return true;
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
}
