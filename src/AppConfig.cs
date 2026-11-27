using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace BibataIceTrail
{
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
}
