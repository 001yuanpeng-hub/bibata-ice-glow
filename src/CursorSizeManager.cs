using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using Microsoft.Win32;

namespace BibataIceTrail
{
    internal static class CursorSizeManager
    {
        private static readonly string[] RoleNames = new string[]
        {
            "Arrow", "Help", "AppStarting", "Wait", "Crosshair", "IBeam",
            "NWPen", "No", "SizeNS", "SizeWE", "SizeNWSE", "SizeNESW",
            "SizeAll", "UpArrow", "Hand", "Pin", "Person"
        };

        private static readonly string[] RoleFiles = new string[]
        {
            "Pointer.cur", "Help.cur", "Work.ani", "Busy.ani", "Cross.cur", "Text.cur",
            "Handwriting.cur", "Unavailable.cur", "Vert.cur", "Horz.cur", "Dgn1.cur", "Dgn2.cur",
            "Move.cur", "Alternate.cur", "Link.cur", "Pin.cur", "Person.cur"
        };

        private static readonly string[] SizeOrder = new string[] { "Regular", "Large", "Extra-Large" };

        public static string ParseSizeFromFolderName(string folderName)
        {
            if (string.IsNullOrEmpty(folderName)) return null;
            if (folderName.EndsWith("-Extra-Large-Windows", StringComparison.OrdinalIgnoreCase)) return "Extra-Large";
            if (folderName.EndsWith("-Large-Windows", StringComparison.OrdinalIgnoreCase)) return "Large";
            if (folderName.EndsWith("-Regular-Windows", StringComparison.OrdinalIgnoreCase)) return "Regular";
            return null;
        }

        public static string GetNextSize(string currentSize)
        {
            if (string.Equals(currentSize, "Regular", StringComparison.OrdinalIgnoreCase)) return "Large";
            if (string.Equals(currentSize, "Large", StringComparison.OrdinalIgnoreCase)) return "Extra-Large";
            return "Regular";
        }

        private static bool HasAllCursorFiles(string sizeDir)
        {
            if (string.IsNullOrEmpty(sizeDir) || !Directory.Exists(sizeDir)) return false;
            for (int i = 0; i < RoleFiles.Length; i++)
            {
                if (!File.Exists(Path.Combine(sizeDir, RoleFiles[i]))) return false;
            }
            return true;
        }

        private static string ExtractThemeName(string folderName, string size)
        {
            string suffix = "-" + size + "-Windows";
            if (folderName.Length <= suffix.Length) return null;
            return folderName.Substring(0, folderName.Length - suffix.Length);
        }

        public static bool CycleInstalledCursorSize(string exePath)
        {
            return CycleInstalledCursorSize(exePath, @"Control Panel\Cursors", true);
        }

