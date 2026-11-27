using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime;
using System.Runtime.InteropServices;

namespace BibataIceTrail
{
    internal sealed class TrailRenderer : IDisposable
    {
        private const int MaxFrameWidth = 2560;
        private const int MaxFrameHeight = 1600;

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
            bool hasNewestTrail = false;
            long newestTrailTicks = long.MinValue;
            int newestTrailX = 0;
            int newestTrailY = 0;
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
                            bool strokeVisible = false;
                            for (int i = before; i < _subdivNodes.Count; i++)
                            {
                                SplineNode n = _subdivNodes[i];
                                if (n.Env < 0.0f) continue;
                                if (n.Env > 0.01f && n.U > 0.01f) strokeVisible = true;
                                if (n.X < minX) minX = n.X;
                                if (n.Y < minY) minY = n.Y;
                                if (n.X > maxX) maxX = n.X;
                                if (n.Y > maxY) maxY = n.Y;
                            }
                            if (strokeVisible)
                            {
                                long sTicks = samples[end - 1].Ticks;
                                if (!hasNewestTrail || sTicks >= newestTrailTicks)
                                {
                                    hasNewestTrail = true;
                                    newestTrailTicks = sTicks;
                                    newestTrailX = samples[end - 1].X;
                                    newestTrailY = samples[end - 1].Y;
                                }
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
            long newestRippleTicks = long.MinValue;
            int newestRippleX = 0;
            int newestRippleY = 0;
            float newestRippleReach = 0.0f;
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
                    if (!hasAnyRipple || ripples[i].Ticks >= newestRippleTicks)
                    {
                        newestRippleTicks = ripples[i].Ticks;
                        newestRippleX = ripples[i].X;
                        newestRippleY = ripples[i].Y;
                        newestRippleReach = reach;
                    }
                    hasAnyRipple = true;
                }
            }

            float cursorEffectReach = 0.0f;
            bool hasShake = (shakeProgress >= 0.0f && shakeProgress < 1.0f);
            if (hasShake)
            {
                float shakeReach = 60.0f * scale;
                if (shakeReach > cursorEffectReach) cursorEffectReach = shakeReach;
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
                if (dragReach > cursorEffectReach) cursorEffectReach = dragReach;
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
                if (scrollReach > cursorEffectReach) cursorEffectReach = scrollReach;
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
                float prevReach = (12.0f + preset.RippleMaxRadius * 0.65f + preset.HaloRadius * 0.65f) * scale;
                if (prevReach > cursorEffectReach) cursorEffectReach = prevReach;
                float px = (float)cursorX;
                float py = (float)cursorY;
                if (px - prevReach < bMinX) bMinX = px - prevReach;
                if (py - prevReach < bMinY) bMinY = py - prevReach;
                if (px + prevReach > bMaxX) bMaxX = px + prevReach;
                if (py + prevReach > bMaxY) bMaxY = py + prevReach;
            }

            if (!hasTrail && !hasAnyRipple && !hasShake && !hasDrag && !hasScroll && !hasPreview) return false;

            int rawLeft = (int)Math.Floor(bMinX);
            int rawTop = (int)Math.Floor(bMinY);
            int rawRight = (int)Math.Ceiling(bMaxX);
            int rawBottom = (int)Math.Ceiling(bMaxY);
            int rawW = rawRight - rawLeft;
            int rawH = rawBottom - rawTop;

            if (rawW <= 0 || rawH <= 0) return false;

