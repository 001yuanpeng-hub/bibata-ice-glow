using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;

namespace BibataIceTrail
{
    internal static class AppLogger
    {
        private const long MaxLogBytes = 256 * 1024;
        private static readonly object _sync = new object();
        private static string _logPath;

        public static string LogPath
        {
            get { return _logPath; }
        }

        public static void Init(string path)
        {
            lock (_sync)
            {
                _logPath = path;
            }
        }

        public static void Info(string message)
        {
            Write("INFO", message);
        }

        public static void Warn(string message)
        {
            Write("WARN", message);
        }

        public static void Error(string message, Exception ex)
        {
            string full = ex == null ? message : (message + " | " + ex.GetType().Name + ": " + ex.Message + " | " + ex.StackTrace);
            Write("ERROR", full);
        }

        private static void Write(string level, string message)
        {
            try
            {
                lock (_sync)
                {
                    if (string.IsNullOrEmpty(_logPath)) return;
                    string dir = Path.GetDirectoryName(_logPath);
                    if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                    {
                        Directory.CreateDirectory(dir);
                    }
                    if (File.Exists(_logPath))
                    {
                        FileInfo fi = new FileInfo(_logPath);
                        if (fi.Length >= MaxLogBytes)
                        {
                            string oldPath = _logPath + ".old";
                            try
                            {
                                if (File.Exists(oldPath)) File.Delete(oldPath);
                                File.Move(_logPath, oldPath);
                            }
                            catch
                            {
                            }
                        }
                    }
                    string line = string.Format(
                        CultureInfo.InvariantCulture,
                        "{0:yyyy-MM-dd HH:mm:ss.fff} [{1}] [pid={2}] {3}{4}",
                        DateTime.Now,
                        level,
                        Process.GetCurrentProcess().Id,
                        message ?? "",
                        Environment.NewLine);
                    File.AppendAllText(_logPath, line, Encoding.UTF8);
                }
            }
            catch
            {
            }
        }
    }
}
