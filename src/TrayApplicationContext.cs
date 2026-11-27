using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BibataIceTrail
{
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
        private readonly ContextMenuStrip _menu;
        private readonly Icon _activeIcon;
        private readonly Icon _pausedIcon;
        private bool _disposed;
        private bool _colorDialogOpen;
        private long _lastCursorSwitchTicks;

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
                new Action(CyclePalette),
                new Action(CycleCursorSize),
                new Action(CyclePreset));
            _inputSink.SetTrackingOptions(_config.ShakeLocateEnabled, _config.DragGlowEnabled, _config.ScrollGlowEnabled, _config.HotkeyEnabled);

            if (showTrayIcon)
            {
                _activeIcon = CreateTrayIcon(true);
                _pausedIcon = CreateTrayIcon(false);

                _notifyIcon = new NotifyIcon();
                _menu = BuildMenu();
                _notifyIcon.ContextMenuStrip = _menu;
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

            _itemHotkeyEnabled = new ToolStripMenuItem("全局快捷键 (G开关 / C换色 / S指针大小 / D光影大小)");
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

        private void CycleCursorSize()
        {
            long now = Stopwatch.GetTimestamp();
            double dtMs = (double)(now - _lastCursorSwitchTicks) * 1000.0 / (double)Stopwatch.Frequency;
            if (_lastCursorSwitchTicks > 0 && dtMs >= 0.0 && dtMs < 300.0)
            {
                return;
            }
            _lastCursorSwitchTicks = now;
            CursorSizeManager.CycleInstalledCursorSize(Application.ExecutablePath);
        }

        private void CyclePreset()
        {
            PresetKind next;
            if (_config.Preset == PresetKind.Light) next = PresetKind.Standard;
            else if (_config.Preset == PresetKind.Standard) next = PresetKind.Vivid;
            else next = PresetKind.Light;

            _config.Preset = next;
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
            Dispose();
            ExitThread();
        }

        protected override void Dispose(bool disposing)
        {
            if (!_disposed)
            {
                _disposed = true;
                if (disposing)
                {
                    if (_notifyIcon != null)
                    {
                        _notifyIcon.Visible = false;
                        _notifyIcon.Dispose();
                    }
                    if (_menu != null)
                    {
                        _menu.Dispose();
                    }
                    _inputSink.Dispose();
                    _engine.Dispose();
                    if (_activeIcon != null) _activeIcon.Dispose();
                    if (_pausedIcon != null) _pausedIcon.Dispose();
                }
            }
            base.Dispose(disposing);
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
}
