using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace BibataIceTrail
{
    internal static partial class Program
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

            if (args != null && args.Length >= 1 && string.Equals(args[0], "--cycle-cursor-size", StringComparison.OrdinalIgnoreCase))
            {
                string cursorsSubKey = @"Control Panel\Cursors";
                bool noRefresh = false;
                for (int i = 1; i < args.Length; i++)
                {
                    if (string.Equals(args[i], "--cursors-reg-key", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                    {
                        cursorsSubKey = args[++i];
                    }
                    else if (string.Equals(args[i], "--no-refresh", StringComparison.OrdinalIgnoreCase))
                    {
                        noRefresh = true;
                    }
                }
                return CursorSizeManager.CycleInstalledCursorSize(Application.ExecutablePath, cursorsSubKey, !noRefresh) ? 0 : 1;
            }

            bool forceShowTray = false;
            bool runDiagnose = false;
            string diagnoseOutPath = null;
            string customLogPath = null;
            string instanceSuffix = "SingleInstance";
            if (args != null)
            {
                for (int i = 0; i < args.Length; i++)
                {
                    if (string.Equals(args[i], "--show-tray", StringComparison.OrdinalIgnoreCase) ||
                        string.Equals(args[i], "--tray", StringComparison.OrdinalIgnoreCase))
                    {
                        forceShowTray = true;
                    }
                    else if (string.Equals(args[i], "--diagnose", StringComparison.OrdinalIgnoreCase))
                    {
                        runDiagnose = true;
                        if (i + 1 < args.Length && !args[i + 1].StartsWith("-", StringComparison.Ordinal))
                        {
                            diagnoseOutPath = args[++i];
                        }
                    }
                    else if (string.Equals(args[i], "--log", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                    {
                        customLogPath = args[++i];
                    }
                    else if (string.Equals(args[i], "--instance-name", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                    {
                        string rawName = args[++i];
                        StringBuilder clean = new StringBuilder();
                        for (int c = 0; c < rawName.Length && clean.Length < 40; c++)
                        {
                            char ch = rawName[c];
                            if ((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-')
                            {
                                clean.Append(ch);
                            }
                        }
                        if (clean.Length > 0)
                        {
                            instanceSuffix = clean.ToString();
                        }
                    }
                }
            }

            string exeDir = Path.GetDirectoryName(Application.ExecutablePath);
            string cfgPath = Path.Combine(exeDir, "config.ini");
            AppConfig config = new AppConfig(cfgPath);
            config.Load();

            if (runDiagnose)
            {
                return RunDiagnostics(config, cfgPath, diagnoseOutPath);
            }

            string defaultLogPath = !string.IsNullOrWhiteSpace(customLogPath)
                ? customLogPath
                : Path.Combine(exeDir, "BibataIceTrail.log");
            AppLogger.Init(defaultLogPath);

            Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
            Application.ThreadException += delegate (object sender, ThreadExceptionEventArgs e)
            {
                AppLogger.Error("Unhandled UI thread exception", e != null ? e.Exception : null);
            };
            AppDomain.CurrentDomain.UnhandledException += delegate (object sender, UnhandledExceptionEventArgs e)
            {
                AppLogger.Error("Unhandled domain exception (terminating=" + (e != null && e.IsTerminating) + ")", e != null ? e.ExceptionObject as Exception : null);
            };
            AppDomain.CurrentDomain.ProcessExit += delegate
            {
                AppLogger.Info("ProcessExit invoked.");
            };

            bool createdNew;
            using (Mutex mutex = new Mutex(true, "Local\\BibataIceTrail_" + instanceSuffix, out createdNew))
            {
                if (!createdNew)
                {
                    AppLogger.Info("Another BibataIceTrail instance is already running (mutex=" + instanceSuffix + "); exiting.");
                    return 0;
                }

                AppLogger.Info(BuildStartupSummary(config, cfgPath));

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);

                using (TrayApplicationContext ctx = new TrayApplicationContext(config, config.ShowTrayIcon || forceShowTray))
                {
                    Application.Run(ctx);
                }
                GC.KeepAlive(mutex);
                AppLogger.Info("Clean exit.");
                return 0;
            }
        }

        private static string BuildStartupSummary(AppConfig config, string cfgPath)
        {
            Process proc = Process.GetCurrentProcess();
            StringBuilder sb = new StringBuilder();
            sb.AppendFormat(
                CultureInfo.InvariantCulture,
                "Startup pid={0} session={1} arch={2} os={3} job=[{4}] configExists={5} palette={6} preset={7} showTray={8} screens={9}",
                proc.Id,
                proc.SessionId,
                IntPtr.Size == 8 ? "x64" : "x86",
                Environment.OSVersion.VersionString,
                NativeMethods.GetCurrentJobSummary(),
                File.Exists(cfgPath),
                config.Palette,
                config.Preset,
                config.ShowTrayIcon,
                Screen.AllScreens.Length);
            return sb.ToString();
        }

        private static int RunDiagnostics(AppConfig config, string cfgPath, string outPath)
        {
            StringBuilder sb = new StringBuilder();
            Process proc = Process.GetCurrentProcess();
            sb.AppendLine("BibataIceTrail Diagnostics");
            sb.AppendLine("Executable: " + Application.ExecutablePath);
            sb.AppendLine("PID: " + proc.Id.ToString(CultureInfo.InvariantCulture) + " | SessionId: " + proc.SessionId.ToString(CultureInfo.InvariantCulture) + " | Arch: " + (IntPtr.Size == 8 ? "x64" : "x86"));
            sb.AppendLine("OS: " + Environment.OSVersion.VersionString);
            sb.AppendLine("Job: " + NativeMethods.GetCurrentJobSummary());
            sb.AppendLine("ConfigPath: " + cfgPath + " (exists=" + File.Exists(cfgPath) + ")");
            sb.AppendLine(string.Format(
                CultureInfo.InvariantCulture,
                "Config: Enabled={0} Trail={1} Ripple={2} Drag={3} Shake={4} Scroll={5} Hotkey={6} Preset={7} Palette={8} AutoPauseFullscreen={9} ShowTrayIcon={10}",
                config.Enabled, config.TrailEnabled, config.ClickRippleEnabled, config.DragGlowEnabled,
                config.ShakeLocateEnabled, config.ScrollGlowEnabled, config.HotkeyEnabled,
                config.Preset, config.Palette, config.AutoPauseFullscreen, config.ShowTrayIcon));

            Screen[] screens = Screen.AllScreens;
            sb.AppendLine("Monitors (" + screens.Length.ToString(CultureInfo.InvariantCulture) + "):");
            for (int i = 0; i < screens.Length; i++)
            {
                Rectangle b = screens[i].Bounds;
                uint dpi = NativeMethods.GetDpiAtPoint(b.Left + b.Width / 2, b.Top + b.Height / 2);
                sb.AppendLine(string.Format(
                    CultureInfo.InvariantCulture,
                    "  [{0}] {1} Primary={2} Bounds=({3},{4},{5}x{6}) DPI={7} ({8}%)",
                    i, screens[i].DeviceName, screens[i].Primary, b.Left, b.Top, b.Width, b.Height,
                    dpi, (int)Math.Round(dpi * 100.0 / 96.0)));
            }

            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(@"Control Panel\Cursors", false))
                {
                    string defScheme = key != null ? (key.GetValue("") as string ?? "") : "";
                    string arrow = key != null ? (key.GetValue("Arrow") as string ?? "") : "";
                    sb.AppendLine("ActiveCursorScheme: " + defScheme);
                    sb.AppendLine("ActiveArrow: " + arrow);
                }
            }
            catch (Exception ex)
            {
                sb.AppendLine("ActiveCursorError: " + ex.Message);
            }

            string text = sb.ToString();
            try { Console.Out.Write(text); } catch { }
            if (!string.IsNullOrWhiteSpace(outPath))
            {
                try { File.WriteAllText(outPath, text, Encoding.UTF8); } catch { }
            }
            return 0;
        }
    }
}
