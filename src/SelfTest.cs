using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BibataIceTrail
{
    internal static partial class Program
    {
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
                    try
                    {
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
                        }
                    }
                    finally
                    {
                        if (testHwnd != IntPtr.Zero)
                        {
                            NativeMethods.DestroyWindow(testHwnd);
                        }
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

                    TrailSample[] bigSamples = new TrailSample[3];
                    bigSamples[0].X = 200;
                    bigSamples[0].Y = 200;
                    bigSamples[0].Ticks = nowTicks - (long)(30.0 * freq / 1000.0);
                    bigSamples[0].StrokeId = 1;
                    bigSamples[1].X = 500;
                    bigSamples[1].Y = 360;
                    bigSamples[1].Ticks = nowTicks - (long)(15.0 * freq / 1000.0);
                    bigSamples[1].StrokeId = 1;
                    bigSamples[2].X = 800;
                    bigSamples[2].Y = 520;
                    bigSamples[2].Ticks = nowTicks;
                    bigSamples[2].StrokeId = 1;
                    int lbx, lby, lbw, lbh;
                    bool bigOk = renderer.RenderFrame(bigSamples, 3, true, null, 0, false, 800, 520, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, pbPal, out lbx, out lby, out lbw, out lbh);
                    bool didTrim = renderer.TrimIfOversized();
                    int recX, recY, recW, recH;
                    bool recOk = renderer.RenderFrame(null, 0, true, ripples, ripples.Length, true, 720, 300, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, palette, out recX, out recY, out recW, out recH);
                    int recPixels = 0;
                    if (recOk && renderer.DibBits != IntPtr.Zero)
                    {
                        uint* dibBase = (uint*)renderer.DibBits.ToPointer();
                        int stride = renderer.DibWidth;
                        for (int y = 0; y < recH; y++)
                        {
                            uint* row = dibBase + y * stride;
                            for (int x = 0; x < recW; x++)
                            {
                                uint px = row[x];
                                byte a = (byte)(px >> 24);
                                byte r = (byte)((px >> 16) & 0xFF);
                                byte g = (byte)((px >> 8) & 0xFF);
                                byte b = (byte)(px & 0xFF);
                                if (a > 0) recPixels++;
                                if (r > a || g > a || b > a) alphaViolations++;
                            }
                        }
                    }
                    bool trimRecoverOk = bigOk && didTrim && recOk && recPixels >= 100;

                    List<CursorSizeManager.RuntimeSchemeRecord> rtSrc = new List<CursorSizeManager.RuntimeSchemeRecord>();
                    CursorSizeManager.RuntimeSchemeRecord rtSample = new CursorSizeManager.RuntimeSchemeRecord();
                    rtSample.Name = "Bibata-Modern-Ice (Large)";
                    rtSample.ExistedBefore = true;
                    rtSample.PreviousKind = "ExpandString";
                    rtSample.PreviousValue = @"%SystemRoot%\cursors\aero_arrow.cur,C:\My ""Cur""\a.cur";
                    rtSample.WrittenValue = @"D:\Cursors\Large\Pointer.cur";
                    rtSrc.Add(rtSample);
                    string rtJson = CursorSizeManager.SerializeRuntimeSchemeRecords(rtSrc);
                    List<CursorSizeManager.RuntimeSchemeRecord> rtParsed;
                    bool runtimeSchemeJsonOk =
                        CursorSizeManager.TryParseRuntimeSchemeRecords(rtJson, out rtParsed) &&
                        rtParsed.Count == 1 &&
                        string.Equals(rtParsed[0].Name, rtSample.Name, StringComparison.Ordinal) &&
                        rtParsed[0].ExistedBefore == true &&
                        string.Equals(rtParsed[0].PreviousKind, "ExpandString", StringComparison.Ordinal) &&
                        string.Equals(rtParsed[0].PreviousValue, rtSample.PreviousValue, StringComparison.Ordinal) &&
                        string.Equals(rtParsed[0].WrittenValue, rtSample.WrittenValue, StringComparison.Ordinal);

                    bool cursorSizeLogicOk =
                        runtimeSchemeJsonOk &&
                        string.Equals(CursorSizeManager.ParseSizeFromFolderName("Bibata-Modern-Ice-Large-Windows"), "Large", StringComparison.Ordinal) &&
                        string.Equals(CursorSizeManager.ParseSizeFromFolderName("Bibata-Original-Ice-Extra-Large-Windows"), "Extra-Large", StringComparison.Ordinal) &&
                        string.Equals(CursorSizeManager.GetNextSize("Regular"), "Large", StringComparison.Ordinal) &&
                        string.Equals(CursorSizeManager.GetNextSize("Large"), "Extra-Large", StringComparison.Ordinal) &&
                        string.Equals(CursorSizeManager.GetNextSize("Extra-Large"), "Regular", StringComparison.Ordinal);

                    int ax, ay;
                    bool noAnchor = OverlayEngine.TryResolveAnchorPoint(false, 0, 0, samples, 0, ripples, 0, out ax, out ay);
                    bool oneSampleAnchor = OverlayEngine.TryResolveAnchorPoint(false, 0, 0, samples, 1, ripples, 0, out ax, out ay) &&
                                           ax == samples[0].X && ay == samples[0].Y;
                    bool nextValidAnchor = OverlayEngine.TryResolveAnchorPoint(true, 500, 400, samples, 0, ripples, 0, out ax, out ay) &&
                                           ax == 500 && ay == 400;
                    int rvx, rvy, rvw, rvh;
                    bool nextFrameOk = renderer.RenderFrame(null, 0, false, null, 0, false, ax, ay, -1.0f, 0.0f, 0.0f, 1, 0.25f, 0.30f, nowTicks, 144, preset, palette, out rvx, out rvy, out rvw, out rvh);
                    int nextPixels = 0;
                    if (nextFrameOk && renderer.DibBits != IntPtr.Zero)
                    {
                        uint* dibBase = (uint*)renderer.DibBits.ToPointer();
                        int stride = renderer.DibWidth;
                        for (int y = 0; y < rvh; y++)
                        {
                            uint* row = dibBase + y * stride;
                            for (int x = 0; x < rvw; x++)
                            {
                                uint px = row[x];
                                byte a = (byte)(px >> 24);
                                byte r = (byte)((px >> 16) & 0xFF);
                                byte g = (byte)((px >> 8) & 0xFF);
                                byte b = (byte)(px & 0xFF);
                                if (a > 0) nextPixels++;
                                if (r > a || g > a || b > a) alphaViolations++;
                            }
                        }
                    }
                    bool missingAnchorOk = !noAnchor && oneSampleAnchor && nextValidAnchor && nextFrameOk && nextPixels >= 80;

                    // Multi-monitor rapid click clamping checks
                    ClickRipple[] mmLR = new ClickRipple[2];
                    mmLR[0].X = 140; mmLR[0].Y = 450; mmLR[0].Ticks = nowTicks - (long)(100.0 * freq / 1000.0); mmLR[0].Kind = 0;
                    mmLR[1].X = 3320; mmLR[1].Y = 450; mmLR[1].Ticks = nowTicks - (long)(30.0 * freq / 1000.0); mmLR[1].Kind = 0;
                    int mlrx, mlry, mlrw, mlrh;
                    bool mmLROk = renderer.RenderFrame(null, 0, false, mmLR, 2, true, 3320, 450, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, palette, out mlrx, out mlry, out mlrw, out mlrh);
                    int mmLRNewPx = mmLROk ? CountVisiblePixelsNear(renderer, mlrx, mlry, mlrw, mlrh, 3320, 450, 64, ref alphaViolations) : 0;

                    ClickRipple[] mmRL = new ClickRipple[2];
                    mmRL[0].X = 3320; mmRL[0].Y = 450; mmRL[0].Ticks = nowTicks - (long)(100.0 * freq / 1000.0); mmRL[0].Kind = 0;
                    mmRL[1].X = 140; mmRL[1].Y = 450; mmRL[1].Ticks = nowTicks - (long)(30.0 * freq / 1000.0); mmRL[1].Kind = 0;
                    int mrlx, mrly, mrlw, mrlh;
                    bool mmRLOk = renderer.RenderFrame(null, 0, false, mmRL, 2, true, 140, 450, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, palette, out mrlx, out mrly, out mrlw, out mrlh);
                    int mmRLNewPx = mmRLOk ? CountVisiblePixelsNear(renderer, mrlx, mrly, mrlw, mrlh, 140, 450, 64, ref alphaViolations) : 0;

                    ClickRipple[] mmTB = new ClickRipple[2];
                    mmTB[0].X = 500; mmTB[0].Y = 120; mmTB[0].Ticks = nowTicks - (long)(100.0 * freq / 1000.0); mmTB[0].Kind = 0;
                    mmTB[1].X = 500; mmTB[1].Y = 2100; mmTB[1].Ticks = nowTicks - (long)(30.0 * freq / 1000.0); mmTB[1].Kind = 0;
                    int mtbx, mtby, mtbw, mtbh;
                    bool mmTBOk = renderer.RenderFrame(null, 0, false, mmTB, 2, true, 500, 2100, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, palette, out mtbx, out mtby, out mtbw, out mtbh);
                    int mmTBNewPx = mmTBOk ? CountVisiblePixelsNear(renderer, mtbx, mtby, mtbw, mtbh, 500, 2100, 64, ref alphaViolations) : 0;

                    ClickRipple[] mmBT = new ClickRipple[2];
                    mmBT[0].X = 500; mmBT[0].Y = 2100; mmBT[0].Ticks = nowTicks - (long)(100.0 * freq / 1000.0); mmBT[0].Kind = 0;
                    mmBT[1].X = 500; mmBT[1].Y = 120; mmBT[1].Ticks = nowTicks - (long)(30.0 * freq / 1000.0); mmBT[1].Kind = 0;
                    int mbtx, mbty, mbtw, mbth;
                    bool mmBTOk = renderer.RenderFrame(null, 0, false, mmBT, 2, true, 500, 120, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, palette, out mbtx, out mbty, out mbtw, out mbth);
                    int mmBTNewPx = mmBTOk ? CountVisiblePixelsNear(renderer, mbtx, mbty, mbtw, mbth, 500, 120, 64, ref alphaViolations) : 0;

                    ClickRipple[] mmNear = new ClickRipple[2];
                    mmNear[0].X = 720; mmNear[0].Y = 300; mmNear[0].Ticks = nowTicks - (long)(100.0 * freq / 1000.0); mmNear[0].Kind = 0;
                    mmNear[1].X = 760; mmNear[1].Y = 330; mmNear[1].Ticks = nowTicks - (long)(30.0 * freq / 1000.0); mmNear[1].Kind = 0;

                    ClickRipple[] mmNearOldOnly = new ClickRipple[1];
                    mmNearOldOnly[0] = mmNear[0];
                    int mnox, mnoy, mnow, mnoh;
                    bool mmNearOldOnlyOk = renderer.RenderFrame(null, 0, false, mmNearOldOnly, 1, true, 760, 330, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, palette, out mnox, out mnoy, out mnow, out mnoh);
                    CapturedFrame frameOldOnly = mmNearOldOnlyOk ? CaptureRenderedFrame(renderer, mnox, mnoy, mnow, mnoh, ref alphaViolations) : null;

                    ClickRipple[] mmNearNewOnly = new ClickRipple[1];
                    mmNearNewOnly[0] = mmNear[1];
                    int mnnx, mnny, mnnw, mnnh;
                    bool mmNearNewOnlyOk = renderer.RenderFrame(null, 0, false, mmNearNewOnly, 1, true, 760, 330, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, palette, out mnnx, out mnny, out mnnw, out mnnh);
                    CapturedFrame frameNewOnly = mmNearNewOnlyOk ? CaptureRenderedFrame(renderer, mnnx, mnny, mnnw, mnnh, ref alphaViolations) : null;

                    int mnx, mny, mnw, mnh;
                    bool mmNearOk = renderer.RenderFrame(null, 0, false, mmNear, 2, true, 760, 330, -1.0f, 0.0f, 0.0f, 0, -1.0f, -1.0f, nowTicks, 144, preset, palette, out mnx, out mny, out mnw, out mnh);
                    CapturedFrame frameBoth = mmNearOk ? CaptureRenderedFrame(renderer, mnx, mny, mnw, mnh, ref alphaViolations) : null;

                    int mmNearOldDeltaPx = 0;
                    int mmNearNewDeltaPx = 0;
                    bool mmNearBothOk =
                        frameOldOnly != null && frameNewOnly != null && frameBoth != null &&
                        VerifyBothRipplesVisible(frameBoth, frameOldOnly, frameNewOnly, 80, out mmNearNewDeltaPx, out mmNearOldDeltaPx);

                    int dropNewA = 0;
                    int dropNewB = 0;
                    bool dropNewRejected =
                        frameOldOnly != null && frameNewOnly != null &&
                        !VerifyBothRipplesVisible(frameOldOnly, frameOldOnly, frameNewOnly, 80, out dropNewA, out dropNewB) &&
                        dropNewA == 0 && dropNewB >= 0;

                    int dropOldA = 0;
                    int dropOldB = 0;
                    bool dropOldRejected =
                        frameOldOnly != null && frameNewOnly != null &&
                        !VerifyBothRipplesVisible(frameNewOnly, frameOldOnly, frameNewOnly, 80, out dropOldA, out dropOldB) &&
                        dropOldB == 0 && dropOldA >= 0;

                    bool mmNearDropCheck = dropNewRejected && dropOldRejected;

                    bool multiMonitorRippleOk =
                        mmLROk && mlrw <= 2560 && mlrh <= 1600 && mmLRNewPx >= 80 &&
                        mmRLOk && mrlw <= 2560 && mrlh <= 1600 && mmRLNewPx >= 80 &&
                        mmTBOk && mtbw <= 2560 && mtbh <= 1600 && mmTBNewPx >= 80 &&
                        mmBTOk && mbtw <= 2560 && mbth <= 1600 && mmBTNewPx >= 80 &&
                        mmNearOk && mnw <= 2560 && mnh <= 1600 && mmNearBothOk && mmNearDropCheck;

                    report.AppendLine(string.Format(CultureInfo.InvariantCulture,
                        "ok={0} bbox=({1},{2},{3},{4}) nonZeroPixels={5} clickOnlyOk={6} clickPixels={7} extraOk={8} extraPixels={9} shakeDetected={10} falseShake={11} customPaletteOk={12} pinkBlueGradientOk={13} rainbowGradientOk={14} scrollArcOk={15} previewOk={16} trimRecoverOk={17} missingAnchorOk={18} multiMonitorRippleOk={19} mmPx=({20},{21},{22},{23}) mmNearDelta=({24}/{25}) mmNearDropCheck={26} cursorSizeLogicOk={27} silentDefaultOk={28} headerSize={29} alphaViolations={30} elapsedMs={31:F3} fullscreenBusy={32} ulwOk={33} ulwErr={34} ridOk={35} ridErr={36}",
                        ok, bx, by, bw, bh, nonZeroPixels, clickOnlyOk, clickPixels, extraOk, extraPixels, shakeDetected, falseShake, customPaletteOk, pinkBlueGradientOk, rainbowGradientOk, scrollArcOk, previewOk, trimRecoverOk, missingAnchorOk, multiMonitorRippleOk, mmLRNewPx, mmRLNewPx, mmTBNewPx, mmBTNewPx, mmNearOldDeltaPx, mmNearNewDeltaPx, mmNearDropCheck, cursorSizeLogicOk, silentDefaultOk, headerSize, alphaViolations, sw.Elapsed.TotalMilliseconds, fullscreenBusy, ulwOk, ulwErr, ridOk, ridErr));

                    if (!string.IsNullOrEmpty(logPath))
                    {
                        File.WriteAllText(logPath, report.ToString(), Encoding.UTF8);
                    }

                    if (!ok || nonZeroPixels < 100 || !clickOnlyOk || clickPixels < 100 || !extraOk || extraPixels < 100 || !shakeDetected || falseShake || !customPaletteOk || !pinkBlueGradientOk || !rainbowGradientOk || !scrollArcOk || !previewOk || !trimRecoverOk || !missingAnchorOk || !multiMonitorRippleOk || !cursorSizeLogicOk || !silentDefaultOk || !headerOk || alphaViolations != 0 || !ulwOk || !ridOk)
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

        private static unsafe int CountVisiblePixelsNear(
            TrailRenderer renderer,
            int bx,
            int by,
            int bw,
            int bh,
            int targetX,
            int targetY,
            int radius,
            ref int alphaViolations)
        {
            if (renderer.DibBits == IntPtr.Zero || bw <= 0 || bh <= 0) return 0;
            int x0 = targetX - radius;
            int y0 = targetY - radius;
            int x1 = targetX + radius;
            int y1 = targetY + radius;
            if (x0 < bx) x0 = bx;
            if (y0 < by) y0 = by;
            if (x1 >= bx + bw) x1 = bx + bw - 1;
            if (y1 >= by + bh) y1 = by + bh - 1;
            if (x0 > x1 || y0 > y1) return 0;

            int count = 0;
            uint* dibBase = (uint*)renderer.DibBits.ToPointer();
            int stride = renderer.DibWidth;
            for (int sy = y0; sy <= y1; sy++)
            {
                uint* row = dibBase + (sy - by) * stride;
                for (int sx = x0; sx <= x1; sx++)
                {
                    uint px = row[sx - bx];
                    byte a = (byte)(px >> 24);
                    byte r = (byte)((px >> 16) & 0xFF);
                    byte g = (byte)((px >> 8) & 0xFF);
                    byte b = (byte)(px & 0xFF);
                    if (a > 0) count++;
                    if (r > a || g > a || b > a) alphaViolations++;
                }
            }
            return count;
        }

        private sealed class CapturedFrame
        {
            public int X;
            public int Y;
            public int W;
            public int H;
            public uint[] Pixels;
        }

        private static unsafe CapturedFrame CaptureRenderedFrame(
            TrailRenderer renderer,
            int bx,
            int by,
            int bw,
            int bh,
            ref int alphaViolations)
        {
            if (renderer.DibBits == IntPtr.Zero || bw <= 0 || bh <= 0) return null;
            CapturedFrame frame = new CapturedFrame();
            frame.X = bx;
            frame.Y = by;
            frame.W = bw;
            frame.H = bh;
            frame.Pixels = new uint[bw * bh];

            uint* dibBase = (uint*)renderer.DibBits.ToPointer();
            int stride = renderer.DibWidth;
            for (int y = 0; y < bh; y++)
            {
                uint* row = dibBase + y * stride;
                int dstRow = y * bw;
                for (int x = 0; x < bw; x++)
                {
                    uint px = row[x];
                    byte a = (byte)(px >> 24);
                    byte r = (byte)((px >> 16) & 0xFF);
                    byte g = (byte)((px >> 8) & 0xFF);
                    byte b = (byte)(px & 0xFF);
                    if (r > a || g > a || b > a) alphaViolations++;
                    frame.Pixels[dstRow + x] = px;
                }
            }
            return frame;
        }

        private static int CountDistinctVisiblePixels(CapturedFrame candidate, CapturedFrame baseline)
        {
            if (candidate == null || candidate.W <= 0 || candidate.H <= 0) return 0;
            int count = 0;
            for (int y = 0; y < candidate.H; y++)
            {
                int sy = candidate.Y + y;
                int cRow = y * candidate.W;
                bool inBaseY = (baseline != null && sy >= baseline.Y && sy < baseline.Y + baseline.H);
                int bRow = inBaseY ? (sy - baseline.Y) * baseline.W : 0;
                for (int x = 0; x < candidate.W; x++)
                {
                    uint cPx = candidate.Pixels[cRow + x];
                    if ((cPx >> 24) == 0) continue;
                    int sx = candidate.X + x;
                    uint bPx = 0u;
                    if (inBaseY && sx >= baseline.X && sx < baseline.X + baseline.W)
                    {
                        bPx = baseline.Pixels[bRow + (sx - baseline.X)];
                    }
                    if (cPx != bPx)
                    {
                        count++;
                    }
                }
            }
            return count;
        }

        private static bool VerifyBothRipplesVisible(
            CapturedFrame combined,
            CapturedFrame oldOnly,
            CapturedFrame newOnly,
            int minDistinctPixels,
            out int newContribPx,
            out int oldContribPx)
        {
            newContribPx = CountDistinctVisiblePixels(combined, oldOnly);
            oldContribPx = CountDistinctVisiblePixels(combined, newOnly);
            return newContribPx >= minDistinctPixels && oldContribPx >= minDistinctPixels;
        }
    }
}