        public static bool CycleInstalledCursorSize(string exePath, string cursorsSubKeyPath, bool refreshSystemCursors)
        {
            try
            {
                if (string.IsNullOrEmpty(cursorsSubKeyPath))
                {
                    cursorsSubKeyPath = @"Control Panel\Cursors";
                }
                string schemesSubKeyPath = cursorsSubKeyPath + @"\Schemes";

                string themeRoot = null;
                string themeName = null;
                string currentSize = "Regular";

                using (RegistryKey cursorsKey = Registry.CurrentUser.OpenSubKey(cursorsSubKeyPath, false))
                {
                    if (cursorsKey != null)
                    {
                        string arrowPath = cursorsKey.GetValue("Arrow") as string;
                        if (!string.IsNullOrEmpty(arrowPath))
                        {
                            string curSizeDir = Path.GetDirectoryName(arrowPath);
                            if (!string.IsNullOrEmpty(curSizeDir))
                            {
                                string dirName = Path.GetFileName(curSizeDir);
                                string parsedSize = ParseSizeFromFolderName(dirName);
                                if (parsedSize != null && dirName.StartsWith("Bibata-", StringComparison.OrdinalIgnoreCase))
                                {
                                    themeName = ExtractThemeName(dirName, parsedSize);
                                    themeRoot = Path.GetDirectoryName(curSizeDir);
                                    currentSize = parsedSize;
                                }
                            }
                        }
                    }
                }

                if (string.IsNullOrEmpty(themeRoot) || string.IsNullOrEmpty(themeName))
                {
                    string exeDir = Path.GetDirectoryName(exePath);
                    string installRootFallback = string.IsNullOrEmpty(exeDir) ? null : Path.GetDirectoryName(exeDir);
                    if (!string.IsNullOrEmpty(installRootFallback))
                    {
                        string modernRoot = Path.Combine(installRootFallback, "Bibata-Modern-Ice");
                        string origRoot = Path.Combine(installRootFallback, "Bibata-Original-Ice");
                        if (Directory.Exists(modernRoot))
                        {
                            themeRoot = modernRoot;
                            themeName = "Bibata-Modern-Ice";
                        }
                        else if (Directory.Exists(origRoot))
                        {
                            themeRoot = origRoot;
                            themeName = "Bibata-Original-Ice";
                        }
                    }
                }

                if (string.IsNullOrEmpty(themeRoot) || string.IsNullOrEmpty(themeName)) return false;

                int validCount = 0;
                for (int i = 0; i < SizeOrder.Length; i++)
                {
                    string cand = Path.Combine(themeRoot, themeName + "-" + SizeOrder[i] + "-Windows");
                    if (HasAllCursorFiles(cand)) validCount++;
                }
                if (validCount < 2) return false;

                string probe = currentSize;
                string targetSize = null;
                string targetDir = null;
                for (int attempt = 0; attempt < SizeOrder.Length; attempt++)
                {
                    probe = GetNextSize(probe);
                    string cand = Path.Combine(themeRoot, themeName + "-" + probe + "-Windows");
                    if (HasAllCursorFiles(cand))
                    {
                        targetSize = probe;
                        targetDir = cand;
                        break;
                    }
                }
                if (targetSize == null || targetDir == null) return false;

                string[] paths = new string[RoleFiles.Length];
                for (int i = 0; i < RoleFiles.Length; i++)
                {
                    paths[i] = Path.Combine(targetDir, RoleFiles[i]);
                }

                string schemeName = themeName + " (" + targetSize + ")";
                string schemeValue = string.Join(",", paths);
                string installRoot = Path.GetDirectoryName(themeRoot);
                string runtimeBackupPath = string.IsNullOrEmpty(installRoot)
                    ? null
                    : Path.Combine(installRoot, "bibata-runtime-schemes.json");

                using (RegistryKey schemesKey = Registry.CurrentUser.CreateSubKey(schemesSubKeyPath))
                {
                    if (schemesKey != null)
                    {
                        bool existedBefore = false;
                        string previousValue = null;
                        string previousKind = "String";
                        object existingObj = schemesKey.GetValue(schemeName, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
                        if (existingObj != null)
                        {
                            existedBefore = true;
                            previousValue = existingObj.ToString();
                            try
                            {
                                previousKind = schemesKey.GetValueKind(schemeName).ToString();
                            }
                            catch
                            {
                                previousKind = "String";
                            }
                        }

                        bool alreadyMatches = existedBefore &&
                            string.Equals(previousValue, schemeValue, StringComparison.OrdinalIgnoreCase);

                        if (!alreadyMatches)
                        {
                            ResolveInheritedSchemeBackup(schemeName, installRoot, ref existedBefore, ref previousKind, ref previousValue);
                            bool backupSaved = !string.IsNullOrEmpty(runtimeBackupPath) &&
                                TryPersistRuntimeSchemeRecord(runtimeBackupPath, schemeName, existedBefore, previousKind, previousValue, schemeValue);
                            if (backupSaved)
                            {
                                schemesKey.SetValue(schemeName, schemeValue, RegistryValueKind.String);
                            }
                        }
                    }
                }

                using (RegistryKey cursorsKey = Registry.CurrentUser.CreateSubKey(cursorsSubKeyPath))
                {
                    if (cursorsKey == null) return false;
                    cursorsKey.SetValue("", schemeName, RegistryValueKind.String);
                    cursorsKey.SetValue("Scheme Source", 1, RegistryValueKind.DWord);
                    for (int i = 0; i < RoleNames.Length; i++)
                    {
                        cursorsKey.SetValue(RoleNames[i], paths[i], RegistryValueKind.String);
                    }
                }

                if (!refreshSystemCursors)
                {
                    return true;
                }
                return NativeMethods.SystemParametersInfo(NativeMethods.SPI_SETCURSORS, 0, IntPtr.Zero, NativeMethods.SPIF_SENDCHANGE);
            }
            catch
            {
                return false;
            }
        }

        internal sealed class RuntimeSchemeRecord
        {
            public string Name;
            public bool ExistedBefore;
            public string PreviousKind;
            public string PreviousValue;
            public string WrittenValue;
        }

        internal static bool TryPersistRuntimeSchemeRecord(
            string path,
            string schemeName,
            bool existedBefore,
            string previousKind,
            string previousValue,
            string writtenValue)
        {
            try
            {
                List<RuntimeSchemeRecord> records;
                if (!TryLoadRuntimeSchemeRecords(path, out records))
                {
                    return false;
                }

                RuntimeSchemeRecord existing = null;
                for (int i = 0; i < records.Count; i++)
                {
                    if (string.Equals(records[i].Name, schemeName, StringComparison.OrdinalIgnoreCase))
                    {
                        existing = records[i];
                        break;
                    }
                }

                if (existing != null)
                {
                    bool unchangedFromOurWrite = existedBefore &&
                        string.Equals(previousValue, existing.WrittenValue, StringComparison.OrdinalIgnoreCase);
                    if (!unchangedFromOurWrite)
                    {
                        existing.ExistedBefore = existedBefore;
                        existing.PreviousKind = string.IsNullOrEmpty(previousKind) ? "String" : previousKind;
                        existing.PreviousValue = existedBefore ? previousValue : null;
                    }
                    existing.WrittenValue = writtenValue;
                }
                else
                {
                    RuntimeSchemeRecord rec = new RuntimeSchemeRecord();
                    rec.Name = schemeName;
                    rec.ExistedBefore = existedBefore;
                    rec.PreviousKind = string.IsNullOrEmpty(previousKind) ? "String" : previousKind;
                    rec.PreviousValue = existedBefore ? previousValue : null;
                    rec.WrittenValue = writtenValue;
                    records.Add(rec);
                }

                return TrySaveRuntimeSchemeRecords(path, records);
            }
            catch
            {
                return false;
            }
        }

        internal static string SerializeRuntimeSchemeRecords(List<RuntimeSchemeRecord> records)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("[\r\n");
            for (int i = 0; i < records.Count; i++)
            {
                RuntimeSchemeRecord r = records[i];
                sb.Append("  {");
                sb.Append("\"name\":\"");
                AppendJsonEscaped(sb, r.Name ?? "");
                sb.Append("\",\"existedBefore\":");
                sb.Append(r.ExistedBefore ? "true" : "false");
                sb.Append(",\"previousKind\":\"");
                AppendJsonEscaped(sb, string.IsNullOrEmpty(r.PreviousKind) ? "String" : r.PreviousKind);
                sb.Append("\",\"previousValue\":");
                if (r.PreviousValue == null)
                {
                    sb.Append("null");
                }
                else
                {
                    sb.Append("\"");
                    AppendJsonEscaped(sb, r.PreviousValue);
                    sb.Append("\"");
                }
                sb.Append(",\"writtenValue\":\"");
                AppendJsonEscaped(sb, r.WrittenValue ?? "");
                sb.Append("\"}");
                if (i + 1 < records.Count) sb.Append(",");
                sb.Append("\r\n");
            }
            sb.Append("]\r\n");
            return sb.ToString();
        }

