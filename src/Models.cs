using System;

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
}
