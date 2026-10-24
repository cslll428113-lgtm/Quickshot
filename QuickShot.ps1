$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$source = @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;
using System.Runtime.InteropServices;

namespace QuickShot
{
    internal static class NativeMethods
    {
        public const int WM_HOTKEY = 0x0312;
        public const uint MOD_ALT = 0x0001;
        public const uint MOD_CONTROL = 0x0002;
        public const uint MOD_SHIFT = 0x0004;

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint key);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();

        [DllImport("user32.dll", EntryPoint = "SetProcessDpiAwarenessContext")]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    }

    internal sealed class HotKeyWindow : NativeWindow, IDisposable
    {
        public event EventHandler Pressed;
        private const int HotKeyId = 0x5148;
        public string ActiveShortcut { get; private set; }

        public HotKeyWindow()
        {
            CreateHandle(new CreateParams());
            if (NativeMethods.RegisterHotKey(Handle, HotKeyId, NativeMethods.MOD_ALT, (uint)Keys.A))
            {
                ActiveShortcut = "Alt + A";
            }
            else if (NativeMethods.RegisterHotKey(Handle, HotKeyId,
                NativeMethods.MOD_CONTROL | NativeMethods.MOD_SHIFT, (uint)Keys.A))
            {
                ActiveShortcut = "Ctrl + Shift + A";
            }
            else
            {
                ActiveShortcut = null;
            }
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == NativeMethods.WM_HOTKEY && Pressed != null)
                Pressed(this, EventArgs.Empty);
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            if (Handle != IntPtr.Zero)
            {
                NativeMethods.UnregisterHotKey(Handle, HotKeyId);
                DestroyHandle();
            }
        }
    }

    internal sealed class CaptureOverlay : Form
    {
        private readonly Bitmap desktop;
        private readonly Bitmap dimmedDesktop;
        private Point start;
        private Point current;
        private bool dragging;

        public event Action<Bitmap> Captured;

        public CaptureOverlay(Bitmap desktopImage, Rectangle desktopBounds)
        {
            desktop = desktopImage;
            dimmedDesktop = new Bitmap(desktop.Width, desktop.Height, PixelFormat.Format32bppPArgb);
            using (Graphics g = Graphics.FromImage(dimmedDesktop))
            {
                g.DrawImageUnscaled(desktop, 0, 0);
                using (SolidBrush shade = new SolidBrush(Color.FromArgb(112, 7, 8, 15)))
                    g.FillRectangle(shade, 0, 0, dimmedDesktop.Width, dimmedDesktop.Height);
            }
            Bounds = desktopBounds;
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            TopMost = true;
            Cursor = Cursors.Cross;
            KeyPreview = true;
            StartPosition = FormStartPosition.Manual;
            SetStyle(ControlStyles.AllPaintingInWmPaint |
                     ControlStyles.UserPaint |
                     ControlStyles.OptimizedDoubleBuffer, true);
            UpdateStyles();
        }

        protected override bool ShowWithoutActivation { get { return false; } }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            Activate();
            Focus();
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Rectangle clip = Rectangle.Intersect(e.ClipRectangle, ClientRectangle);
            if (clip.Width < 1 || clip.Height < 1) return;
            e.Graphics.DrawImage(dimmedDesktop, clip, clip, GraphicsUnit.Pixel);

            if (!dragging) return;
            Rectangle rect = SelectionRectangle();
            if (rect.Width < 1 || rect.Height < 1) return;

            Rectangle visibleSelection = Rectangle.Intersect(rect, clip);
            if (visibleSelection.Width > 0 && visibleSelection.Height > 0)
                e.Graphics.DrawImage(desktop, visibleSelection, visibleSelection, GraphicsUnit.Pixel);
            using (Pen border = new Pen(Color.FromArgb(255, 105, 210, 255), 2f))
                e.Graphics.DrawRectangle(border, rect.X, rect.Y, rect.Width - 1, rect.Height - 1);

            string size = rect.Width + " x " + rect.Height;
            using (Font font = new Font("Segoe UI", 9f))
            {
                SizeF textSize = e.Graphics.MeasureString(size, font);
                int boxX = rect.X;
                int boxY = rect.Y - (int)textSize.Height - 8;
                if (boxY < 0) boxY = rect.Bottom + 4;
                using (SolidBrush box = new SolidBrush(Color.FromArgb(220, 25, 25, 28)))
                    e.Graphics.FillRectangle(box, boxX, boxY, textSize.Width + 12, textSize.Height + 4);
                using (SolidBrush text = new SolidBrush(Color.White))
                    e.Graphics.DrawString(size, font, text, boxX + 6, boxY + 2);
            }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            start = e.Location;
            current = e.Location;
            dragging = true;
            Capture = true;
            Invalidate(DirtyRectangle(SelectionRectangle()));
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            if (!dragging) return;
            Rectangle oldRect = SelectionRectangle();
            current = Clamp(e.Location);
            Rectangle newRect = SelectionRectangle();
            InvalidateTransition(oldRect, newRect);
        }

        protected override void OnMouseUp(MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left || !dragging) return;
            current = Clamp(e.Location);
            dragging = false;
            Capture = false;
            Rectangle rect = SelectionRectangle();
            if (rect.Width < 5 || rect.Height < 5)
            {
                Invalidate();
                return;
            }

            Bitmap result = new Bitmap(rect.Width, rect.Height, PixelFormat.Format32bppArgb);
            using (Graphics g = Graphics.FromImage(result))
                g.DrawImage(desktop, new Rectangle(0, 0, result.Width, result.Height), rect, GraphicsUnit.Pixel);

            Hide();
            if (Captured != null) Captured(result);
            Close();
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape)
            {
                e.Handled = true;
                Close();
            }
            base.OnKeyDown(e);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                dimmedDesktop.Dispose();
                desktop.Dispose();
            }
            base.Dispose(disposing);
        }

        private Rectangle DirtyRectangle(Rectangle rect)
        {
            rect.Inflate(12, 42);
            return Rectangle.Intersect(rect, ClientRectangle);
        }

        private void InvalidateTransition(Rectangle oldRect, Rectangle newRect)
        {
            InvalidateBorder(oldRect);
            InvalidateBorder(newRect);
            InvalidateDifference(oldRect, newRect);
            InvalidateDifference(newRect, oldRect);
            Invalidate(LabelRectangle(oldRect));
            Invalidate(LabelRectangle(newRect));
        }

        private void InvalidateBorder(Rectangle rect)
        {
            if (rect.Width < 1 || rect.Height < 1) return;
            const int pad = 4;
            Invalidate(Rectangle.Intersect(new Rectangle(rect.Left - pad, rect.Top - pad, rect.Width + pad * 2, pad * 2 + 2), ClientRectangle));
            Invalidate(Rectangle.Intersect(new Rectangle(rect.Left - pad, rect.Bottom - pad, rect.Width + pad * 2, pad * 2 + 2), ClientRectangle));
            Invalidate(Rectangle.Intersect(new Rectangle(rect.Left - pad, rect.Top, pad * 2 + 2, rect.Height), ClientRectangle));
            Invalidate(Rectangle.Intersect(new Rectangle(rect.Right - pad, rect.Top, pad * 2 + 2, rect.Height), ClientRectangle));
        }

        private void InvalidateDifference(Rectangle source, Rectangle subtract)
        {
            Rectangle overlap = Rectangle.Intersect(source, subtract);
            if (overlap.IsEmpty)
            {
                Invalidate(Rectangle.Intersect(source, ClientRectangle));
                return;
            }
            if (source.Top < overlap.Top)
                Invalidate(Rectangle.Intersect(Rectangle.FromLTRB(source.Left, source.Top, source.Right, overlap.Top), ClientRectangle));
            if (overlap.Bottom < source.Bottom)
                Invalidate(Rectangle.Intersect(Rectangle.FromLTRB(source.Left, overlap.Bottom, source.Right, source.Bottom), ClientRectangle));
            if (source.Left < overlap.Left)
                Invalidate(Rectangle.Intersect(Rectangle.FromLTRB(source.Left, overlap.Top, overlap.Left, overlap.Bottom), ClientRectangle));
            if (overlap.Right < source.Right)
                Invalidate(Rectangle.Intersect(Rectangle.FromLTRB(overlap.Right, overlap.Top, source.Right, overlap.Bottom), ClientRectangle));
        }

        private Rectangle LabelRectangle(Rectangle rect)
        {
            int y = rect.Top - 34;
            if (y < 0) y = rect.Bottom + 2;
            return Rectangle.Intersect(new Rectangle(rect.Left - 4, y, 150, 32), ClientRectangle);
        }

        private Point Clamp(Point point)
        {
            return new Point(
                Math.Max(0, Math.Min(ClientSize.Width, point.X)),
                Math.Max(0, Math.Min(ClientSize.Height, point.Y)));
        }

        private Rectangle SelectionRectangle()
        {
            int left = Math.Min(start.X, current.X);
            int top = Math.Min(start.Y, current.Y);
            int right = Math.Max(start.X, current.X);
            int bottom = Math.Max(start.Y, current.Y);
            return Rectangle.FromLTRB(left, top, right, bottom);
        }
    }

    public static class App
    {
        private static NotifyIcon tray;
        private static Icon appIcon;
        private static HotKeyWindow hotKey;
        private static ToolStripMenuItem autoSaveItem;
        private static ToolStripMenuItem startupItem;
        private static bool capturing;
        private static bool changingStartup;
        private static string appDirectory;
        private static string settingsDirectory;
        private static string screenshotsDirectory;
        private static string settingsFile;
        private const string RunValueName = "QuickShot";

        public static void Run(string baseDirectory)
        {
            bool created;
            Mutex singleInstance = new Mutex(true, "Local\\QuickShot_MouseLuo", out created);
            if (!created)
            {
                MessageBox.Show("QuickShot is already running.", "QuickShot",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
                singleInstance.Dispose();
                return;
            }

            try { NativeMethods.SetProcessDpiAwarenessContext(new IntPtr(-4)); }
            catch { try { NativeMethods.SetProcessDPIAware(); } catch { } }

            appDirectory = baseDirectory;
            settingsDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "QuickShot");
            screenshotsDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.MyPictures), "QuickShot");
            settingsFile = Path.Combine(settingsDirectory, "settings.txt");
            Directory.CreateDirectory(settingsDirectory);

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            hotKey = new HotKeyWindow();
            hotKey.Pressed += delegate { BeginCapture(); };
            BuildTray();

            if (hotKey.ActiveShortcut == null)
                ShowNotice("Shortcut unavailable", "Alt+A and Ctrl+Shift+A are both in use. Use the tray menu to capture.");
            else if (hotKey.ActiveShortcut != "Alt + A")
                ShowNotice("QuickShot is ready", "Alt+A is in use, so the shortcut is " + hotKey.ActiveShortcut + ".");
            else
                ShowNotice("QuickShot is ready", "Press Alt+A to select an area. Release to copy it.");

            Application.Run();

            tray.Visible = false;
            tray.Dispose();
            if (appIcon != null) appIcon.Dispose();
            hotKey.Dispose();
            singleInstance.ReleaseMutex();
            singleInstance.Dispose();
        }

        private static void BuildTray()
        {
            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Font = new Font("Microsoft YaHei UI", 9f);
            ToolStripMenuItem captureItem = new ToolStripMenuItem("\u7acb\u5373\u622a\u56fe");
            captureItem.Click += delegate { BeginCapture(); };

            autoSaveItem = new ToolStripMenuItem("\u540c\u65f6\u4fdd\u5b58\u56fe\u7247");
            autoSaveItem.CheckOnClick = true;
            autoSaveItem.Checked = LoadAutoSave();
            autoSaveItem.CheckedChanged += delegate { SaveAutoSave(autoSaveItem.Checked); };

            ToolStripMenuItem openItem = new ToolStripMenuItem("\u6253\u5f00\u622a\u56fe\u6587\u4ef6\u5939");
            openItem.Click += delegate
            {
                Directory.CreateDirectory(screenshotsDirectory);
                System.Diagnostics.Process.Start("explorer.exe", screenshotsDirectory);
            };

            startupItem = new ToolStripMenuItem("\u5f00\u673a\u81ea\u52a8\u542f\u52a8");
            startupItem.CheckOnClick = true;
            startupItem.Checked = IsStartupEnabled();
            startupItem.CheckedChanged += StartupChanged;

            ToolStripMenuItem exitItem = new ToolStripMenuItem("\u9000\u51fa QuickShot");
            exitItem.Click += delegate { Application.Exit(); };

            menu.Items.Add(captureItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(autoSaveItem);
            menu.Items.Add(openItem);
            menu.Items.Add(startupItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(exitItem);

            tray = new NotifyIcon();
            string iconPath = Path.Combine(appDirectory, "QuickShot.ico");
            appIcon = File.Exists(iconPath) ? new Icon(iconPath) : (Icon)SystemIcons.Application.Clone();
            tray.Icon = appIcon;
            tray.Text = "QuickShot" + (hotKey.ActiveShortcut == null ? "" : "  \u00b7  " + hotKey.ActiveShortcut);
            tray.ContextMenuStrip = menu;
            tray.Visible = true;
            tray.DoubleClick += delegate { BeginCapture(); };
        }

        private static void BeginCapture()
        {
            if (capturing) return;
            capturing = true;
            try
            {
                Rectangle bounds = SystemInformation.VirtualScreen;
                Bitmap desktop = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
                using (Graphics g = Graphics.FromImage(desktop))
                    g.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size, CopyPixelOperation.SourceCopy);

                CaptureOverlay overlay = new CaptureOverlay(desktop, bounds);
                overlay.Captured += delegate(Bitmap image) { FinishCapture(image); };
                overlay.FormClosed += delegate { capturing = false; overlay.Dispose(); };
                overlay.Show();
            }
            catch (Exception ex)
            {
                capturing = false;
                MessageBox.Show("Capture failed: " + ex.Message, "QuickShot",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private static void FinishCapture(Bitmap image)
        {
            bool copied = false;
            Exception lastError = null;
            for (int i = 0; i < 5 && !copied; i++)
            {
                try
                {
                    Clipboard.SetImage(image);
                    copied = true;
                }
                catch (Exception ex)
                {
                    lastError = ex;
                    Thread.Sleep(80);
                }
            }

            string savedPath = null;
            if (autoSaveItem.Checked)
            {
                Directory.CreateDirectory(screenshotsDirectory);
                savedPath = Path.Combine(screenshotsDirectory,
                    "Screenshot_" + DateTime.Now.ToString("yyyyMMdd_HHmmss_fff") + ".png");
                image.Save(savedPath, ImageFormat.Png);
            }
            image.Dispose();

            if (copied)
                ShowNotice("Copied", savedPath == null ? "Paste it into ChatGPT with Ctrl+V." : "Copied and saved to Pictures\\QuickShot.");
            else
                MessageBox.Show("Could not access the clipboard: " + (lastError == null ? "unknown error" : lastError.Message),
                    "QuickShot", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        private static bool LoadAutoSave()
        {
            try { return File.Exists(settingsFile) && File.ReadAllText(settingsFile).Trim() == "save=true"; }
            catch { return false; }
        }

        private static void SaveAutoSave(bool enabled)
        {
            try { File.WriteAllText(settingsFile, enabled ? "save=true" : "save=false"); }
            catch { }
        }

        private static string LauncherPath()
        {
            return Application.ExecutablePath;
        }

        private static bool IsStartupEnabled()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Run"))
                    return key != null && key.GetValue(RunValueName) != null;
            }
            catch { return false; }
        }

        private static void SetStartup(bool enabled)
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(
                    "Software\\Microsoft\\Windows\\CurrentVersion\\Run", true))
                {
                    if (enabled)
                        key.SetValue(RunValueName, "\"" + LauncherPath() + "\"");
                    else
                        key.DeleteValue(RunValueName, false);
                }
            }
            catch (Exception ex)
            {
                changingStartup = true;
                startupItem.Checked = !enabled;
                changingStartup = false;
                MessageBox.Show("Could not change startup setting: " + ex.Message, "QuickShot",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private static void StartupChanged(object sender, EventArgs e)
        {
            if (changingStartup) return;
            SetStartup(startupItem.Checked);
        }

        private static void ShowNotice(string title, string text)
        {
            tray.BalloonTipTitle = title;
            tray.BalloonTipText = text;
            tray.BalloonTipIcon = ToolTipIcon.Info;
            tray.ShowBalloonTip(2200);
        }
    }

    public static class Program
    {
        [STAThread]
        public static void Main()
        {
            App.Run(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar));
        }
    }
}
'@

$baseDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$exePath = Join-Path $baseDirectory 'QuickShot.exe'
$iconPath = Join-Path $baseDirectory 'QuickShot.ico'
$sourceTime = (Get-Item $MyInvocation.MyCommand.Path).LastWriteTimeUtc
$needsBuild = -not (Test-Path $exePath) -or ((Get-Item $exePath).LastWriteTimeUtc -lt $sourceTime)

try {
    if ($needsBuild) {
        if (Test-Path $exePath) { Remove-Item $exePath -Force }
        $compiler = Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
        if (-not (Test-Path $compiler)) { throw 'Windows C# compiler was not found.' }
        $temporarySource = Join-Path $env:TEMP ('QuickShot_' + [Guid]::NewGuid().ToString('N') + '.cs')
        try {
            [IO.File]::WriteAllText($temporarySource, $source, [System.Text.UTF8Encoding]::new($true))
            $arguments = @(
                '/nologo', '/target:winexe', '/optimize+', '/platform:anycpu',
                "/out:$exePath", '/reference:System.Windows.Forms.dll',
                '/reference:System.Drawing.dll'
            )
            if (Test-Path $iconPath) { $arguments += "/win32icon:$iconPath" }
            $arguments += $temporarySource
            $compilerOutput = & $compiler $arguments 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exePath)) {
                throw ("Build failed.`r`n" + $compilerOutput)
            }
        }
        finally {
            if (Test-Path $temporarySource) { Remove-Item $temporarySource -Force }
        }
    }

    $desktop = [Environment]::GetFolderPath('Desktop')
    $shortcutPath = Join-Path $desktop 'QuickShot.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = $exePath
    $shortcut.WorkingDirectory = $baseDirectory
    $shortcut.Description = 'QuickShot - Alt+A'
    if (Test-Path $iconPath) { $shortcut.IconLocation = "$iconPath,0" }
    $shortcut.Save()

    Start-Process -FilePath $exePath -WorkingDirectory $baseDirectory
}
catch {
    [System.Windows.Forms.MessageBox]::Show(
        "QuickShot failed to install or start.`r`n`r`n$($_.Exception.Message)",
        'QuickShot',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