        private static void AppendJsonEscaped(StringBuilder sb, string s)
        {
            for (int i = 0; i < s.Length; i++)
            {
                char ch = s[i];
                if (ch == '\\') sb.Append("\\\\");
                else if (ch == '"') sb.Append("\\\"");
                else if (ch == '\r') sb.Append("\\r");
                else if (ch == '\n') sb.Append("\\n");
                else if (ch == '\t') sb.Append("\\t");
                else if (ch < 0x20) sb.AppendFormat(CultureInfo.InvariantCulture, "\\u{0:X4}", (int)ch);
                else sb.Append(ch);
            }
        }

        internal static bool TrySaveRuntimeSchemeRecords(string path, List<RuntimeSchemeRecord> records)
        {
            string tmpPath = null;
            try
            {
                string dir = Path.GetDirectoryName(path);
                if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return false;
                string json = SerializeRuntimeSchemeRecords(records);
                tmpPath = Path.Combine(dir, ".bibata-runtime-schemes." + Guid.NewGuid().ToString("N") + ".tmp");
                File.WriteAllText(tmpPath, json, Encoding.UTF8);
                File.Copy(tmpPath, path, true);
                return true;
            }
            catch
            {
                return false;
            }
            finally
            {
                if (!string.IsNullOrEmpty(tmpPath) && File.Exists(tmpPath))
                {
                    try { File.Delete(tmpPath); } catch { }
                }
            }
        }