            if (rawW <= MaxFrameWidth && rawH <= MaxFrameHeight)
            {
                outX = rawLeft;
                outY = rawTop;
                outW = rawW;
                outH = rawH;
            }
            else
            {
                int prioX = cursorX;
                int prioY = cursorY;
                float prioReach = 64.0f;
                if (cursorEffectReach > 0.0f)
                {
                    prioX = cursorX;
                    prioY = cursorY;
                    prioReach = cursorEffectReach;
                }
                else if (hasAnyRipple && (!hasTrail || !hasNewestTrail || newestRippleTicks >= newestTrailTicks))
                {
                    prioX = newestRippleX;
                    prioY = newestRippleY;
                    prioReach = newestRippleReach;
                }
                else if (hasTrail && hasNewestTrail)
                {
                    prioX = newestTrailX;
                    prioY = newestTrailY;
                    prioReach = trailPad;
                }

                int prioMinX = (int)Math.Floor((float)prioX - prioReach);
                int prioMaxX = (int)Math.Ceiling((float)prioX + prioReach);
                int prioMinY = (int)Math.Floor((float)prioY - prioReach);
                int prioMaxY = (int)Math.Ceiling((float)prioY + prioReach);

                int clipLeft, clipRight, clipTop, clipBottom;
                ComputeClampedAxis(rawLeft, rawRight, prioX, prioMinX, prioMaxX, MaxFrameWidth, out clipLeft, out clipRight);
                ComputeClampedAxis(rawTop, rawBottom, prioY, prioMinY, prioMaxY, MaxFrameHeight, out clipTop, out clipBottom);

                int tMinX = int.MaxValue;
                int tMinY = int.MaxValue;
                int tMaxX = int.MinValue;
                int tMaxY = int.MinValue;

                if (hasTrail)
                {
                    int nodeCount = _subdivNodes.Count;
                    for (int i = 0; i < nodeCount - 1; i++)
                    {
                        SplineNode na = _subdivNodes[i];
                        SplineNode nb = _subdivNodes[i + 1];
                        if (na.Env < 0.0f || nb.Env < 0.0f) continue;
                        float maxEnv = na.Env > nb.Env ? na.Env : nb.Env;
                        float maxU = na.U > nb.U ? na.U : nb.U;
                        if (maxEnv <= 0.005f || maxU <= 0.005f) continue;

                        int sx0 = (int)Math.Floor((na.X < nb.X ? na.X : nb.X) - trailPad);
                        int sy0 = (int)Math.Floor((na.Y < nb.Y ? na.Y : nb.Y) - trailPad);
                        int sx1 = (int)Math.Ceiling((na.X > nb.X ? na.X : nb.X) + trailPad);
                        int sy1 = (int)Math.Ceiling((na.Y > nb.Y ? na.Y : nb.Y) + trailPad);
                        AccumulateClippedBounds(sx0, sy0, sx1, sy1, clipLeft, clipTop, clipRight, clipBottom, ref tMinX, ref tMinY, ref tMaxX, ref tMaxY);
                    }
                }

                if (hasAnyRipple)
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

                        int rx0 = (int)Math.Floor((float)ripples[i].X - reach);
                        int ry0 = (int)Math.Floor((float)ripples[i].Y - reach);
                        int rx1 = (int)Math.Ceiling((float)ripples[i].X + reach);
                        int ry1 = (int)Math.Ceiling((float)ripples[i].Y + reach);
                        AccumulateClippedBounds(rx0, ry0, rx1, ry1, clipLeft, clipTop, clipRight, clipBottom, ref tMinX, ref tMinY, ref tMaxX, ref tMaxY);
                    }
                }

                if (cursorEffectReach > 0.0f)
                {
                    int cx0 = (int)Math.Floor((float)cursorX - cursorEffectReach);
                    int cy0 = (int)Math.Floor((float)cursorY - cursorEffectReach);
                    int cx1 = (int)Math.Ceiling((float)cursorX + cursorEffectReach);
                    int cy1 = (int)Math.Ceiling((float)cursorY + cursorEffectReach);
                    AccumulateClippedBounds(cx0, cy0, cx1, cy1, clipLeft, clipTop, clipRight, clipBottom, ref tMinX, ref tMinY, ref tMaxX, ref tMaxY);
                }

                if (tMaxX <= tMinX || tMaxY <= tMinY) return false;
                outX = tMinX;
                outY = tMinY;
                outW = tMaxX - tMinX;
                outH = tMaxY - tMinY;
                if (outW > MaxFrameWidth) outW = MaxFrameWidth;
                if (outH > MaxFrameHeight) outH = MaxFrameHeight;
            }

            bool trackColor = (palette.Mode != PaletteMode.Solid);
            EnsureBuffers(outW, outH, trackColor);
            EnsureDib(outW, outH);
            if (_dibBits == IntPtr.Zero) return false;
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
                AccumulatePalettePreview(outX, outY, outW, outH, cursorX, cursorY, previewProgress, scale, preset, trackColor);
            }
            float timeSec = (float)((double)(nowTicks % (Stopwatch.Frequency * 3600L)) / (double)Stopwatch.Frequency);
            int nonZero = CompositePremultiplied(outW, outH, preset, palette, timeSec);
            return nonZero > 0;
        }

        private static void ComputeClampedAxis(
            int rawMin,
            int rawMax,
            int anchor,
            int prioMin,
            int prioMax,
            int maxSpan,
            out int clipMin,
            out int clipMax)
        {
            if (rawMax - rawMin <= maxSpan)
            {
                clipMin = rawMin;
                clipMax = rawMax;
                return;
            }

            int minStart = rawMin;
            int maxStart = rawMax - maxSpan;
            int start = anchor - (maxSpan / 2);
            if (prioMax - prioMin <= maxSpan)
            {
                if (prioMin < start) start = prioMin;
                if (prioMax > start + maxSpan) start = prioMax - maxSpan;
            }
            if (start < minStart) start = minStart;
            if (start > maxStart) start = maxStart;

            clipMin = start;
            clipMax = start + maxSpan;
        }

        private static void AccumulateClippedBounds(
            int elemMinX,
            int elemMinY,
            int elemMaxX,
            int elemMaxY,
            int clipMinX,
            int clipMinY,
            int clipMaxX,
            int clipMaxY,
            ref int tMinX,
            ref int tMinY,
            ref int tMaxX,
            ref int tMaxY)
        {
            int ix0 = elemMinX > clipMinX ? elemMinX : clipMinX;
            int iy0 = elemMinY > clipMinY ? elemMinY : clipMinY;
            int ix1 = elemMaxX < clipMaxX ? elemMaxX : clipMaxX;
            int iy1 = elemMaxY < clipMaxY ? elemMaxY : clipMaxY;
            if (ix0 >= ix1 || iy0 >= iy1) return;
            if (ix0 < tMinX) tMinX = ix0;
            if (iy0 < tMinY) tMinY = iy0;
            if (ix1 > tMaxX) tMaxX = ix1;
            if (iy1 > tMaxY) tMaxY = iy1;
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

        private void EnsureBuffers(int w, int h, bool needColor)
        {
            int needed = w * h;
            if (_haloBuf.Length < needed)
            {
                int newCap = Math.Max(needed, 65536);
                _haloBuf = new float[newCap];
                _coreBuf = new float[newCap];
            }
            if (needColor)
            {
                if (_colorBuf.Length < needed)
                {
                    int newCap = Math.Max(needed, 65536);
                    _colorBuf = new float[newCap];
                }
            }
            else if (_colorBuf.Length == 0)
            {
                _colorBuf = new float[1];
            }
        }

        private void EnsureDib(int w, int h)
        {
            if (_memDC != IntPtr.Zero && w <= _dibWidth && h <= _dibHeight)
            {
                return;
            }

            int reqW = Math.Max(w, 256);
            int reqH = Math.Max(h, 256);
            int newW = (reqW + 63) & ~63;
            int newH = (reqH + 63) & ~63;

            DisposeDibOnly();

            IntPtr screenDC = NativeMethods.GetDC(IntPtr.Zero);
            if (screenDC == IntPtr.Zero)
            {
                return;
            }
            _memDC = NativeMethods.CreateCompatibleDC(screenDC);
            NativeMethods.ReleaseDC(IntPtr.Zero, screenDC);
            if (_memDC == IntPtr.Zero)
            {
                return;
            }

            NativeMethods.BITMAPINFOHEADER bmi = new NativeMethods.BITMAPINFOHEADER();
            bmi.biSize = (uint)Marshal.SizeOf(typeof(NativeMethods.BITMAPINFOHEADER));
            bmi.biWidth = newW;
            bmi.biHeight = -newH; // top-down DIB
            bmi.biPlanes = 1;
            bmi.biBitCount = 32;
            bmi.biCompression = 0; // BI_RGB

            _dibBitmap = NativeMethods.CreateDIBSection(_memDC, ref bmi, 0, out _dibBits, IntPtr.Zero, 0);
            if (_dibBitmap != IntPtr.Zero && _dibBits != IntPtr.Zero)
            {
                _oldBitmap = NativeMethods.SelectObject(_memDC, _dibBitmap);
                _dibWidth = newW;
                _dibHeight = newH;
            }
            else
            {
                DisposeDibOnly();
            }
        }

        public bool TrimIfOversized()
        {
            bool trimmed = false;
            if (_dibWidth * _dibHeight > 131072)
            {
                DisposeDibOnly();
                trimmed = true;
            }
            if (_haloBuf.Length > 131072 || _coreBuf.Length > 131072 || _colorBuf.Length > 131072)
            {
                _haloBuf = new float[65536];
                _coreBuf = new float[65536];
                _colorBuf = new float[1];
                trimmed = true;
            }
            return trimmed;
        }

        public static void CompactManagedHeapOnce()
        {
            try
            {
                GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
                GC.Collect(2, GCCollectionMode.Forced, true);
            }
            catch
            {
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
                    if (x0 > x1 || y0 > y1) continue;

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
                    if (x0 > x1 || y0 > y1) continue;

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
            if (x0 > x1 || y0 > y1) return;

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
            if (x0 > x1 || y0 > y1) return;

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
            if (x0 > x1 || y0 > y1) return;

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
            TrailPreset preset,
            bool trackColor)
        {
            float inv = 1.0f - progress;
            float ease = 1.0f - inv * inv * inv;
            float rScale = preset.RippleMaxRadius / 30.0f;
            float wScale = preset.HaloRadius / 14.0f;
            float rRing = (9.0f + 17.0f * rScale * ease) * scale;
            float ringHaloW = 7.5f * wScale * scale;
            float ringCoreW = 2.0f * wScale * scale;
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
            if (x0 > x1 || y0 > y1) return;

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
}
