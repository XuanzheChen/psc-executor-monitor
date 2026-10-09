using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Threading;
using System.Reflection;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

internal static class PSCMonitorLauncher
{
    [STAThread]
    private static int Main(string[] args)
    {
        string baseDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string script = Path.Combine(baseDir, "PSC-Monitor.ps1");
        bool selfTest = args != null && args.Any(a => a.Equals("--selftest", StringComparison.OrdinalIgnoreCase));
        try
        {
            if (!File.Exists(script))
                throw new FileNotFoundException("未找到 PSC-Monitor.ps1", script);

            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    // Interpret the local UTF-8 source in-process so that the executable
                    // (rather than powershell.exe) owns the GUI/taskbar icon.
                    string source = File.ReadAllText(script, Encoding.UTF8);
                    ps.AddScript(source, false);
                    if (selfTest) ps.AddParameter("SelfTest", true);
                    var output = ps.Invoke();

                    if (selfTest)
                    {
                        foreach (var item in output)
                            Console.WriteLine(item == null ? "" : item.ToString());
                    }

                    if (ps.HadErrors)
                    {
                        string error = String.Join(Environment.NewLine,
                            ps.Streams.Error.Select(e => e.ToString()).ToArray());
                        File.AppendAllText(Path.Combine(baseDir, "monitor-error.log"),
                            DateTime.Now.ToString("s") + Environment.NewLine + error + Environment.NewLine,
                            Encoding.UTF8);
                        if (!selfTest) MessageBox.Show(error, "PSC 监视器启动失败",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return 2;
                    }
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            string message = ex.ToString();
            try { File.AppendAllText(Path.Combine(baseDir, "monitor-error.log"),
                DateTime.Now.ToString("s") + Environment.NewLine + message + Environment.NewLine,
                Encoding.UTF8); } catch {}
            if (!selfTest) MessageBox.Show(message, "PSC 监视器启动失败",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