        internal static bool TryLoadRuntimeSchemeRecords(string path, out List<RuntimeSchemeRecord> records)
        {
            records = new List<RuntimeSchemeRecord>();
            try
            {
                if (!File.Exists(path)) return true;
                string text = File.ReadAllText(path, Encoding.UTF8);
                return TryParseRuntimeSchemeRecords(text, out records);
            }
            catch
            {
                return false;
            }
        }

        internal static bool TryParseRuntimeSchemeRecords(string json, out List<RuntimeSchemeRecord> records)
        {
            records = new List<RuntimeSchemeRecord>();
            if (string.IsNullOrEmpty(json)) return false;
            int pos = 0;
            SkipJsonWs(json, ref pos);
            if (pos >= json.Length || json[pos] != '[') return false;
            pos++;
            SkipJsonWs(json, ref pos);
            if (pos < json.Length && json[pos] == ']') return true;

            while (pos < json.Length)
            {
                SkipJsonWs(json, ref pos);
                if (pos >= json.Length || json[pos] != '{') return false;
                pos++;
                RuntimeSchemeRecord rec = new RuntimeSchemeRecord();
                rec.PreviousKind = "String";

                SkipJsonWs(json, ref pos);
                while (pos < json.Length && json[pos] != '}')
                {
                    string key;
                    if (!ReadJsonString(json, ref pos, out key)) return false;
                    SkipJsonWs(json, ref pos);
                    if (pos >= json.Length || json[pos] != ':') return false;
                    pos++;
                    SkipJsonWs(json, ref pos);

                    if (string.Equals(key, "existedBefore", StringComparison.Ordinal))
                    {
                        bool bVal;
                        if (!ReadJsonBool(json, ref pos, out bVal)) return false;
                        rec.ExistedBefore = bVal;
                    }
                    else
                    {
                        string sVal;
                        if (!ReadJsonStringOrNull(json, ref pos, out sVal)) return false;
                        if (string.Equals(key, "name", StringComparison.Ordinal)) rec.Name = sVal;
                        else if (string.Equals(key, "previousKind", StringComparison.Ordinal)) rec.PreviousKind = sVal ?? "String";
                        else if (string.Equals(key, "previousValue", StringComparison.Ordinal)) rec.PreviousValue = sVal;
                        else if (string.Equals(key, "writtenValue", StringComparison.Ordinal)) rec.WrittenValue = sVal;
                    }

                    SkipJsonWs(json, ref pos);
                    if (pos < json.Length && json[pos] == ',')
                    {
                        pos++;
                        SkipJsonWs(json, ref pos);
                    }
                    else if (pos < json.Length && json[pos] == '}')
                    {
                        break;
                    }
                    else
                    {
                        return false;
                    }
                }
                if (pos >= json.Length || json[pos] != '}') return false;
                pos++;
                if (!string.IsNullOrEmpty(rec.Name))
                {
                    records.Add(rec);
                }

                SkipJsonWs(json, ref pos);
                if (pos < json.Length && json[pos] == ',')
                {
                    pos++;
                    continue;
                }
                if (pos < json.Length && json[pos] == ']')
                {
                    return true;
                }
                return false;
            }
            return false;
        }

        private static string NormalizeDirPath(string p)
        {
            if (string.IsNullOrEmpty(p)) return "";
            try
            {
                return Path.GetFullPath(p.Trim().Trim('"')).TrimEnd('\\').ToLowerInvariant();
            }
            catch
            {
                return p.Trim().Trim('"').TrimEnd('\\').ToLowerInvariant();
            }
        }

        internal static void ResolveInheritedSchemeBackup(
            string schemeName,
            string currentInstallRoot,
            ref bool existedBefore,
            ref string previousKind,
            ref string previousValue)
        {
            if (!existedBefore || string.IsNullOrEmpty(previousValue)) return;

            HashSet<string> visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            string curNorm = NormalizeDirPath(currentInstallRoot);
            if (!string.IsNullOrEmpty(curNorm)) visited.Add(curNorm);

            for (int hop = 0; hop < 5; hop++)
            {
                if (!existedBefore || string.IsNullOrEmpty(previousValue)) break;

                int commaIdx = previousValue.IndexOf(',');
                string firstPath = (commaIdx >= 0 ? previousValue.Substring(0, commaIdx) : previousValue).Trim();
                if (string.IsNullOrEmpty(firstPath)) break;

                string sizeDir = Path.GetDirectoryName(firstPath);
                if (string.IsNullOrEmpty(sizeDir)) break;
                string sizeDirName = Path.GetFileName(sizeDir);
                if (ParseSizeFromFolderName(sizeDirName) == null) break;

                string themeDir = Path.GetDirectoryName(sizeDir);
                if (string.IsNullOrEmpty(themeDir)) break;
                string themeDirName = Path.GetFileName(themeDir);
                if (!string.Equals(themeDirName, "Bibata-Modern-Ice", StringComparison.OrdinalIgnoreCase) &&
                    !string.Equals(themeDirName, "Bibata-Original-Ice", StringComparison.OrdinalIgnoreCase))
                {
                    break;
                }

                string otherRoot = Path.GetDirectoryName(themeDir);
                string otherNorm = NormalizeDirPath(otherRoot);
                if (string.IsNullOrEmpty(otherNorm) || visited.Contains(otherNorm)) break;
                visited.Add(otherNorm);

                RuntimeSchemeRecord matchedOther = null;
                List<RuntimeSchemeRecord> otherRt;
                string otherRtPath = Path.Combine(otherRoot, "bibata-runtime-schemes.json");
                if (File.Exists(otherRtPath) && TryLoadRuntimeSchemeRecords(otherRtPath, out otherRt))
                {
                    for (int i = 0; i < otherRt.Count; i++)
                    {
                        if (string.Equals(otherRt[i].Name, schemeName, StringComparison.OrdinalIgnoreCase) &&
                            string.Equals(otherRt[i].WrittenValue, previousValue, StringComparison.OrdinalIgnoreCase))
                        {
                            matchedOther = otherRt[i];
                            break;
                        }
                    }
                }

                if (matchedOther == null)
                {
                    string otherManifestPath = Path.Combine(otherRoot, "bibata-ice-glow-manifest.json");
                    RuntimeSchemeRecord mfRec;
                    if (File.Exists(otherManifestPath) &&
                        TryFindManifestSchemeRecord(otherManifestPath, schemeName, out mfRec) &&
                        string.Equals(mfRec.WrittenValue, previousValue, StringComparison.OrdinalIgnoreCase))
                    {
                        matchedOther = mfRec;
                    }
                }

                if (matchedOther == null) break;

                existedBefore = matchedOther.ExistedBefore;
                previousKind = string.IsNullOrEmpty(matchedOther.PreviousKind) ? "String" : matchedOther.PreviousKind;
                previousValue = matchedOther.ExistedBefore ? matchedOther.PreviousValue : null;
            }
        }

        internal static bool TryFindManifestSchemeRecord(string manifestPath, string schemeName, out RuntimeSchemeRecord record)
        {
            record = null;
            try
            {
                if (!File.Exists(manifestPath)) return false;
                string json = File.ReadAllText(manifestPath, Encoding.UTF8);
                int pos = 0;
                SkipJsonWs(json, ref pos);
                if (pos >= json.Length || json[pos] != '{') return false;
                pos++;
                SkipJsonWs(json, ref pos);
                while (pos < json.Length && json[pos] != '}')
                {
                    string key;
                    if (!ReadJsonString(json, ref pos, out key)) return false;
                    SkipJsonWs(json, ref pos);
                    if (pos >= json.Length || json[pos] != ':') return false;
                    pos++;
                    SkipJsonWs(json, ref pos);

                    if (string.Equals(key, "managedSchemeRecords", StringComparison.OrdinalIgnoreCase) &&
                        pos < json.Length && json[pos] == '{')
                    {
                        pos++;
                        SkipJsonWs(json, ref pos);
                        while (pos < json.Length && json[pos] != '}')
                        {
                            string sKey;
                            if (!ReadJsonString(json, ref pos, out sKey)) return false;
                            SkipJsonWs(json, ref pos);
                            if (pos >= json.Length || json[pos] != ':') return false;
                            pos++;
                            SkipJsonWs(json, ref pos);

                            if (string.Equals(sKey, schemeName, StringComparison.OrdinalIgnoreCase) &&
                                pos < json.Length && json[pos] == '{')
                            {
                                pos++;
                                RuntimeSchemeRecord rec = new RuntimeSchemeRecord();
                                rec.Name = sKey;
                                rec.PreviousKind = "String";
                                SkipJsonWs(json, ref pos);
                                while (pos < json.Length && json[pos] != '}')
                                {
                                    string fk;
                                    if (!ReadJsonString(json, ref pos, out fk)) return false;
                                    SkipJsonWs(json, ref pos);
                                    if (pos >= json.Length || json[pos] != ':') return false;
                                    pos++;
                                    SkipJsonWs(json, ref pos);
                                    if (string.Equals(fk, "existedBefore", StringComparison.OrdinalIgnoreCase))
                                    {
                                        bool bv;
                                        if (!ReadJsonBool(json, ref pos, out bv)) return false;
                                        rec.ExistedBefore = bv;
                                    }
                                    else if (string.Equals(fk, "previousKind", StringComparison.OrdinalIgnoreCase) ||
                                             string.Equals(fk, "previousValue", StringComparison.OrdinalIgnoreCase) ||
                                             string.Equals(fk, "writtenValue", StringComparison.OrdinalIgnoreCase))
                                    {
                                        string sv;
                                        if (!ReadJsonStringOrNull(json, ref pos, out sv)) return false;
                                        if (string.Equals(fk, "previousKind", StringComparison.OrdinalIgnoreCase)) rec.PreviousKind = sv ?? "String";
                                        else if (string.Equals(fk, "previousValue", StringComparison.OrdinalIgnoreCase)) rec.PreviousValue = sv;
                                        else if (string.Equals(fk, "writtenValue", StringComparison.OrdinalIgnoreCase)) rec.WrittenValue = sv;
                                    }
                                    else
                                    {
                                        if (!SkipJsonValue(json, ref pos)) return false;
                                    }
                                    SkipJsonWs(json, ref pos);
                                    if (pos < json.Length && json[pos] == ',') { pos++; SkipJsonWs(json, ref pos); }
                                    else if (pos < json.Length && json[pos] == '}') break;
                                    else return false;
                                }
                                record = rec;
                                return true;
                            }
                            else
                            {
                                if (!SkipJsonValue(json, ref pos)) return false;
                            }
                            SkipJsonWs(json, ref pos);
                            if (pos < json.Length && json[pos] == ',') { pos++; SkipJsonWs(json, ref pos); }
                            else if (pos < json.Length && json[pos] == '}') break;
                            else return false;
                        }
                        return false;
                    }
                    else
                    {
                        if (!SkipJsonValue(json, ref pos)) return false;
                    }
                    SkipJsonWs(json, ref pos);
                    if (pos < json.Length && json[pos] == ',') { pos++; SkipJsonWs(json, ref pos); }
                    else if (pos < json.Length && json[pos] == '}') break;
                    else return false;
                }
                return false;
            }
            catch
            {
                return false;
            }
        }

        private static bool SkipJsonValue(string s, ref int pos)
        {
            SkipJsonWs(s, ref pos);
            if (pos >= s.Length) return false;
            char ch = s[pos];
            if (ch == '"')
            {
                string ignored;
                return ReadJsonString(s, ref pos, out ignored);
            }
            if (ch == '{')
            {
                pos++;
                SkipJsonWs(s, ref pos);
                if (pos < s.Length && s[pos] == '}') { pos++; return true; }
                while (pos < s.Length)
                {
                    string k;
                    if (!ReadJsonString(s, ref pos, out k)) return false;
                    SkipJsonWs(s, ref pos);
                    if (pos >= s.Length || s[pos] != ':') return false;
                    pos++;
                    if (!SkipJsonValue(s, ref pos)) return false;
                    SkipJsonWs(s, ref pos);
                    if (pos < s.Length && s[pos] == ',') { pos++; SkipJsonWs(s, ref pos); continue; }
                    if (pos < s.Length && s[pos] == '}') { pos++; return true; }
                    return false;
                }
                return false;
            }
            if (ch == '[')
            {
                pos++;
                SkipJsonWs(s, ref pos);
                if (pos < s.Length && s[pos] == ']') { pos++; return true; }
                while (pos < s.Length)
                {
                    if (!SkipJsonValue(s, ref pos)) return false;
                    SkipJsonWs(s, ref pos);
                    if (pos < s.Length && s[pos] == ',') { pos++; SkipJsonWs(s, ref pos); continue; }
                    if (pos < s.Length && s[pos] == ']') { pos++; return true; }
                    return false;
                }
                return false;
            }
            if (pos + 4 <= s.Length && string.CompareOrdinal(s, pos, "true", 0, 4) == 0) { pos += 4; return true; }
            if (pos + 5 <= s.Length && string.CompareOrdinal(s, pos, "false", 0, 5) == 0) { pos += 5; return true; }
            if (pos + 4 <= s.Length && string.CompareOrdinal(s, pos, "null", 0, 4) == 0) { pos += 4; return true; }
            int start = pos;
            while (pos < s.Length)
            {
                char nc = s[pos];
                if ((nc >= '0' && nc <= '9') || nc == '-' || nc == '+' || nc == '.' || nc == 'e' || nc == 'E') pos++;
                else break;
            }
            return pos > start;
        }

        private static void SkipJsonWs(string s, ref int pos)
        {
            while (pos < s.Length)
            {
                char ch = s[pos];
                if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') pos++;
                else break;
            }
        }

        private static bool ReadJsonBool(string s, ref int pos, out bool val)
        {
            val = false;
            if (pos + 4 <= s.Length && string.CompareOrdinal(s, pos, "true", 0, 4) == 0)
            {
                val = true;
                pos += 4;
                return true;
            }
            if (pos + 5 <= s.Length && string.CompareOrdinal(s, pos, "false", 0, 5) == 0)
            {
                val = false;
                pos += 5;
                return true;
            }
            return false;
        }

        private static bool ReadJsonStringOrNull(string s, ref int pos, out string val)
        {
            val = null;
            if (pos + 4 <= s.Length && string.CompareOrdinal(s, pos, "null", 0, 4) == 0)
            {
                pos += 4;
                return true;
            }
            return ReadJsonString(s, ref pos, out val);
        }

        private static bool ReadJsonString(string s, ref int pos, out string val)
        {
            val = null;
            if (pos >= s.Length || s[pos] != '"') return false;
            pos++;
            StringBuilder sb = new StringBuilder();
            while (pos < s.Length)
            {
                char ch = s[pos++];
                if (ch == '"')
                {
                    val = sb.ToString();
                    return true;
                }
                if (ch == '\\')
                {
                    if (pos >= s.Length) return false;
                    char esc = s[pos++];
                    if (esc == '"' || esc == '\\' || esc == '/') sb.Append(esc);
                    else if (esc == 'b') sb.Append('\b');
                    else if (esc == 'f') sb.Append('\f');
                    else if (esc == 'n') sb.Append('\n');
                    else if (esc == 'r') sb.Append('\r');
                    else if (esc == 't') sb.Append('\t');
                    else if (esc == 'u' && pos + 4 <= s.Length)
                    {
                        int code;
                        if (!int.TryParse(s.Substring(pos, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out code)) return false;
                        sb.Append((char)code);
                        pos += 4;
                    }
                    else
                    {
                        return false;
                    }
                }
                else
                {
                    sb.Append(ch);
                }
            }
            return false;
        }
    }
}
