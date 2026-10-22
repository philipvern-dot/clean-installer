# Clean Installer
# Open "Clean Installer" in the parent folder. This file is the program window.

param(
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
$script:SmokeTest = [bool]$SmokeTest

if (-not ('CleanInstaller.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
namespace CleanInstaller {
  public static class Native {
    [DllImport("kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  }

  public static class QuietLog {
    const int EM_SETSEL = 0x00B1;
    const int EM_REPLACESEL = 0x00C2;
    const int WM_VSCROLL = 0x0115;
    const int SB_BOTTOM = 7;

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto, EntryPoint = "SendMessage")]
    static extern IntPtr SendMessageText(IntPtr hWnd, int msg, IntPtr wParam, string text);

    public static void SelectRange(IntPtr handle, int start, int end) {
      SendMessage(handle, EM_SETSEL, (IntPtr)start, (IntPtr)end);
    }
    public static void Insert(IntPtr handle, string text) {
      SendMessageText(handle, EM_REPLACESEL, IntPtr.Zero, text ?? "");
    }
    public static void ScrollToEnd(IntPtr handle) {
      SendMessage(handle, WM_VSCROLL, (IntPtr)SB_BOTTOM, IntPtr.Zero);
    }
  }

  public static class ShellIcon {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern int ExtractIconEx(string file, int index, out IntPtr large, out IntPtr small, int count);
    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);
    public static System.Drawing.Icon Load(string file, int index) {
      IntPtr large, small;
      ExtractIconEx(file, index, out large, out small, 1);
      if (large == IntPtr.Zero) return null;
      System.Drawing.Icon icon = (System.Drawing.Icon)System.Drawing.Icon.FromHandle(large).Clone();
      DestroyIcon(large);
      if (small != IntPtr.Zero) DestroyIcon(small);
      return icon;
    }
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct ShellExecuteInfo {
    public int cbSize;
    public uint fMask;
    public IntPtr hwnd;
    public string lpVerb;
    public string lpFile;
    public string lpParameters;
    public string lpDirectory;
    public int nShow;
    public IntPtr hInstApp;
    public IntPtr lpIDList;
    public string lpClass;
    public IntPtr hkeyClass;
    public uint dwHotKey;
    public IntPtr hIcon;
    public IntPtr hProcess;
  }

  public static class Elevate {
    const uint SEE_MASK_NOCLOSEPROCESS = 0x00000040;
    const uint WAIT_INFINITE = 0xFFFFFFFF;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ShellExecuteEx(ref ShellExecuteInfo info);
    [DllImport("kernel32.dll")]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll")]
    static extern bool GetExitCodeProcess(IntPtr handle, out uint exitCode);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    public static int RunAs(string file, string arguments, string directory) {
      ShellExecuteInfo info = new ShellExecuteInfo();
      info.cbSize = Marshal.SizeOf(info);
      info.fMask = SEE_MASK_NOCLOSEPROCESS;
      info.lpVerb = "runas";
      info.lpFile = file;
      info.lpParameters = arguments;
      info.lpDirectory = directory;
      info.nShow = 0;
      if (!ShellExecuteEx(ref info)) {
        int err = Marshal.GetLastWin32Error();
        if (err == 1223) return -1223;
        throw new System.ComponentModel.Win32Exception(err);
      }
      if (info.hProcess == IntPtr.Zero) throw new InvalidOperationException("Administrator launch did not return a process.");
      WaitForSingleObject(info.hProcess, WAIT_INFINITE);
      uint code;
      GetExitCodeProcess(info.hProcess, out code);
      CloseHandle(info.hProcess);
      return unchecked((int)code);
    }
  }

  public sealed class ProcessSink {
    public readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public volatile int ExitCode;
    public volatile bool Exited;

    public void Attach(Process process, bool readOutput) {
      process.EnableRaisingEvents = true;
      process.Exited += OnExited;
      if (readOutput) {
        process.OutputDataReceived += OnData;
        process.ErrorDataReceived += OnData;
      }
    }

    void OnData(object sender, DataReceivedEventArgs e) {
      if (e.Data != null) Lines.Enqueue(e.Data);
    }

    void OnExited(object sender, EventArgs e) {
      Process process = sender as Process;
      try {
        ExitCode = process != null ? process.ExitCode : 1;
      } catch {
        ExitCode = 1;
      }
      Exited = true;
    }
  }
}
'@ -ReferencedAssemblies System.Drawing
}

function Hide-OwnConsole {
    try {
        $hwnd = [CleanInstaller.Native]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $owner = [uint32]0
        [void][CleanInstaller.Native]::GetWindowThreadProcessId($hwnd, [ref]$owner)
        if ($owner -eq [uint32]$PID) {
            [void][CleanInstaller.Native]::ShowWindow($hwnd, 0)
        }
    } catch { }
}

if (-not $SmokeTest) { Hide-OwnConsole }

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($SmokeTest) { $argList += '-SmokeTest' }
    if ($SmokeTest) {
        $child = Start-Process -FilePath $ps -ArgumentList $argList -Wait -PassThru
        exit $child.ExitCode
    }
    Start-Process -FilePath $ps -ArgumentList $argList | Out-Null
    exit 0
}

$script:AppDir = $PSScriptRoot
if (-not $script:AppDir) { $script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:Root = Split-Path -Parent $script:AppDir
$script:EnginePath = Join-Path $script:AppDir 'Engine.ps1'
$script:SettingsPath = Join-Path $script:AppDir 'settings.json'
if (-not (Test-Path -LiteralPath $script:EnginePath)) { throw "The engine is missing: $($script:EnginePath)" }
. $script:EnginePath

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::SetUnhandledExceptionMode([Windows.Forms.UnhandledExceptionMode]::CatchException)
[Windows.Forms.Application]::add_ThreadException({
    param($sender, $eventArgs)
    $msg = 'Something went wrong: ' + $eventArgs.Exception.Message
    try { Write-Activity $msg 'err' } catch { }
    if ($script:SmokeTest) {
        Write-Output ('SMOKE FAIL ' + $eventArgs.Exception.Message)
        exit 1
    }
    try {
        [Windows.Forms.MessageBox]::Show($script:Form, $msg, 'Clean Installer', 'OK', 'Error') | Out-Null
    } catch { }
})

$script:ColorPage = [Drawing.Color]::FromArgb(238, 241, 244)
$script:ColorInk = [Drawing.Color]::FromArgb(17, 24, 39)
$script:ColorMuted = [Drawing.Color]::FromArgb(75, 85, 99)
$script:ColorLine = [Drawing.Color]::FromArgb(214, 218, 225)
$script:ColorHeader = [Drawing.Color]::FromArgb(28, 36, 48)
$script:ColorHeaderMuted = [Drawing.Color]::FromArgb(209, 213, 219)
$script:ColorPrimary = [Drawing.Color]::FromArgb(29, 78, 216)
$script:ColorPrimaryHover = [Drawing.Color]::FromArgb(30, 64, 175)
$script:ColorDanger = [Drawing.Color]::FromArgb(185, 28, 28)
$script:ColorLogBg = [Drawing.Color]::FromArgb(28, 36, 48)
$script:ColorLogText = [Drawing.Color]::FromArgb(229, 231, 235)
$script:ColorLogOk = [Drawing.Color]::FromArgb(134, 239, 172)
$script:ColorLogWarn = [Drawing.Color]::FromArgb(252, 211, 77)
$script:ColorLogErr = [Drawing.Color]::FromArgb(252, 165, 165)
$script:ColorLogMuted = [Drawing.Color]::FromArgb(156, 163, 175)
$script:ColorOkText = [Drawing.Color]::FromArgb(22, 101, 52)
$script:ColorErrText = [Drawing.Color]::FromArgb(153, 27, 27)

$script:FontTitle = New-Object Drawing.Font('Segoe UI', 22, [Drawing.FontStyle]::Bold)
$script:FontSubtitle = New-Object Drawing.Font('Segoe UI', 10)
$script:FontSection = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
$script:FontUi = New-Object Drawing.Font('Segoe UI', 10)
$script:FontHint = New-Object Drawing.Font('Segoe UI', 9)
$script:FontButton = New-Object Drawing.Font('Segoe UI', 10)
$script:FontButtonBold = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$script:FontLog = New-Object Drawing.Font('Consolas', 10)
$script:FontHelpHeading = New-Object Drawing.Font('Segoe UI', 13, [Drawing.FontStyle]::Bold)
$script:FontHelpBody = New-Object Drawing.Font('Segoe UI', 10)

$script:View = 'search'
$script:Busy = $false
$script:AllowClose = $false
$script:LoadingSettings = $true
$script:ToolsOk = $false
$script:AutoAccept = $false
$script:Detailed = $false
$script:UnusedMonths = 6
$script:InstalledCache = $null
$script:Sink = $null
$script:JobOutput = New-Object Text.StringBuilder
$script:JobKind = ''
$script:JobPackage = $null
$script:JobExited = $false
$script:JobExitCode = 0
$script:JobInteractive = $false
$script:JobDeelevated = $false
$script:DeelevateExit = ''
$script:DeelevateLog = ''
$script:ShowInfo = @{}
$script:Proc = $null
$script:Tips = $null
$script:HelpText = ''
$script:UpdateRepo = 'clean-installer'
$script:UpdateAsset = 'clean_installer.exe'
$script:UpdateProduct = 'Clean Installer'
$script:UpdateFallback = '1.0.0'
$script:UpdateOffer = $null
$script:UpdatePrompt = ''
$script:UpdateClosing = $false
$script:UpdateCheckQueued = $false

function Enable-DoubleBuffer($control) {
    $prop = $control.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic')
    if ($prop) { $prop.SetValue($control, $true, $null) }
}

function Update-Shortcut {
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnkPath = Join-Path $script:Root 'Clean Installer.lnk'
        $lnk = $wsh.CreateShortcut($lnkPath)
        $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
        $lnk.Arguments = "//nologo `"$(Join-Path $script:AppDir 'launch.vbs')`""
        $lnk.WorkingDirectory = $script:Root
        $lnk.WindowStyle = 1
        $lnk.Description = 'Install and uninstall programs with winget'
        $iconPath = Get-AppIconPath
        if ($iconPath) { $lnk.IconLocation = $iconPath + ',0' }
        else { $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\imageres.dll') + ',189' }
        $lnk.Save()
    } catch { }
}

function Load-Settings {
    $defaults = @{ AutoAccept = $false; Detailed = $false; UnusedMonths = 6; UpdatePrompt = '' }
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return $defaults }
    try {
        $json = Get-Content -Raw -LiteralPath $script:SettingsPath -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $json.autoAccept) { $defaults.AutoAccept = [bool]$json.autoAccept }
        if ($null -ne $json.detailed) { $defaults.Detailed = [bool]$json.detailed }
        $months = 6
        try { $months = [int]$json.unusedMonths } catch { $months = 6 }
        if ($months -lt 1) { $months = 1 }
        if ($months -gt 36) { $months = 36 }
        $defaults.UnusedMonths = $months
        if ($json.updatePrompt) { $defaults.UpdatePrompt = [string]$json.updatePrompt }
    } catch { }
    return $defaults
}

function Save-Settings {
    if ($script:SmokeTest -or $script:LoadingSettings) { return }
    $payload = [pscustomobject]@{
        autoAccept = [bool]$script:AutoAccept
        detailed = [bool]$script:Detailed
        unusedMonths = [int]$script:UnusedMonths
        updatePrompt = [string]$script:UpdatePrompt
    }
    $json = ConvertTo-Json -InputObject $payload -Depth 3
    [IO.File]::WriteAllText($script:SettingsPath, $json)
}

function Update-ButtonFace($btn) {
    if ($null -eq $btn) { return }
    $role = [string]$btn.Tag
    $gray = [Drawing.Color]::FromArgb(229, 231, 235)
    $grayText = [Drawing.Color]::FromArgb(156, 163, 175)
    if (-not $btn.Enabled) {
        $btn.BackColor = $gray
        $btn.ForeColor = $grayText
        $btn.FlatAppearance.BorderColor = $gray
        $btn.FlatAppearance.MouseOverBackColor = $gray
        $btn.FlatAppearance.MouseDownBackColor = $gray
        return
    }
    if ($role -eq 'primary') {
        $btn.BackColor = $script:ColorPrimary
        $btn.ForeColor = [Drawing.Color]::White
        $btn.FlatAppearance.BorderColor = $script:ColorPrimary
        $btn.FlatAppearance.MouseOverBackColor = $script:ColorPrimaryHover
        $btn.FlatAppearance.MouseDownBackColor = $script:ColorPrimaryHover
    } elseif ($role -eq 'danger') {
        $btn.BackColor = [Drawing.Color]::White
        $btn.ForeColor = $script:ColorDanger
        $btn.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(252, 165, 165)
        $btn.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(254, 242, 242)
        $btn.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(254, 226, 226)
    } else {
        $btn.BackColor = [Drawing.Color]::White
        $btn.ForeColor = $script:ColorInk
        $btn.FlatAppearance.BorderColor = $script:ColorLine
        $btn.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(243, 244, 246)
        $btn.FlatAppearance.MouseDownBackColor = [Drawing.Color]::FromArgb(229, 231, 235)
    }
}

function New-Button([string]$text, [string]$role, [int]$width, [int]$height) {
    $btn = New-Object Windows.Forms.Button
    $btn.Text = $text
    $btn.Tag = $role
    $btn.Width = $width
    $btn.Height = $height
    $btn.FlatStyle = [Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 1
    $btn.Cursor = [Windows.Forms.Cursors]::Hand
    $btn.UseVisualStyleBackColor = $false
    $btn.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
    if ($role -eq 'primary') { $btn.Font = $script:FontButtonBold } else { $btn.Font = $script:FontButton }
    $btn.Add_EnabledChanged({ Update-ButtonFace $this })
    Update-ButtonFace $btn
    return $btn
}

function New-Check([string]$text) {
    $chk = New-Object Windows.Forms.CheckBox
    $chk.Text = $text
    $chk.AutoSize = $true
    $chk.Font = $script:FontUi
    $chk.ForeColor = $script:ColorInk
    $chk.BackColor = [Drawing.Color]::White
    $chk.UseVisualStyleBackColor = $false
    return $chk
}

function Set-Tip($control, [string]$text) {
    if ($script:Tips) { $script:Tips.SetToolTip($control, $text) }
}

function Resolve-HoverTip($parent, [Drawing.Point]$point) {
    if ($null -eq $parent -or $null -eq $script:Tips) { return $null }
    $child = $parent.GetChildAtPoint($point, [Windows.Forms.GetChildAtPointSkip]::Invisible)
    if ($null -eq $child -or $child.Enabled) { return $null }
    if (-not ($child -is [Windows.Forms.Button])) { return $null }
    $text = [string]$script:Tips.GetToolTip($child)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return [pscustomobject]@{ Control = $child; Text = $text }
}

function Hide-DisabledButtonTip {
    if ($script:DisabledTipParent -and $script:DisabledTips) {
        try { $script:DisabledTips.Hide($script:DisabledTipParent) } catch { }
    }
    $script:DisabledTipChild = $null
    $script:DisabledTipParent = $null
    $script:DisabledTipText = ''
    $script:DisabledTipShown = $null
}

function Note-DisabledButtonTip($parent) {
    if ($null -eq $parent) { return }
    $point = $parent.PointToClient([Windows.Forms.Cursor]::Position)
    $hit = Resolve-HoverTip $parent $point
    if ($null -eq $hit) {
        if ($script:DisabledTipParent -eq $parent) { Hide-DisabledButtonTip }
        return
    }
    if ($script:DisabledTipChild -eq $hit.Control) { return }
    Hide-DisabledButtonTip
    $script:DisabledTipChild = $hit.Control
    $script:DisabledTipParent = $parent
    $script:DisabledTipText = [string]$hit.Text
    $script:DisabledTipAt = [datetime]::UtcNow
}

function Show-PendingDisabledTip {
    if ($null -eq $script:DisabledTipChild -or $null -eq $script:DisabledTipParent) { return }
    if ($script:DisabledTipShown -eq $script:DisabledTipChild) { return }
    if (([datetime]::UtcNow - $script:DisabledTipAt).TotalMilliseconds -lt 400) { return }
    try {
        $parent = $script:DisabledTipParent
        $cursor = $parent.PointToClient([Windows.Forms.Cursor]::Position)
        $script:DisabledTips.Show($script:DisabledTipText, $parent, ($cursor.X + 16), ($cursor.Y + 20), 20000)
        $script:DisabledTipShown = $script:DisabledTipChild
    } catch {
        Hide-DisabledButtonTip
    }
}

function Enable-DisabledButtonTips($parent) {
    if ($null -eq $parent) { return }
    $parent.Add_MouseMove({ Note-DisabledButtonTip $this })
    $parent.Add_MouseLeave({
        if ($script:DisabledTipParent -eq $this) { Hide-DisabledButtonTip }
    })
}

function Set-Status([string]$text, [string]$kind) {
    if ($null -eq $script:StatusLabel) { return }
    $script:StatusLabel.Text = $text
    if ($kind -eq 'ok') { $script:StatusLabel.ForeColor = $script:ColorOkText }
    elseif ($kind -eq 'err') { $script:StatusLabel.ForeColor = $script:ColorErrText }
    elseif ($kind -eq 'busy') { $script:StatusLabel.ForeColor = $script:ColorInk }
    else { $script:StatusLabel.ForeColor = $script:ColorMuted }
}

function Set-ProgressIdle {
    $script:MarqueeOn = $false
    if ($script:ProgressFill) {
        $script:ProgressFill.Left = 0
        $script:ProgressFill.Width = 0
    }
}

function Update-Marquee {
    if (-not $script:MarqueeOn -or $null -eq $script:ProgressTrack) { return }
    $track = $script:ProgressTrack.ClientSize.Width
    if ($track -le 0) { return }
    $width = [Math]::Max(48, [int]($track * 0.28))
    $script:MarqueeX = ($script:MarqueeX + 16) % ($track + $width)
    $x = $script:MarqueeX - $width
    if ($x -lt 0) {
        $script:ProgressFill.Left = 0
        $script:ProgressFill.Width = [Math]::Max(8, $width + $x)
    } else {
        $script:ProgressFill.Left = $x
        $script:ProgressFill.Width = [Math]::Min($width, [Math]::Max(8, $track - $x))
    }
}

function Test-LogPinned {
    $box = $script:Log
    if ($null -eq $box) { return $true }
    $point = $box.GetPositionFromCharIndex([Math]::Max(0, $box.TextLength - 1))
    return ($point.Y -le ($box.ClientSize.Height + 8))
}

function Write-Activity([string]$message, [string]$kind) {
    $box = $script:Log
    if ($null -eq $box -or $box.IsDisposed) { return }
    $color = $script:ColorLogText
    if ($kind -eq 'ok') { $color = $script:ColorLogOk }
    elseif ($kind -eq 'warn') { $color = $script:ColorLogWarn }
    elseif ($kind -eq 'err') { $color = $script:ColorLogErr }
    elseif ($kind -eq 'dim') { $color = $script:ColorLogMuted }
    $follow = Test-LogPinned
    if ($box.TextLength -gt 180000) {
        [CleanInstaller.QuietLog]::SelectRange($box.Handle, 0, 60000)
        [CleanInstaller.QuietLog]::Insert($box.Handle, '')
    }
    [CleanInstaller.QuietLog]::SelectRange($box.Handle, $box.TextLength, $box.TextLength)
    $box.SelectionColor = $color
    [CleanInstaller.QuietLog]::Insert($box.Handle, ($message + [Environment]::NewLine))
    if ($follow) { [CleanInstaller.QuietLog]::ScrollToEnd($box.Handle) }
}

function Test-UsefulLine([string]$line) {
    if ([string]::IsNullOrWhiteSpace($line)) { return $false }
    if ($script:Detailed) { return $true }
    if ($line -match '^\s*[\\|/.\-]+\s*$') { return $false }
    if ($line -match '\d+\s*%') { return $false }
    return $true
}

function Get-SelectedEntry {
    if ($null -eq $script:Files -or $script:Files.SelectedItems.Count -eq 0) { return $null }
    return $script:Files.SelectedItems[0].Tag
}

function Get-SelectedPackage {
    $entry = Get-SelectedEntry
    if ($null -eq $entry) { return $null }
    if ($entry.PSObject.Properties.Name -contains 'Package' -and $entry.Package) { return $entry.Package }
    return $entry
}

function Update-Actions {
    $pkg = Get-SelectedPackage
    $busy = [bool]$script:Busy
    $have = $null -ne $pkg
    $catalog = $have -and [bool]$pkg.IsCatalog
    $canUpgrade = $have -and ($catalog -or -not [string]::IsNullOrWhiteSpace([string]$pkg.Available))
    $steam = $have -and (Test-SteamAppId ([string]$pkg.Id))
    $script:InstallButton.Enabled = (-not $busy -and $script:ToolsOk -and $catalog)
    $script:UpgradeButton.Enabled = (-not $busy -and $script:ToolsOk -and $canUpgrade)
    $script:UninstallButton.Enabled = (-not $busy -and $script:ToolsOk -and $have)
    $script:LeftoverButton.Enabled = (-not $busy -and $have -and -not $steam)
    $script:DetailsButton.Enabled = (-not $busy -and $have)
    $script:CancelButton.Enabled = $busy
    $script:UpgradeAllButton.Enabled = (-not $busy -and $script:ToolsOk)
    $script:SearchButton.Enabled = (-not $busy -and $script:ToolsOk)
    $script:RefreshButton.Enabled = (-not $busy -and $script:ToolsOk)
    $script:SourceButton.Enabled = (-not $busy -and $script:ToolsOk)
    $script:SearchBox.Enabled = (-not $busy)
    $script:Files.Enabled = -not $busy
    foreach ($btn in @($script:ViewSearch, $script:ViewInstalled, $script:ViewUpdates, $script:ViewSuspects)) {
        $btn.Enabled = -not $busy
    }
    foreach ($btn in @($script:InstallButton, $script:UpgradeButton, $script:UninstallButton, $script:LeftoverButton, $script:DetailsButton, $script:CancelButton, $script:UpgradeAllButton, $script:SearchButton, $script:RefreshButton, $script:SourceButton, $script:ViewSearch, $script:ViewInstalled, $script:ViewUpdates, $script:ViewSuspects, $script:HelpButton)) {
        Update-ButtonFace $btn
    }
    Update-UpdateButtons
    if ($script:DisabledTipChild -and $script:DisabledTipChild.Enabled) { Hide-DisabledButtonTip }
}

function Set-ListColumns([string]$view) {
    $script:Files.Columns.Clear()
    [void]$script:Files.Columns.Add('Name', 280)
    [void]$script:Files.Columns.Add('Id', 300)
    if ($view -eq 'updates') {
        [void]$script:Files.Columns.Add('Installed', 110)
        [void]$script:Files.Columns.Add('Available', 110)
        [void]$script:Files.Columns.Add('Source', 140)
    } elseif ($view -eq 'suspects') {
        [void]$script:Files.Columns.Add('Version', 110)
        [void]$script:Files.Columns.Add('Why', 360)
    } elseif ($view -eq 'search') {
        [void]$script:Files.Columns.Add('Version', 110)
        [void]$script:Files.Columns.Add('Source', 100)
        [void]$script:Files.Columns.Add('Match', 220)
    } else {
        [void]$script:Files.Columns.Add('Version', 140)
        [void]$script:Files.Columns.Add('Source', 220)
    }
}

function Resize-ListColumns {
    $lv = $script:Files
    if ($null -eq $lv -or $lv.Columns.Count -eq 0) { return }
    $used = 0
    for ($i = 0; $i -lt $lv.Columns.Count - 1; $i++) { $used += $lv.Columns[$i].Width }
    $lv.Columns[$lv.Columns.Count - 1].Width = [Math]::Max(140, $lv.ClientSize.Width - $used - 8)
}

function Show-PackageRows($rows, [string]$view) {
    $script:Files.BeginUpdate()
    $script:Files.Items.Clear()
    Set-ListColumns $view
    foreach ($row in @($rows)) {
        if ($null -eq $row) { continue }
        $pkg = $row
        $why = ''
        if ($row.PSObject.Properties.Name -contains 'Package' -and $row.Package) {
            $pkg = $row.Package
            $why = [string]$row.Why
        }
        $item = New-Object Windows.Forms.ListViewItem([string]$pkg.Name)
        $item.Tag = $row
        [void]$item.SubItems.Add([string]$pkg.Id)
        if ($view -eq 'updates') {
            [void]$item.SubItems.Add([string]$pkg.Version)
            [void]$item.SubItems.Add([string]$pkg.Available)
            [void]$item.SubItems.Add([string]$pkg.Source)
        } elseif ($view -eq 'suspects') {
            [void]$item.SubItems.Add([string]$pkg.Version)
            [void]$item.SubItems.Add($why)
        } elseif ($view -eq 'search') {
            [void]$item.SubItems.Add([string]$pkg.Version)
            [void]$item.SubItems.Add([string]$pkg.Source)
            [void]$item.SubItems.Add([string]$pkg.Match)
        } else {
            [void]$item.SubItems.Add([string]$pkg.Version)
            [void]$item.SubItems.Add([string]$pkg.Source)
        }
        [void]$script:Files.Items.Add($item)
    }
    $script:Files.EndUpdate()
    Resize-ListColumns
    Update-Actions
}

function Set-View([string]$view, [bool]$load) {
    $script:View = $view
    foreach ($pair in @(
        @{ Name = 'search'; Button = $script:ViewSearch },
        @{ Name = 'installed'; Button = $script:ViewInstalled },
        @{ Name = 'updates'; Button = $script:ViewUpdates },
        @{ Name = 'suspects'; Button = $script:ViewSuspects }
    )) {
        if ($pair.Name -eq $view) { $pair.Button.Tag = 'primary' } else { $pair.Button.Tag = 'secondary' }
        Update-ButtonFace $pair.Button
    }
    $searching = $view -eq 'search'
    $script:SearchHost.Visible = $searching
    $script:RefreshButton.Visible = -not $searching
    $script:UpgradeAllButton.Visible = ($view -eq 'updates')
    $script:ViewHint.Visible = -not $searching
    if ($view -eq 'installed') { $script:ViewHint.Text = 'Programs winget can see, including Windows inventory entries.' }
    elseif ($view -eq 'updates') { $script:ViewHint.Text = 'Packages with a newer version. Upgrade all asks before it starts.' }
    elseif ($view -eq 'suspects') { $script:ViewHint.Text = 'Known problem software, and programs with no recorded launches in the months you chose. Shared tools such as FFmpeg are left off.' }
    if ($view -eq 'search') { $script:HintLabel.Text = 'Type at least two characters. A catalog package can be installed. A Windows inventory row can be uninstalled.' }
    elseif ($view -eq 'installed') { $script:HintLabel.Text = 'Select a program, then install, upgrade, or uninstall it. Uninstall is followed by a leftover review.' }
    elseif ($view -eq 'updates') { $script:HintLabel.Text = 'Upgrade installs the available version. Upgrade all runs winget upgrade --all after you confirm.' }
    else { $script:HintLabel.Text = 'This is a hint list. It does not remove anything until you uninstall a selected row yourself.' }
    Show-PackageRows @() $view
    if ($view -eq 'installed' -and $script:InstalledCache) { Show-PackageRows $script:InstalledCache 'installed' }
    Layout-Query
    if ($load -and $view -ne 'search') { Start-ViewLoad $view }
}

function Layout-Query {
    $panel = $script:QueryPanel
    if ($null -eq $panel -or $panel.ClientSize.Width -lt 40) { return }
    $y = 4
    if ($script:View -eq 'search') {
        $script:SearchHost.SetBounds(0, $y, ([Math]::Max(120, $panel.ClientSize.Width - 128)), 36)
        $script:SearchButton.Location = New-Object Drawing.Point(($panel.ClientSize.Width - 112), ($y + 2))
    } else {
        $script:ViewHint.SetBounds(0, ($y + 6), ([Math]::Max(80, $panel.ClientSize.Width - 280)), 24)
        $script:UpgradeAllButton.Location = New-Object Drawing.Point(($panel.ClientSize.Width - 248), ($y + 2))
        $script:RefreshButton.Location = New-Object Drawing.Point(($panel.ClientSize.Width - 112), ($y + 2))
    }
}

function Layout-Actions {
    $panel = $script:ActionPanel
    if ($null -eq $panel -or $panel.ClientSize.Width -lt 40) { return }
    $y = [Math]::Max(0, [int](($panel.ClientSize.Height - 38) / 2))
    $x = 0
    foreach ($btn in @($script:InstallButton, $script:UpgradeButton, $script:UninstallButton, $script:LeftoverButton, $script:DetailsButton, $script:CancelButton)) {
        $btn.Location = New-Object Drawing.Point($x, $y)
        $x += $btn.Width + 8
    }
    $script:HelpButton.Location = New-Object Drawing.Point(($panel.ClientSize.Width - $script:HelpButton.Width), $y)
}

function Layout-Options {
    $card = $script:OptionsCard
    if ($null -eq $card -or $card.ClientSize.Width -lt 40) { return }
    $script:OptionsTitle.SetBounds(16, 12, ($card.ClientSize.Width - 32), 22)
    $script:AutoAcceptCheck.Location = New-Object Drawing.Point(16, 42)
    $script:DetailedCheck.Location = New-Object Drawing.Point(16, 70)
    $script:MonthsLabel.Location = New-Object Drawing.Point(16, 104)
    $labelWidth = $script:MonthsLabel.PreferredSize.Width
    if ($labelWidth -lt $script:MonthsLabel.Width) { $labelWidth = $script:MonthsLabel.Width }
    $script:MonthsBox.Location = New-Object Drawing.Point((28 + $labelWidth), 100)
}

function Update-ChromeLayout {
    $header = $script:Header
    if ($header -and $header.ClientSize.Width -gt 0) {
        $reserve = 28
        $leftEdge = $header.ClientSize.Width
        if ($script:CheckUpdateButton -and $script:UpdateButton) {
            $right = $header.ClientSize.Width - 24
            $script:UpdateButton.Location = New-Object Drawing.Point(($right - $script:UpdateButton.Width), 16)
            $script:CheckUpdateButton.Location = New-Object Drawing.Point(($script:UpdateButton.Left - 8 - $script:CheckUpdateButton.Width), 16)
            $leftEdge = $script:CheckUpdateButton.Left
        }
        if ($script:ReportBugButton -and $script:DonateButton) {
            $right = $header.ClientSize.Width - 24
            $script:ReportBugButton.Location = New-Object Drawing.Point(($right - $script:ReportBugButton.Width), 58)
            $script:DonateButton.Location = New-Object Drawing.Point(($script:ReportBugButton.Left - 8 - $script:DonateButton.Width), 58)
            if ($script:DonateButton.Left -lt $leftEdge) { $leftEdge = $script:DonateButton.Left }
        }
        $reserve = $header.ClientSize.Width - $leftEdge + 16
        $textWidth = [Math]::Max(160, ($header.ClientSize.Width - 28 - $reserve))
        $script:TitleLabel.SetBounds(28, 18, $textWidth, 36)
        $script:SubtitleLabel.SetBounds(28, 56, $textWidth, 40)
    }
    $status = $script:StatusPanel
    if ($status -and $status.ClientSize.Width -gt 0) {
        $versionGap = 0
        if ($script:VersionLabel) {
            $vw = $script:VersionLabel.PreferredSize.Width
            if ($vw -lt 1) { $vw = 48 }
            $script:VersionLabel.SetBounds(($status.ClientSize.Width - 24 - $vw), 8, $vw, 22)
            $versionGap = $vw + 12
        }
        $script:StatusLabel.SetBounds(24, 8, ([Math]::Max(80, $status.ClientSize.Width - 48 - $versionGap)), 22)
        $script:ProgressTrack.SetBounds(24, 36, ([Math]::Max(0, $status.ClientSize.Width - 48)), 8)
    }
    if ($script:ViewRow -and $script:ViewRow.ClientSize.Width -gt 0) {
        $script:ViewSearch.Location = New-Object Drawing.Point(0, 4)
        $script:ViewInstalled.Location = New-Object Drawing.Point(128, 4)
        $script:ViewUpdates.Location = New-Object Drawing.Point(268, 4)
        $script:ViewSuspects.Location = New-Object Drawing.Point(396, 4)
        $script:SourceButton.Location = New-Object Drawing.Point(($script:ViewRow.ClientSize.Width - $script:SourceButton.Width), 4)
    }
    Layout-Query
    Layout-Actions
    Layout-Options
    Resize-ListColumns
}

function Clear-JobLines {
    $sink = $script:Sink
    if ($sink) {
        $discard = ''
        while ($sink.Lines.TryDequeue([ref]$discard)) { }
    }
    $script:JobOutput = New-Object Text.StringBuilder
}

function Start-Job([string]$kind, [string[]]$command, $package, [bool]$interactive, [bool]$deelevated) {
    if ($script:Busy) {
        [Windows.Forms.MessageBox]::Show($script:Form, 'Finish or cancel the current job first.', 'Clean Installer', 'OK', 'Information') | Out-Null
        return
    }
    $script:Busy = $true
    $script:JobKind = $kind
    $script:JobPackage = $package
    $script:JobInteractive = $interactive
    $script:JobDeelevated = $deelevated
    $script:JobExited = $false
    $script:JobExitCode = 0
    $script:MarqueeOn = $true
    $script:MarqueeX = 0
    Clear-JobLines
    Update-Actions
    $line = Format-CommandLine $command
    if ($deelevated) { $line += '  (user-scope; dropping elevation)' }
    Write-Activity $line 'dim'
    if ($deelevated) {
        Start-DeelevatedJob $command $interactive
        return
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $command[0]
    $psi.Arguments = Format-CommandLine @($command | Select-Object -Skip 1)
    $psi.WorkingDirectory = $script:Root
    if ($interactive) {
        $psi.UseShellExecute = $true
        $psi.CreateNoWindow = $false
        $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    } else {
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $utf8 = New-Object Text.UTF8Encoding $false
        $psi.StandardOutputEncoding = $utf8
        $psi.StandardErrorEncoding = $utf8
    }
    $proc = New-Object Diagnostics.Process
    $proc.StartInfo = $psi
    $script:Sink = New-Object CleanInstaller.ProcessSink
    $script:Sink.Attach($proc, (-not $interactive))
    try {
        [void]$proc.Start()
        if (-not $interactive) {
            $proc.BeginOutputReadLine()
            $proc.BeginErrorReadLine()
        }
    } catch {
        $script:Busy = $false
        $script:MarqueeOn = $false
        Set-ProgressIdle
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        try { $proc.Dispose() } catch { }
        $script:Proc = $null
        Update-Actions
        Set-Status 'Could not start winget.' 'err'
        Write-Activity $_.Exception.Message 'err'
        return
    }
    $script:Proc = $proc
    if ($proc.HasExited) {
        if ($script:Sink.Exited) { $script:JobExitCode = [int]$script:Sink.ExitCode }
        else {
            try { $script:JobExitCode = [int]$proc.ExitCode } catch { $script:JobExitCode = 1 }
        }
        $script:JobExited = $true
    }
}

function Start-DeelevatedJob([string[]]$command, [bool]$interactive) {
    $stamp = '{0}-{1}' -f $PID, [DateTime]::UtcNow.Ticks
    $dir = $env:TEMP
    $spec = Join-Path $dir "ci-user-$stamp.json"
    $script:DeelevateLog = Join-Path $dir "ci-user-$stamp.log"
    $script:DeelevateExit = Join-Path $dir "ci-user-$stamp.exit"
    $launcher = Join-Path $dir "ci-user-$stamp.cmd"
    $payload = @{
        argv = @($command)
        log = $(if ($interactive) { $null } else { $script:DeelevateLog })
        exit = $script:DeelevateExit
        interactive = [bool]$interactive
    }
    [IO.File]::WriteAllText($spec, (ConvertTo-Json -InputObject $payload -Depth 5))
    $engine = $script:EnginePath
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cmd = @(
        '@echo off',
        'chcp 65001 >nul',
        "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$engine`" -RunCaptured `"$spec`"",
        "if exist `"$($script:DeelevateExit)`" goto cidone",
        "> `"$($script:DeelevateExit)`" echo 1",
        ':cidone'
    ) -join "`r`n"
    [IO.File]::WriteAllText($launcher, $cmd + "`r`n")
    $script:Proc = Start-Process -FilePath 'runas.exe' -ArgumentList @('/trustlevel:0x20000', $launcher) -PassThru -WindowStyle Hidden
    Write-Activity 'Waiting for the unelevated command to finish.' 'dim'
}

function Stop-CurrentJob {
    if (-not $script:Busy) { return }
    if ($script:JobDeelevated) {
        $script:JobExited = $true
        $script:JobExitCode = 1
        Write-Activity 'Stopped waiting. The unelevated command may still be running.' 'warn'
        return
    }
    if ($script:Proc -and -not $script:Proc.HasExited) {
        try { & taskkill.exe /PID $script:Proc.Id /T /F | Out-Null } catch { }
    }
    Write-Activity 'Cancel requested.' 'warn'
}

function Receive-JobLines {
    $sink = $script:Sink
    if ($null -eq $sink) { return }
    $line = ''
    while ($sink.Lines.TryDequeue([ref]$line)) {
        $clean = ConvertFrom-WingetLine $line
        if ([string]::IsNullOrWhiteSpace($clean)) { continue }
        [void]$script:JobOutput.AppendLine($clean)
        if (Test-UsefulLine $clean) { Write-Activity $clean 'text' }
    }
    if ($script:JobDeelevated -and $script:DeelevateLog -and (Test-Path -LiteralPath $script:DeelevateLog)) {
        try {
            $text = [IO.File]::ReadAllText($script:DeelevateLog)
            if ($text -and $script:JobOutput.Length -eq 0) {
                foreach ($raw in ($text -split "`n")) {
                    $clean = ConvertFrom-WingetLine $raw
                    if ($clean) {
                        [void]$script:JobOutput.AppendLine($clean)
                        if (Test-UsefulLine $clean) { Write-Activity $clean 'text' }
                    }
                }
            }
        } catch { }
    }
}

function Complete-Job {
    Receive-JobLines
    if ($script:JobInteractive) {
        Write-Activity '(command ran in a new console window. Output was not captured.)' 'dim'
    }
    $output = $script:JobOutput.ToString()
    $code = [int]$script:JobExitCode
    $kind = $script:JobKind
    $package = $script:JobPackage
    $script:Busy = $false
    $script:MarqueeOn = $false
    Set-ProgressIdle
    if ($script:Proc) {
        try { $script:Proc.Dispose() } catch { }
        $script:Proc = $null
    }
    Update-Actions
    if ($kind -eq 'search') {
        $rows = @(ConvertFrom-WingetTable $output)
        if ($script:View -eq 'search') { Show-PackageRows $rows 'search' }
        if ($rows.Count -eq 0) { Set-Status 'No packages matched.' 'idle' }
        else { Set-Status ("{0} packages." -f $rows.Count) 'ok' }
        return
    }
    if ($kind -eq 'installed' -or $kind -eq 'installed-then-suspects') {
        $script:InstalledCache = @(ConvertFrom-WingetTable $output)
        if ($kind -eq 'installed' -and $script:View -eq 'installed') {
            Show-PackageRows $script:InstalledCache 'installed'
            Set-Status ("{0} installed." -f @($script:InstalledCache).Count) 'ok'
        }
        if ($kind -eq 'installed-then-suspects') { Show-Suspects }
        return
    }
    if ($kind -eq 'updates') {
        $rows = @(ConvertFrom-WingetTable $output)
        if ($script:View -eq 'updates') { Show-PackageRows $rows 'updates' }
        Set-Status ("{0} updates." -f $rows.Count) 'ok'
        return
    }
    if ($kind -eq 'source') {
        if ($code -eq 0) {
            Set-Status 'Winget catalog is up to date.' 'ok'
            Write-Activity 'Winget catalog updated.' 'ok'
        } else {
            Set-Status ("Could not update the winget catalog. winget exited $code.") 'err'
            Write-Activity ("Could not update the winget catalog. winget exited $code.") 'err'
        }
        return
    }
    if ($kind -eq 'show-then-uninstall') {
        $script:ShowInfo = ConvertFrom-WingetShow $output
        Start-UninstallCommand $package
        return
    }
    if ($kind -eq 'details') {
        $info = ConvertFrom-WingetShow $output
        Open-Details $package $info
        Set-Status 'Ready' 'idle'
        return
    }
    if ($kind -eq 'uninstall') {
        Finish-Uninstall $package $code $output
        return
    }
    $script:InstalledCache = $null
    if ($code -eq 0) {
        Set-Status 'Done.' 'ok'
        Write-Activity 'Command finished.' 'ok'
    } else {
        Set-Status ("winget exited $code.") 'err'
        Write-Activity ("winget exited $code.") 'err'
    }
}

function Invoke-WorkTick {
    try {
        Show-PendingDisabledTip
        if ($script:MarqueeOn) { Update-Marquee }
        if (-not $script:Busy) { return }
        Receive-JobLines
        if ($script:JobDeelevated -and $script:DeelevateExit -and (Test-Path -LiteralPath $script:DeelevateExit)) {
            $raw = ''
            try { $raw = [IO.File]::ReadAllText($script:DeelevateExit).Trim() } catch { $raw = '' }
            $parsed = 1
            try { $parsed = [int]$raw } catch { $parsed = 1 }
            $script:JobExitCode = $parsed
            $script:JobExited = $true
        }
        if ($script:Sink -and $script:Sink.Exited -and -not $script:JobDeelevated) {
            $script:JobExitCode = [int]$script:Sink.ExitCode
            $script:JobExited = $true
        }
        if ($script:JobExited) {
            Complete-Job
            if ($script:UpdateCheckQueued -and -not $script:Busy) {
                $script:UpdateCheckQueued = $false
                Start-UpdateCheck -Automatic
            }
        }
    } catch {
        Write-Activity ("The window hit a problem. " + $_.Exception.Message) 'err'
    }
}

function Start-SourceUpdate {
    if (-not $script:ToolsOk -or $script:Busy) { return }
    Set-Status 'Updating the winget catalog...' 'busy'
    $cmd = @(New-WingetCommand -Verb 'source' -Argument @('update') -Mutate $false -AutoAccept $true)
    Start-Job 'source' $cmd $null $false $false
}

function Start-ViewLoad([string]$view) {
    if (-not $script:ToolsOk) { return }
    if ($view -eq 'installed') {
        Set-Status 'Reading installed programs...' 'busy'
        $cmd = @(New-WingetCommand -Verb 'list' -Argument @() -Mutate $false -AutoAccept $script:AutoAccept)
        Start-Job 'installed' $cmd $null $false $false
    } elseif ($view -eq 'updates') {
        Set-Status 'Looking for updates...' 'busy'
        $cmd = @(New-WingetCommand -Verb 'upgrade' -Argument @() -Mutate $false -AutoAccept $script:AutoAccept)
        Start-Job 'updates' $cmd $null $false $false
    } elseif ($view -eq 'suspects') {
        if ($null -eq $script:InstalledCache) {
            Set-Status 'Reading installed programs...' 'busy'
            $cmd = @(New-WingetCommand -Verb 'list' -Argument @() -Mutate $false -AutoAccept $script:AutoAccept)
            Start-Job 'installed-then-suspects' $cmd $null $false $false
        } else {
            Show-Suspects
        }
    }
}

function Show-Suspects {
    Set-Status 'Checking suspects...' 'busy'
    $script:Form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    [Windows.Forms.Application]::DoEvents()
    try {
        $arp = @(Get-UninstallRecords)
        $launches = @(Get-LaunchRecords)
        $rules = Read-ProblemRules ''
        $rows = @(Get-Suspects $script:InstalledCache $arp $launches $rules $script:UnusedMonths ([datetime]::Now))
        if ($script:View -eq 'suspects') { Show-PackageRows $rows 'suspects' }
        Set-Status ("{0} suspects." -f $rows.Count) 'ok'
    } catch {
        Set-Status 'Could not build the suspect list.' 'err'
        Write-Activity $_.Exception.Message 'err'
    } finally {
        $script:Form.Cursor = [Windows.Forms.Cursors]::Default
    }
}

function Start-Search {
    if ($script:Busy -or -not $script:ToolsOk) { return }
    $query = $script:SearchBox.Text.Trim()
    if ($query.Length -lt 2) {
        Set-Status 'Type at least two characters.' 'idle'
        return
    }
    Set-View 'search' $false
    Set-Status ("Searching for $query...") 'busy'
    $cmd = @(New-WingetCommand -Verb 'search' -Argument @($query, '--count', '80') -Mutate $false -AutoAccept $script:AutoAccept)
    Start-Job 'search' $cmd $null $false $false
}

function Confirm-Action([string]$title, [string]$body, [bool]$danger) {
    $icon = [Windows.Forms.MessageBoxIcon]::Question
    $buttons = [Windows.Forms.MessageBoxButtons]::OKCancel
    $default = [Windows.Forms.MessageBoxDefaultButton]::Button1
    if ($danger) { $default = [Windows.Forms.MessageBoxDefaultButton]::Button2 }
    $answer = [Windows.Forms.MessageBox]::Show($script:Form, $body, $title, $buttons, $icon, $default)
    return $answer -eq [Windows.Forms.DialogResult]::OK
}

function Start-Install {
    $pkg = Get-SelectedPackage
    if ($null -eq $pkg -or -not $pkg.IsCatalog) { return }
    $accept = 'off'
    if ($script:AutoAccept) { $accept = 'on' }
    $body = "Id: $($pkg.Id)`r`nThe command uses --id and --exact.`r`nAuto-accept is $accept."
    if (-not (Confirm-Action "Install $($pkg.Name)?" $body $false)) { return }
    Set-Status ("Installing $($pkg.Name)...") 'busy'
    $cmd = @(New-WingetCommand -Verb 'install' -Argument @('--id', [string]$pkg.Id, '--exact') -Mutate $true -AutoAccept $script:AutoAccept)
    $drop = (Test-IsAdmin) -and (Test-UserScopeId ([string]$pkg.Id))
    Start-Job 'install' $cmd $pkg (-not $script:AutoAccept) $drop
}

function Start-Upgrade {
    $pkg = Get-SelectedPackage
    if ($null -eq $pkg) { return }
    if (-not $pkg.IsCatalog -and [string]::IsNullOrWhiteSpace([string]$pkg.Available)) {
        [Windows.Forms.MessageBox]::Show($script:Form, 'No winget upgrade is available for this Windows inventory entry. You can still uninstall it.', 'Clean Installer', 'OK', 'Information') | Out-Null
        return
    }
    $next = [string]$pkg.Available
    if (-not $next) { $next = 'latest' }
    $body = "Id: $($pkg.Id)`r`n$($pkg.Version) -> $next"
    if (-not (Confirm-Action "Upgrade $($pkg.Name)?" $body $false)) { return }
    Set-Status ("Upgrading $($pkg.Name)...") 'busy'
    $cmd = @(New-WingetCommand -Verb 'upgrade' -Argument @('--id', [string]$pkg.Id, '--exact') -Mutate $true -AutoAccept $script:AutoAccept)
    $drop = (Test-IsAdmin) -and (Test-UserScopeId ([string]$pkg.Id))
    Start-Job 'upgrade' $cmd $pkg (-not $script:AutoAccept) $drop
}

function Start-UpgradeAll {
    if (-not (Confirm-Action 'Upgrade all packages?' "This runs winget upgrade --all.`r`nCancel leaves everything as it is." $true)) { return }
    Set-Status 'Upgrading all packages...' 'busy'
    $cmd = @(New-WingetCommand -Verb 'upgrade' -Argument @('--all') -Mutate $true -AutoAccept $script:AutoAccept)
    Start-Job 'upgrade-all' $cmd $null (-not $script:AutoAccept) $false
}

function Start-Uninstall {
    $pkg = Get-SelectedPackage
    if ($null -eq $pkg) { return }
    if (Test-SteamAppId ([string]$pkg.Id)) {
        $body = "This is a Steam game. Clean Installer opens Steam's uninstall dialog.`r`nConfirm it in Steam. The game folder is not deleted here."
    } else {
        $body = "The program is removed first.`r`nThen leftovers are listed. Folders start unticked.`r`nFiles go to the Recycle Bin. Registry keys are deleted."
        $dependencyNote = Get-DependencyUninstallNote $pkg (Find-ArpRecord $pkg $null)
        if ($dependencyNote) { $body += "`r`n`r`n" + $dependencyNote }
    }
    if (-not (Confirm-Action "Uninstall $($pkg.Name)?" $body $true)) { return }
    if (Test-SteamAppId ([string]$pkg.Id)) {
        $number = Get-SteamAppNumber ([string]$pkg.Id)
        $url = "steam://uninstall/$number"
        Write-Activity ("explorer.exe " + $url) 'dim'
        Start-Process explorer.exe $url | Out-Null
        Set-Status "Opened Steam uninstall for $($pkg.Name). Confirm in Steam if it asks." 'ok'
        Write-Activity 'Steam should show an uninstall dialog. Leftover scan is skipped.' 'text'
        return
    }
    $script:ShowInfo = @{}
    $id = [string]$pkg.Id
    if ($id.ToUpperInvariant().StartsWith('ARP\')) {
        Write-Activity 'Skipped winget show for this Windows inventory entry.' 'dim'
        Start-UninstallCommand $pkg
        return
    }
    Set-Status ("Reading $($pkg.Name)...") 'busy'
    $cmd = @(New-WingetCommand -Verb 'show' -Argument @('--id', $id, '--exact') -Mutate $false -AutoAccept $script:AutoAccept)
    Start-Job 'show-then-uninstall' $cmd $pkg $false $false
}

function Start-UninstallCommand($package) {
    Set-Status ("Uninstalling $($package.Name)...") 'busy'
    $cmd = @(New-WingetCommand -Verb 'uninstall' -Argument @('--id', [string]$package.Id, '--exact') -Mutate $true -AutoAccept $script:AutoAccept)
    $drop = (Test-IsAdmin) -and (Test-UserScopeId ([string]$package.Id))
    Start-Job 'uninstall' $cmd $package (-not $script:AutoAccept) $drop
}

function Finish-Uninstall($package, [int]$code, [string]$output) {
    $script:InstalledCache = $null
    $ok = ($code -eq 0)
    $trust = $false
    if ($ok) { $trust = $true }
    elseif (Test-OrphanedProduct $output) {
        $trust = $true
        Write-Activity 'Windows Installer error 1605: this product is already gone. Offering cleanup.' 'warn'
    } elseif (Test-AdminBlockedUserScope $code $output) {
        Write-Activity 'winget blocked this per-user uninstall from an elevated window. Nothing is ticked.' 'warn'
    } elseif (([string]$package.Id).ToUpperInvariant().StartsWith('ARP\')) {
        Write-Activity "Uninstall exited $code. Nothing is ticked. The program may still be installed." 'warn'
    } else {
        Set-Status "Uninstall exited $code. Leftover scan skipped." 'err'
        Write-Activity 'Uninstall did not complete. Leftover scan skipped.' 'err'
        return
    }
    Present-Leftovers $package $script:ShowInfo $trust $true
}

function Start-LeftoverScan {
    $pkg = Get-SelectedPackage
    if ($null -eq $pkg) { return }
    if (Test-SteamAppId ([string]$pkg.Id)) {
        [Windows.Forms.MessageBox]::Show($script:Form, 'Steam manages this install. Leftover removal is skipped so the Steam library is not touched.', 'Clean Installer', 'OK', 'Information') | Out-Null
        return
    }
    $info = @{}
    $id = [string]$pkg.Id
    if (-not $id.ToUpperInvariant().StartsWith('ARP\') -and $script:ToolsOk) {
        Set-Status ("Reading $($pkg.Name)...") 'busy'
        $script:Form.Cursor = [Windows.Forms.Cursors]::WaitCursor
        try {
            $cmd = @(New-WingetCommand -Verb 'show' -Argument @('--id', $id, '--exact') -Mutate $false -AutoAccept $false)
            Write-Activity (Format-CommandLine $cmd) 'dim'
            $psi = New-Object Diagnostics.ProcessStartInfo
            $psi.FileName = $cmd[0]
            $psi.Arguments = Format-CommandLine @($cmd | Select-Object -Skip 1)
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.StandardOutputEncoding = [Console]::OutputEncoding
            $proc = [Diagnostics.Process]::Start($psi)
            $text = $proc.StandardOutput.ReadToEnd()
            $proc.WaitForExit()
            $info = ConvertFrom-WingetShow $text
        } catch {
            Write-Activity ('winget show failed (' + $_.Exception.Message + '). Scanning by name.') 'warn'
        } finally {
            $script:Form.Cursor = [Windows.Forms.Cursors]::Default
        }
    } else {
        Write-Activity 'Skipped winget show for this Windows inventory entry. Using the uninstall registry.' 'dim'
    }
    Present-Leftovers $pkg $info $false $false
}

function Present-Leftovers($package, $showInfo, [bool]$trust, [bool]$afterUninstall) {
    Set-Status 'Scanning leftovers...' 'busy'
    $script:Form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    [Windows.Forms.Application]::DoEvents()
    try {
        $found = @(Find-Leftovers $package $showInfo)
        $unique = [System.Collections.Generic.List[object]]::new()
        $seen = @{}
        foreach ($item in $found) {
            $key = [string]$item.Path
            if (-not $key -or $seen.ContainsKey($key.ToLowerInvariant())) { continue }
            $seen[$key.ToLowerInvariant()] = $true
            [void]$unique.Add($item)
        }
        Set-LeftoverSelection $unique $trust | Out-Null
        if ($unique.Count -eq 0) {
            if ($afterUninstall) { Set-Status "Uninstalled $($package.Name). No leftovers found." 'ok' }
            else { Set-Status "No leftovers found for $($package.Name)." 'ok' }
            return
        }
        Set-Status 'Review the leftovers. Nothing else is removed until you tick it.' 'idle'
        Show-LeftoverForm $package @($unique.ToArray()) $true | Out-Null
        if ($afterUninstall) { Set-Status "Uninstalled $($package.Name)." 'ok' }
        else { Set-Status 'Ready' 'idle' }
    } catch {
        Set-Status 'Leftover scan failed.' 'err'
        Write-Activity $_.Exception.Message 'err'
    } finally {
        $script:Form.Cursor = [Windows.Forms.Cursors]::Default
    }
}

function Format-LeftoverLabel($item) {
    $prefix = ''
    if (Test-LeftoverNeedsAdmin $item) { $prefix = '[admin] ' }
    $kind = 'File'
    if ($item.Kind -eq 'registry') { $kind = 'Registry' }
    elseif ($item.Kind -eq 'directory') { $kind = 'Folder' }
    return "$prefix$kind   $($item.Path)"
}

function New-LeftoverForm($package, $items) {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Leftovers'
    $form.StartPosition = 'CenterParent'
    $form.Font = $script:FontUi
    $form.BackColor = $script:ColorPage
    $form.ClientSize = New-Object Drawing.Size(760, 520)
    $form.MinimumSize = New-Object Drawing.Size(640, 420)
    $form.ShowInTaskbar = $false
    $title = New-Object Windows.Forms.Label
    $title.Text = $package.Name
    $title.Font = $script:FontSection
    $title.ForeColor = $script:ColorInk
    $title.SetBounds(20, 16, 720, 24)
    $intro = New-Object Windows.Forms.Label
    $intro.Text = 'Tick what should be removed. Folders go to the Recycle Bin. Registry keys are deleted. [admin] rows need approval.'
    $intro.Font = $script:FontHint
    $intro.ForeColor = $script:ColorMuted
    $intro.SetBounds(20, 44, 720, 36)
    $list = New-Object Windows.Forms.CheckedListBox
    $list.Font = $script:FontUi
    $list.CheckOnClick = $true
    $list.IntegralHeight = $false
    $list.SetBounds(20, 88, 720, 300)
    $list.Anchor = 'Top,Left,Right,Bottom'
    foreach ($item in @($items)) {
        [void]$list.Items.Add($item, [bool]$item.Selected)
    }
    $reason = New-Object Windows.Forms.Label
    $reason.Font = $script:FontHint
    $reason.ForeColor = $script:ColorInk
    $reason.SetBounds(20, 396, 720, 40)
    $reason.Anchor = 'Left,Right,Bottom'
    $list.FormattingEnabled = $true
    $list.add_Format({
        param($sender, $eventArgs)
        $eventArgs.Value = Format-LeftoverLabel $eventArgs.ListItem
    })
    $remove = New-Button 'Remove selected' 'danger' 160 34
    $close = New-Button 'Close' 'secondary' 100 34
    Set-Tip $remove 'Remove the ticked leftovers. Folders go to the Recycle Bin. Registry keys are deleted.'
    Set-Tip $close 'Close this list. Nothing else is removed.'
    $remove.Anchor = 'Bottom,Right'
    $close.Anchor = 'Bottom,Right'
    $form.Controls.AddRange(@($title, $intro, $list, $reason, $remove, $close))
    Enable-DisabledButtonTips $form
    # Event scriptblocks cannot see function locals. Keep the controls on the form.
    $form.Tag = [pscustomobject]@{
        List = $list
        Reason = $reason
        Remove = $remove
        Close = $close
        Intro = $intro
    }
    $list.Add_SelectedIndexChanged({
        param($sender, $eventArgs)
        $ui = $sender.FindForm().Tag
        $entry = $sender.SelectedItem
        if ($entry) { $ui.Reason.Text = [string]$entry.Reason } else { $ui.Reason.Text = '' }
    })
    $form.Add_Shown({
        param($sender, $eventArgs)
        $ui = $sender.Tag
        $ui.Close.Location = New-Object Drawing.Point(($sender.ClientSize.Width - 120), ($sender.ClientSize.Height - 50))
        $ui.Remove.Location = New-Object Drawing.Point(($ui.Close.Left - 168), ($sender.ClientSize.Height - 50))
        $ui.Close.Focus()
    })
    $form.Add_Resize({
        param($sender, $eventArgs)
        $ui = $sender.Tag
        $ui.Close.Location = New-Object Drawing.Point(($sender.ClientSize.Width - 120), ($sender.ClientSize.Height - 50))
        $ui.Remove.Location = New-Object Drawing.Point(($ui.Close.Left - 168), ($sender.ClientSize.Height - 50))
        $ui.List.Width = $sender.ClientSize.Width - 40
        $ui.Intro.Width = $sender.ClientSize.Width - 40
        $ui.Reason.Width = $sender.ClientSize.Width - 40
        $ui.Reason.Top = $sender.ClientSize.Height - 100
        $ui.List.Height = $ui.Reason.Top - $ui.List.Top - 8
    })
    $remove.Add_Click({
        param($sender, $eventArgs)
        $owner = $sender.FindForm()
        $ui = $owner.Tag
        $chosen = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in @($ui.List.CheckedItems)) { [void]$chosen.Add($entry) }
        if ($chosen.Count -eq 0) {
            [Windows.Forms.MessageBox]::Show($owner, 'Tick at least one leftover first.', 'Clean Installer', 'OK', 'Information') | Out-Null
            return
        }
        $body = "Remove $($chosen.Count) selected leftovers?`r`nFolders go to the Recycle Bin. Registry keys are deleted."
        if (-not (Confirm-Action 'Remove selected leftovers?' $body $true)) { return }
        $needsAdmin = $false
        foreach ($entry in $chosen) {
            if (Test-LeftoverNeedsAdmin $entry) { $needsAdmin = $true }
        }
        $lines = @()
        if ($needsAdmin -and -not (Test-IsAdmin)) {
            $answer = [Windows.Forms.MessageBox]::Show($owner, 'Windows will ask for administrator approval to remove leftovers under Program Files or HKLM.', 'Clean Installer', 'OKCancel', 'Warning', 'Button2')
            if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
            $lines = @(Invoke-ElevatedCleanup $chosen)
        } else {
            $lines = @(Remove-Leftovers $chosen)
        }
        foreach ($line in @($lines)) {
            $kind = 'text'
            if ($line.StartsWith('OK')) { $kind = 'ok' }
            elseif ($line.StartsWith('FAIL')) { $kind = 'err' }
            elseif ($line.StartsWith('SKIP')) { $kind = 'warn' }
            Write-Activity $line $kind
        }
        $owner.DialogResult = 'OK'
        $owner.Close()
    })
    $close.Add_Click({
        param($sender, $eventArgs)
        $sender.FindForm().Close()
    })
    return $form
}

function Show-LeftoverForm($package, $items, [bool]$modal) {
    $form = New-LeftoverForm $package $items
    if ($modal -and -not $script:SmokeTest) {
        [void]$form.ShowDialog($script:Form)
        $form.Dispose()
        return $null
    }
    $form.Show($script:Form)
    return $form
}

function Invoke-ElevatedCleanup($items) {
    $stamp = '{0}-{1}' -f $PID, [DateTime]::UtcNow.Ticks
    $inPath = Join-Path $env:TEMP "ci-cleanup-$stamp.json"
    $outPath = Join-Path $env:TEMP "ci-cleanup-$stamp.out.json"
    [IO.File]::WriteAllText($inPath, (ConvertTo-LeftoverJson $items))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$($script:EnginePath)`" -CleanupLeftovers `"$inPath`" `"$outPath`""
    try {
        $code = [CleanInstaller.Elevate]::RunAs($ps, $arguments, $script:Root)
        if ($code -eq -1223) {
            return @($items | ForEach-Object { "FAIL $($_.Path) (Administrator prompt declined)" })
        }
        if (Test-Path -LiteralPath $outPath) {
            $parsed = @(ConvertFrom-JsonArray ([IO.File]::ReadAllText($outPath)))
            if ($parsed.Count -gt 0) { return $parsed }
        }
        return @('FAIL elevated leftover cleanup produced no results')
    } catch {
        return @("FAIL elevated leftover cleanup ($($_.Exception.Message))")
    } finally {
        Remove-Item -LiteralPath $inPath, $outPath -Force -ErrorAction SilentlyContinue
    }
}

function Start-Details {
    $entry = Get-SelectedEntry
    $pkg = Get-SelectedPackage
    if ($null -eq $pkg) { return }
    $note = ''
    if ($entry -and ($entry.PSObject.Properties.Name -contains 'Why')) { $note = [string]$entry.Why }
    $id = [string]$pkg.Id
    if ($id.ToUpperInvariant().StartsWith('ARP\') -or -not $script:ToolsOk) {
        Open-Details $pkg @{} $note
        return
    }
    Set-Status 'Reading package details...' 'busy'
    $cmd = @(New-WingetCommand -Verb 'show' -Argument @('--id', $id, '--exact') -Mutate $false -AutoAccept $script:AutoAccept)
    $pkg | Add-Member -NotePropertyName Note -NotePropertyValue $note -Force
    Start-Job 'details' $cmd $pkg $false $false
}

function Update-DetailsLayout($dialog) {
    $ui = $dialog.Tag
    $ui.Home.Location = New-Object Drawing.Point(20, ($dialog.ClientSize.Height - 50))
    $ui.Web.Location = New-Object Drawing.Point(178, ($dialog.ClientSize.Height - 50))
    $ui.Close.Location = New-Object Drawing.Point(($dialog.ClientSize.Width - 120), ($dialog.ClientSize.Height - 50))
    $ui.Body.Width = $dialog.ClientSize.Width - 40
    $ui.Body.Height = $dialog.ClientSize.Height - 130
    $ui.Title.Width = $dialog.ClientSize.Width - 40
}

function Open-Details($package, $showInfo, [string]$note) {
    if (-not $note -and $package.Note) { $note = [string]$package.Note }
    $arp = Find-ArpRecord $package $null
    $details = New-PackageDetails $package $showInfo $arp $note
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Details'
    $form.StartPosition = 'CenterParent'
    $form.Font = $script:FontUi
    $form.BackColor = $script:ColorPage
    $form.ClientSize = New-Object Drawing.Size(640, 460)
    $form.MinimumSize = New-Object Drawing.Size(520, 380)
    $form.ShowInTaskbar = $false
    $title = New-Object Windows.Forms.Label
    $title.Text = $details.Name
    $title.Font = $script:FontSection
    $title.SetBounds(20, 16, 600, 28)
    $body = New-Object Windows.Forms.TextBox
    $body.Multiline = $true
    $body.ReadOnly = $true
    $body.BorderStyle = 'None'
    $body.BackColor = [Drawing.Color]::White
    $body.Font = $script:FontUi
    $body.ScrollBars = 'Vertical'
    $body.SetBounds(20, 56, 600, 320)
    $body.Anchor = 'Top,Bottom,Left,Right'
    $lines = @(
        $details.Summary,
        '',
        "Id: $($details.Id)",
        "Version: $($details.Version)",
        "Publisher: $($details.Publisher)",
        "Source: $($details.Source)"
    )
    if ($details.InstallLocation) { $lines += "Folder: $($details.InstallLocation)" }
    if ($details.Homepage) { $lines += "Homepage: $($details.Homepage)" }
    $body.Text = ($lines -join "`r`n")
    $pageButton = New-Button 'Open homepage' 'secondary' 150 34
    $web = New-Button 'Search the web' 'secondary' 150 34
    $close = New-Button 'Close' 'primary' 100 34
    $pageButton.Enabled = [bool]$details.Homepage
    if ($details.Homepage) { Set-Tip $pageButton "Open this program's homepage in your browser." }
    else { Set-Tip $pageButton 'No homepage was found for this program.' }
    Set-Tip $web 'Search the web for this program.'
    Set-Tip $close 'Close the details.'
    $pageButton.Anchor = 'Bottom,Left'
    $web.Anchor = 'Bottom,Left'
    $close.Anchor = 'Bottom,Right'
    $form.Controls.AddRange(@($title, $body, $pageButton, $web, $close))
    Enable-DisabledButtonTips $form
    $form.Tag = [pscustomobject]@{
        Home = $pageButton
        Web = $web
        Close = $close
        Body = $body
        Title = $title
        Details = $details
    }
    $form.Add_Shown({
        param($sender, $eventArgs)
        Update-DetailsLayout $sender
        $ui = $sender.Tag
        $ui.Body.SelectionStart = $ui.Body.Text.Length
        $ui.Body.SelectionLength = 0
        $ui.Close.Focus()
    })
    $form.Add_Resize({
        param($sender, $eventArgs)
        Update-DetailsLayout $sender
    })
    $pageButton.Add_Click({
        param($sender, $eventArgs)
        $page = [string]$sender.FindForm().Tag.Details.Homepage
        if ($page) { Start-Process $page }
    })
    $web.Add_Click({
        param($sender, $eventArgs)
        Start-Process ([string]$sender.FindForm().Tag.Details.SearchUrl)
    })
    $close.Add_Click({
        param($sender, $eventArgs)
        $sender.FindForm().Close()
    })
    if ($script:SmokeTest) { return $form }
    [void]$form.ShowDialog($script:Form)
    $form.Dispose()
    return $null
}

function New-HelpForm {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'How this works'
    $form.StartPosition = 'CenterParent'
    $form.Font = $script:FontUi
    $form.BackColor = $script:ColorPage
    $form.ClientSize = New-Object Drawing.Size(720, 640)
    $form.MinimumSize = New-Object Drawing.Size(560, 420)
    $form.ShowInTaskbar = $false
    $box = New-Object Windows.Forms.RichTextBox
    $box.ReadOnly = $true
    $box.BorderStyle = 'None'
    $box.BackColor = $script:ColorPage
    $box.DetectUrls = $false
    $box.Dock = 'Fill'
    $box.Font = $script:FontHelpBody
    $box.Text = @"
Clean Installer

Clean Installer installs and uninstalls programs by running winget, the Windows Package Manager. It is not a Microsoft product. The activity box shows the command that ran.

Search
Type at least two characters and choose Search. The rows come from the winget catalog. Install works on those catalog packages.

Catalog
Update catalog downloads the current package list from the winget sources. Clean Installer also does that each time the window opens, before you search. A package that was added or removed upstream will not show up until that list is refreshed.

Installed
This list is everything winget can see. Rows whose id starts with ARP\ come from Windows inventory. They can be uninstalled. They are not installed from this window.

Updates
Upgrade changes the selected program to the available version. Upgrade all runs winget upgrade --all. Cancel is the default on that question.

Uninstall and leftovers
Uninstall removes the program, then lists registry keys and folders that still look like it. Nothing on that list is removed until you tick it and choose Remove selected. Folders go to the Recycle Bin. Registry keys are deleted. After a successful uninstall, matching Add/Remove Programs keys start ticked. Folders start unticked. A failed uninstall starts with nothing ticked.

These are never offered: your profile, Documents, Desktop, Downloads, the Windows directory, a Steam, Epic, GOG, or Xbox library, and shared vendor registry roots such as Microsoft or Google. A Steam game opens Steam's own uninstall dialog, and its folders are not touched.

Suspects
Suspects flags known problem or trial software, and programs with no recorded launches for the months chosen beside Flag after not used for. That choice only changes this list. Windows only records when you launch a program yourself. It does not record a tool another program runs in the background. Known dependencies such as FFmpeg are left off this unused list, because a missing launch is not evidence they are unused. Uninstall still explains that before it removes one. Other background programs can still look unused. Steam games, Visual C++ and .NET runtimes, and GPU or chipset drivers are left out. The list does not remove anything by itself.

Auto-accept
Auto-accept agreements and install quietly is saved in app\settings.json. When it is on, install and upgrade accept package agreements and run silent. Uninstall runs silent too, without the package-agreement flag, because winget rejects it. When it is off, those commands open a console so you can answer the installer.

Version and updates
The bottom right corner shows this copy's version. The program checks for updates when it opens. Check for updates looks again. When a newer version is found, a window tells you once. Closing that window keeps it from opening again until a later version is published. The status line keeps saying that version is available. Update downloads it and opens the setup program. The setup replaces the installed copy and keeps your settings. The setup asks whether to create a Start menu shortcut and whether to create a desktop shortcut.

Finish or cancel the current job before you update. The program closes while the setup runs, then you can open it again.

Donate opens a tip page. The program stays free. A tip of `$5 or more can include a feature suggestion on that page. Report a bug opens a GitHub page with this version and the Windows version filled in. Include latest activity is a choice on that step. Leave it unchecked and nothing else is added. Those lines can include folder paths. The program does not send the report. You submit it on the GitHub page.

What is in this folder
app\CleanInstaller.ps1 is this window. app\launch.vbs starts it. app\Engine.ps1 holds the winget reading and the leftover rules. app\data\known_problem.json is the suspect hint list. app\settings.json remembers your options. app\version.txt is the version.
"@
    $script:HelpText = $box.Text
    $form.Controls.Add($box)
    return $form
}

function Show-Help {
    if ($script:HelpForm -and -not $script:HelpForm.IsDisposed) {
        $script:HelpForm.Activate()
        return
    }
    $script:HelpForm = New-HelpForm
    if ($script:SmokeTest) {
        $script:HelpForm.Show($script:Form)
        return
    }
    [void]$script:HelpForm.Show($script:Form)
}

function Save-FormImage($targetForm, [string]$path) {
    $bmp = New-Object Drawing.Bitmap $targetForm.Width, $targetForm.Height
    $targetForm.DrawToBitmap($bmp, (New-Object Drawing.Rectangle 0, 0, $targetForm.Width, $targetForm.Height))
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

function Invoke-SmokeTest {
    $script:AllowClose = $true
    $script:Form.Show()
    [Windows.Forms.Application]::DoEvents()
    Update-ChromeLayout
    Assert-True ($script:TitleLabel.Text -eq 'Clean Installer') 'title'
    Assert-True ($script:CheckUpdateButton.Text -eq 'Check for updates') 'Check for updates was missing'
    Assert-True (-not $script:UpdateButton.Enabled) 'Update started enabled'
    Assert-True ($script:CheckUpdateButton.Parent -eq $script:Header) 'Check for updates is not in the header'
    Assert-True ($script:UpdateButton.Parent -eq $script:Header) 'Update is not in the header'
    Assert-True ((Get-AppVersion) -eq '1.0.0') 'Version file was not 1.0.0'
    Assert-True ($script:VersionLabel.Text -eq '1.0.0') 'The version was not shown'
    Assert-True ($script:VersionLabel.Parent -eq $script:StatusPanel) 'The version is not in the status bar'
    Assert-True ($script:DonateButton.Text -eq 'Donate') 'Donate was missing'
    Assert-True ($script:ReportBugButton.Text -eq 'Report a bug') 'Report a bug was missing'
    Assert-True ($script:DonateButton.Parent -eq $script:Header) 'Donate is not in the header'
    Assert-True ($script:Tips.GetToolTip($script:DonateButton) -eq 'Free forever. Tips of $5 or more can include a feature suggestion.') 'Donate tooltip'
    Assert-True ($script:Tips.GetToolTip($script:ReportBugButton) -match 'GitHub bug report') 'Report a bug tooltip'
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:Tips.GetToolTip($script:VersionLabel))) 'Version tooltip was missing'
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:Tips.GetToolTip($script:CheckUpdateButton))) 'Check for updates tooltip was missing'
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:Tips.GetToolTip($script:UpdateButton))) 'Update tooltip was missing'
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:Tips.GetToolTip($script:StatusLabel))) 'Status tooltip was missing'
    Assert-True ((Compare-AppVersion '1.0.0' '1.0.1') -eq -1) 'An older version compared as newer'
    Assert-True ((Compare-AppVersion 'v1.0.2' '1.0.2') -eq 0) 'A v prefix was treated as a different version'
    Assert-True ($null -eq (Compare-AppVersion 'clean-installer' '1.0.1')) 'A name was treated as a version'
    Assert-True ($script:TitleLabel.Right -le $script:CheckUpdateButton.Left) 'The title overlaps Check for updates'
    Assert-True ($script:UpdateButton.Right -le ($script:Header.ClientSize.Width - 8)) 'Update sits outside the header'
    Assert-True ($script:ReportBugButton.Right -le ($script:Header.ClientSize.Width - 8)) 'Report a bug sits outside the header'
    Assert-True ($script:DonateButton.Right -le ($script:ReportBugButton.Left + 1)) 'Donate overlaps Report a bug'
    Assert-True ($script:DonateButton.Top -ge $script:UpdateButton.Bottom) 'Donate overlaps the update buttons'
    Assert-True ($script:TitleLabel.Right -le $script:DonateButton.Left) 'The title overlaps Donate'
    Assert-True ($script:VersionLabel.Right -le ($script:StatusPanel.ClientSize.Width - 8)) 'Version sits outside the status bar'
    Assert-True ($script:StatusLabel.Right -le ($script:VersionLabel.Left + 1)) 'Status overlaps the version'
    $greyUpdate = Resolve-HoverTip $script:Header (New-Object Drawing.Point(($script:UpdateButton.Left + 10), ($script:UpdateButton.Top + 10)))
    Assert-True ($null -ne $greyUpdate -and $greyUpdate.Control -eq $script:UpdateButton) 'grey Update is hoverable'
    Assert-True ($script:MonthsLabel.Text -eq 'Flag after not used for: (suspects)') 'unused label'
    Assert-True ($script:Tips.GetToolTip($script:MonthsLabel) -match 'Suspects') 'unused label tip'
    Assert-True ($script:MonthsBox.Left -ge ($script:MonthsLabel.Right + 8)) 'months dropdown overlaps the label'
    $mainButtons = @(
        $script:ViewSearch, $script:ViewInstalled, $script:ViewUpdates, $script:ViewSuspects,
        $script:SearchButton, $script:RefreshButton, $script:UpgradeAllButton, $script:SourceButton,
        $script:InstallButton, $script:UpgradeButton, $script:UninstallButton,
        $script:LeftoverButton, $script:DetailsButton, $script:CancelButton, $script:HelpButton
    )
    foreach ($btn in $mainButtons) {
        Assert-True (-not [string]::IsNullOrWhiteSpace($script:Tips.GetToolTip($btn))) ("missing tip on " + $btn.Text)
    }
    Assert-True (-not $script:InstallButton.Enabled) 'install starts grey'
    $greyInstall = Resolve-HoverTip $script:ActionPanel (New-Object Drawing.Point(($script:InstallButton.Left + 10), ($script:InstallButton.Top + 10)))
    Assert-True ($null -ne $greyInstall -and $greyInstall.Control -eq $script:InstallButton) 'grey install is hoverable'
    Assert-True ($greyInstall.Text -eq $script:Tips.GetToolTip($script:InstallButton)) 'grey install tip'
    $enabledHelp = Resolve-HoverTip $script:ActionPanel (New-Object Drawing.Point(($script:HelpButton.Left + 10), ($script:HelpButton.Top + 10)))
    Assert-True ($null -eq $enabledHelp) 'enabled help uses its own tip'
    Assert-True ($script:InstallButton.Text -eq 'Install') 'install button'
    Assert-True ($script:UninstallButton.Text -eq 'Uninstall') 'uninstall button'
    Assert-True ($null -ne $script:Log) 'activity log'
    Assert-True ($script:HelpButton.Parent -eq $script:ActionPanel) 'help button'
    Show-Help
    [Windows.Forms.Application]::DoEvents()
    Assert-True ($script:HelpText -match 'Recycle Bin') 'guide leftovers'
    Assert-True ($script:HelpText -match 'winget') 'guide winget'
    Assert-True ($script:HelpText -match 'Suspects') 'guide suspects'
    Assert-True ($script:HelpText -match 'FFmpeg' -and $script:HelpText -match 'background') 'guide dependency limit'
    Assert-True ($script:HelpText -match 'Auto-accept') 'guide auto accept'
    Assert-True ($script:HelpText -match 'Update catalog') 'guide catalog'
    Assert-True ($script:HelpText -match 'Check for updates looks again') 'guide update check'
    Assert-True ($script:HelpText -match 'Report a bug opens a GitHub page') 'guide bug report'
    Assert-True ($script:SourceButton.Text -eq 'Update catalog') 'catalog button'
    $bugUrl = Get-BugReportUrl
    Assert-True ($bugUrl.StartsWith('https://github.com/philipvern-dot/clean-installer/issues/new?')) 'bug report url'
    Assert-True ($bugUrl -match 'version=1\.0\.0') 'bug report version'
    Save-FormImage $script:Form (Join-Path $env:TEMP 'ci-main.png')
    Save-FormImage $script:HelpForm (Join-Path $env:TEMP 'ci-help.png')

    $catalog = [pscustomobject]@{ Name = '7-Zip'; Id = '7zip.7zip'; Version = '26.03'; Available = ''; Source = 'winget'; Match = 'Moniker: 7zip'; Note = ''; IsCatalog = $true }
    $arp = [pscustomobject]@{ Name = 'Old Inventory'; Id = 'ARP\Machine\X64\Old Inventory'; Version = '1.0'; Available = ''; Source = ''; Match = ''; Note = ''; IsCatalog = $false }
    Show-PackageRows @($catalog, $arp) 'search'
    $script:Files.Items[0].Selected = $true
    Update-Actions
    Assert-True ($script:InstallButton.Enabled) 'catalog install should be enabled'
    $script:Files.Items[1].Selected = $true
    Update-Actions
    Assert-True (-not $script:InstallButton.Enabled) 'inventory install should be disabled'
    Assert-True ($script:UninstallButton.Enabled) 'inventory uninstall'

    $leftA = New-Leftover 'registry' 'HKCU\SOFTWARE\ExampleApp' 'exact name match (Example)' 'HKCU' 'SOFTWARE\ExampleApp' ''
    $leftA.Selected = $true
    $leftB = New-Leftover 'directory' 'C:\Program Files\ExampleApp' 'InstallLocation from registry' '' '' 'C:\Program Files\ExampleApp'
    $dialog = Show-LeftoverForm $catalog @($leftA, $leftB) $false
    [Windows.Forms.Application]::DoEvents()
    $dialog.Tag.List.SelectedIndex = 0
    [Windows.Forms.Application]::DoEvents()
    Assert-True ($dialog.Tag.Reason.Text.Length -gt 0) 'leftover reason'
    Assert-True ($script:Tips.GetToolTip($dialog.Tag.Remove) -match 'Recycle Bin') 'leftover remove tip'
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:Tips.GetToolTip($dialog.Tag.Close))) 'leftover close tip'
    $dialog.ClientSize = New-Object Drawing.Size(700, 480)
    [Windows.Forms.Application]::DoEvents()
    Assert-True ($dialog.Tag.Close.Right -le ($dialog.ClientSize.Width + 2)) 'leftover close button'
    Save-FormImage $dialog (Join-Path $env:TEMP 'ci-leftovers.png')
    $dialog.Close()

    $detailsForm = Open-Details $catalog @{} 'Catalog package used by the smoke test.'
    $detailsForm.Show($script:Form)
    [Windows.Forms.Application]::DoEvents()
    Assert-True ($detailsForm.Tag.Title.Text -eq '7-Zip') 'details title'
    Assert-True (-not $detailsForm.Tag.Home.Enabled) 'homepage starts grey'
    Assert-True ($script:Tips.GetToolTip($detailsForm.Tag.Home) -match 'homepage') 'homepage tip'
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:Tips.GetToolTip($detailsForm.Tag.Web))) 'web search tip'
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:Tips.GetToolTip($detailsForm.Tag.Close))) 'details close tip'
    $greyHome = Resolve-HoverTip $detailsForm (New-Object Drawing.Point(($detailsForm.Tag.Home.Left + 10), ($detailsForm.Tag.Home.Top + 10)))
    Assert-True ($null -ne $greyHome -and $greyHome.Control -eq $detailsForm.Tag.Home) 'grey homepage is hoverable'
    Assert-True ($detailsForm.Tag.Close.Right -le ($detailsForm.ClientSize.Width + 2)) 'details close button'
    Save-FormImage $detailsForm (Join-Path $env:TEMP 'ci-details.png')
    $detailsForm.Close()

    $wide = $script:Form.ClientSize.Width
    $script:Form.ClientSize = New-Object Drawing.Size(980, 760)
    Update-ChromeLayout
    [Windows.Forms.Application]::DoEvents()
    Assert-True ($script:HelpButton.Right -le ($script:ActionPanel.ClientSize.Width + 2)) 'help button overflows'
    Assert-True ($script:CancelButton.Right -le $script:HelpButton.Left) 'actions overlap help'
    Assert-True ($script:ViewSuspects.Right -le $script:ViewRow.ClientSize.Width) 'view buttons overflow'
    Assert-True ($script:TitleLabel.Right -le $script:CheckUpdateButton.Left) 'The title overlaps Check for updates in the narrow window'
    Assert-True ($script:UpdateButton.Right -le ($script:Header.ClientSize.Width - 8)) 'Update sits outside the narrow window'
    Assert-True ($script:ReportBugButton.Right -le ($script:Header.ClientSize.Width - 8)) 'Report a bug sits outside the narrow window'
    Assert-True ($script:DonateButton.Right -le ($script:ReportBugButton.Left + 1)) 'Donate overlaps Report a bug in the narrow window'
    Assert-True ($script:VersionLabel.Right -le ($script:StatusPanel.ClientSize.Width - 8)) 'Version sits outside the narrow status bar'
    Assert-True ($script:StatusLabel.Right -le ($script:VersionLabel.Left + 1)) 'Status overlaps the version in the narrow window'
    Save-FormImage $script:Form (Join-Path $env:TEMP 'ci-narrow.png')
    $script:Form.ClientSize = New-Object Drawing.Size($wide, $script:Form.ClientSize.Height)

    $release = [pscustomobject]@{
        tag_name = 'v1.0.1'
        assets = @([pscustomobject]@{
            name = 'clean_installer.exe'
            browser_download_url = 'https://github.com/philipvern-dot/clean-installer/releases/download/v1.0.1/clean_installer.exe'
            size = 1200
        })
    }
    Apply-UpdateOffer (Get-UpdateOffer $release)
    Assert-True ($script:UpdateButton.Enabled) 'Update stayed disabled after a newer release'
    Assert-True ($script:StatusLabel.Text -eq 'Version 1.0.1 is available.') 'Update status did not name the version'
    $script:Busy = $true
    Update-UpdateButtons
    Assert-True ((-not $script:CheckUpdateButton.Enabled) -and (-not $script:UpdateButton.Enabled)) 'Update buttons stayed enabled during a job'
    $script:Busy = $false
    Update-UpdateButtons
    Assert-True ($script:CheckUpdateButton.Enabled -and $script:UpdateButton.Enabled) 'Update buttons did not return after the job'
    $same = Get-UpdateOffer ([pscustomobject]@{
        tag_name = 'v1.0.0'
        assets = @([pscustomobject]@{
            name = 'clean_installer.exe'
            browser_download_url = 'https://github.com/philipvern-dot/clean-installer/releases/download/v1.0.0/clean_installer.exe'
            size = 1200
        })
    })
    Assert-True (-not $same.Newer) 'The current version was treated as newer'
    Assert-True ($same.Message -match 'latest version') 'Latest version message was missing'
    $script:UpdateOffer = $null
    Update-UpdateButtons
    Assert-True (-not $script:UpdateButton.Enabled) 'Update stayed enabled with no offer'

    if ($script:HelpForm) { $script:HelpForm.Close() }
    $script:Form.Close()
    Write-Output 'SMOKE OK'
}

function Get-AppIconPath {
    $path = Join-Path $script:Root 'ci-icon.ico'
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

function Get-AppIcon {
    try {
        $path = Get-AppIconPath
        if (-not $path) { return $null }
        return New-Object Drawing.Icon $path
    } catch {
        return $null
    }
}

function Test-UpdateBusy {
    return [bool]$script:Busy
}

function Remove-VersionPrefix([string]$text) {
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    $clean = $text.Trim()
    if (($clean.StartsWith('v') -or $clean.StartsWith('V')) -and $clean.Length -gt 1) {
        $rest = $clean.Substring(1)
        if ($rest -match '^\d+\.\d+\.\d+$') { return $rest }
    }
    return $clean
}

function ConvertTo-VersionNumbers([string]$text) {
    $clean = ''
    if ($null -ne $text) { $clean = $text.Trim() }
    if ($clean -match '^(\d+)\.(\d+)\.(\d+)$') {
        $numbers = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
        return ,$numbers
    }
    return $null
}

function Compare-AppVersion([string]$left, [string]$right) {
    $a = ConvertTo-VersionNumbers (Remove-VersionPrefix $left)
    $b = ConvertTo-VersionNumbers (Remove-VersionPrefix $right)
    if ($null -eq $a -or $null -eq $b) { return $null }
    for ($i = 0; $i -lt 3; $i++) {
        if ($a[$i] -gt $b[$i]) { return 1 }
        if ($a[$i] -lt $b[$i]) { return -1 }
    }
    return 0
}

function Get-AppVersion {
    $path = Join-Path $script:AppDir 'version.txt'
    if (Test-Path -LiteralPath $path) {
        $text = ''
        try { $text = [IO.File]::ReadAllText($path).Trim() } catch { $text = '' }
        if ($text -match '^\d+\.\d+\.\d+$') { return $text }
    }
    return [string]$script:UpdateFallback
}

function Test-InstalledCopy {
    $programs = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs'))
    if (-not $programs.EndsWith('\')) { $programs = $programs + '\' }
    $root = [IO.Path]::GetFullPath($script:Root)
    if (-not $root.EndsWith('\')) { $root = $root + '\' }
    return $root.StartsWith($programs, [StringComparison]::OrdinalIgnoreCase)
}

function Get-WindowsLabel {
    $build = 0
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        [void][int]::TryParse([string]$cv.CurrentBuild, [ref]$build)
    } catch { }
    $name = 'Windows'
    if ($build -ge 22000) { $name = 'Windows 11' }
    elseif ($build -ge 10240) { $name = 'Windows 10' }
    if ($build -gt 0) { return "$name (build $build)" }
    return $name
}

function Get-LatestActivityText {
    param([int]$MaxEncoded = 4500)
    if ($null -eq $script:Log) { return '' }
    $raw = [string]$script:Log.Text
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($raw -split '\r?\n')) {
        if ($line -ne '') { [void]$lines.Add($line) }
    }
    if ($lines.Count -eq 0) { return '' }
    $kept = New-Object System.Collections.Generic.List[string]
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $candidate = New-Object System.Collections.Generic.List[string]
        [void]$candidate.Add([string]$lines[$i])
        foreach ($older in $kept) { [void]$candidate.Add([string]$older) }
        $text = [string]::Join("`n", $candidate.ToArray())
        if (([uri]::EscapeDataString($text)).Length -le $MaxEncoded) {
            $kept.Insert(0, [string]$lines[$i])
            continue
        }
        if ($kept.Count -eq 0) {
            $line = [string]$lines[$i]
            $low = 0
            $high = $line.Length
            while ($low -lt $high) {
                $mid = [int](($low + $high + 1) / 2)
                $slice = $line.Substring($line.Length - $mid)
                if (([uri]::EscapeDataString($slice)).Length -le $MaxEncoded) { $low = $mid } else { $high = $mid - 1 }
            }
            if ($low -gt 0) { return $line.Substring($line.Length - $low) }
        }
        break
    }
    if ($kept.Count -eq 0) { return '' }
    return [string]::Join("`n", $kept.ToArray())
}

function Get-BugReportUrl {
    param([string]$Activity = '')
    $version = [uri]::EscapeDataString((Get-AppVersion))
    $windows = [uri]::EscapeDataString((Get-WindowsLabel))
    $url = "https://github.com/philipvern-dot/clean-installer/issues/new?template=bug_report.yml&version=$version&windows=$windows"
    if (-not [string]::IsNullOrWhiteSpace($Activity)) {
        $url = $url + '&activity=' + [uri]::EscapeDataString($Activity)
    }
    return $url
}

function Open-HttpLink([string]$Url) {
    $allowed = $false
    if ($Url -eq 'https://ko-fi.com/philipvern') { $allowed = $true }
    elseif ($Url.StartsWith('https://github.com/philipvern-dot/clean-installer/issues/new?')) { $allowed = $true }
    if (-not $allowed) { return }
    Start-Process $Url
}

function Show-BugReport {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Clean Installer'
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = 'CenterParent'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ShowInTaskbar = $false
    $form.ClientSize = New-Object Drawing.Size(520, 262)
    $form.Font = $script:FontUi
    $form.BackColor = [Drawing.Color]::White
    $icon = Get-AppIcon
    if ($icon) { $form.Icon = $icon }
    $label = New-Object Windows.Forms.Label
    $label.Font = $script:FontUi
    $label.ForeColor = $script:ColorInk
    $label.BackColor = [Drawing.Color]::White
    $label.SetBounds(24, 16, 472, 128)
    $label.Text = "Report a bug opens a GitHub page. This version and the Windows version are filled in. Nothing else is added unless you check the box.`r`n`r`nInclude latest activity adds the latest lines from the activity box to that page. Those lines can include folder paths. This program does not send the report. You submit it on the GitHub page."
    $include = New-Check 'Include latest activity'
    $include.Checked = $false
    $include.Enabled = -not [string]::IsNullOrWhiteSpace((Get-LatestActivityText))
    $include.SetBounds(24, 156, 280, 24)
    $open = New-Button 'Open report' 'primary' 140 34
    $cancel = New-Button 'Cancel' 'secondary' 110 34
    $open.SetBounds(238, 204, 140, 34)
    $cancel.SetBounds(386, 204, 110, 34)
    Set-Tip $open 'Open the GitHub page with this version filled in.'
    Set-Tip $cancel 'Close this window without opening GitHub.'
    $form.Controls.Add($label)
    $form.Controls.Add($include)
    $form.Controls.Add($open)
    $form.Controls.Add($cancel)
    $state = [pscustomobject]@{ Open = $false; Include = $false }
    $open.DialogResult = [Windows.Forms.DialogResult]::OK
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.AcceptButton = $open
    $form.CancelButton = $cancel
    $open.Add_Click({ $state.Open = $true; $state.Include = [bool]$include.Checked }.GetNewClosure())
    try { [void]$form.ShowDialog($script:Form) }
    finally { $form.Dispose() }
    if (-not $state.Open) { return }
    $activity = ''
    if ($state.Include) { $activity = Get-LatestActivityText }
    Open-HttpLink (Get-BugReportUrl $activity)
}

function Update-UpdateButtons {
    $busy = Test-UpdateBusy
    if ($script:CheckUpdateButton) { $script:CheckUpdateButton.Enabled = -not $busy }
    if ($script:UpdateButton) {
        $ready = (-not $busy) -and ($null -ne $script:UpdateOffer) -and [bool]$script:UpdateOffer.Newer
        $script:UpdateButton.Enabled = $ready
    }
}

function Get-UpdateOffer($release) {
    $remote = Remove-VersionPrefix ([string]$release.tag_name)
    $cmp = Compare-AppVersion $remote (Get-AppVersion)
    $asset = $null
    foreach ($item in @($release.assets)) {
        if ($null -eq $item) { continue }
        if ([string]$item.name -eq $script:UpdateAsset) { $asset = $item; break }
    }
    $result = [pscustomobject]@{
        Newer = $false
        Version = $remote
        Url = ''
        Size = [int64]0
        Message = ''
        Kind = 'idle'
    }
    if ($null -eq $cmp) {
        $result.Message = 'The latest release has no version number.'
        $result.Kind = 'err'
        return $result
    }
    $url = ''
    $size = [int64]0
    if ($null -ne $asset) {
        $url = [string]$asset.browser_download_url
        try { $size = [int64]$asset.size } catch { $size = 0 }
    }
    if ([string]::IsNullOrWhiteSpace($url) -or $size -le 0 -or $url -notmatch '^https://github\.com/philipvern-dot/clean-installer/') {
        $result.Message = 'The latest release does not include the setup program.'
        $result.Kind = 'err'
        return $result
    }
    if ($cmp -le 0) {
        $result.Message = 'You have the latest version (' + (Get-AppVersion) + ').'
        $result.Kind = 'ok'
        return $result
    }
    $result.Newer = $true
    $result.Url = $url
    $result.Size = $size
    $result.Message = 'Version ' + $remote + ' is available.'
    $result.Kind = 'ok'
    return $result
}

function Test-UpdatePromptDue($offer) {
    if ($null -eq $offer -or -not $offer.Newer) { return $false }
    return ([string]$script:UpdatePrompt -ne [string]$offer.Version)
}

function Remember-UpdatePrompt([string]$version) {
    $script:UpdatePrompt = [string]$version
    Save-Settings
}

function Show-UpdateReady($offer) {
    if ($script:SmokeTest -or -not (Test-UpdatePromptDue $offer)) { return }
    [Windows.Forms.MessageBox]::Show($script:Form, "Version $($offer.Version) is available.`r`n`r`nClick Update to install it.", 'Clean Installer', 'OK', 'Information') | Out-Null
    Remember-UpdatePrompt $offer.Version
}

function Apply-UpdateOffer($offer) {
    if ($offer.Newer) { $script:UpdateOffer = $offer } else { $script:UpdateOffer = $null }
    Update-UpdateButtons
    Set-Status $offer.Message $offer.Kind
    $kind = 'dim'
    if ($offer.Kind -eq 'err') { $kind = 'err' }
    elseif ($offer.Newer) { $kind = 'ok' }
    Write-Activity $offer.Message $kind
    if ($offer.Newer) { Show-UpdateReady $offer }
}

function Start-UpdateCheck {
    param([switch]$Automatic)
    if (Test-UpdateBusy) {
        if ($Automatic) {
            $script:UpdateCheckQueued = $true
            return
        }
        [Windows.Forms.MessageBox]::Show($script:Form, 'Finish or cancel the current job before checking for updates.', $script:UpdateProduct, 'OK', 'Information') | Out-Null
        return
    }
    $script:UpdateOffer = $null
    Update-UpdateButtons
    Set-Status 'Checking for updates...' 'busy'
    $script:Form.Cursor = [Windows.Forms.Cursors]::WaitCursor
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $url = 'https://api.github.com/repos/philipvern-dot/' + $script:UpdateRepo + '/releases/latest'
        $headers = @{ 'User-Agent' = $script:UpdateProduct; 'Accept' = 'application/vnd.github+json' }
        $release = Invoke-RestMethod -Uri $url -Headers $headers -Method Get
        Apply-UpdateOffer (Get-UpdateOffer $release)
    } catch {
        $script:UpdateOffer = $null
        Update-UpdateButtons
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($status -eq 404) { $message = 'No published update was found.' }
        else { $message = 'Could not reach GitHub to check for updates.' }
        Set-Status $message 'err'
        Write-Activity $message 'err'
    } finally {
        $script:Form.Cursor = [Windows.Forms.Cursors]::Default
    }
}

function Receive-SetupFile([string]$url, [string]$dest, [int64]$expected) {
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object Net.WebClient
    $client.Headers['User-Agent'] = $script:UpdateProduct
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Update'
    $dialog.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.StartPosition = [Windows.Forms.FormStartPosition]::CenterParent
    $dialog.ClientSize = New-Object Drawing.Size(420, 128)
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ControlBox = $false
    $dialog.Font = $script:FontUi
    $label = New-Object Windows.Forms.Label
    $label.Text = 'Downloading the update...'
    $label.SetBounds(20, 18, 380, 24)
    $bar = New-Object Windows.Forms.ProgressBar
    $bar.SetBounds(20, 50, 380, 22)
    $bar.Minimum = 0
    $bar.Maximum = 100
    $cancel = New-Button 'Cancel' 'secondary' 100 32
    $cancel.SetBounds(300, 82, 100, 32)
    $dialog.Controls.Add($label)
    $dialog.Controls.Add($bar)
    $dialog.Controls.Add($cancel)
    $state = New-Object psobject -Property @{ Done = $false; Error = $null; Cancelled = $false }
    $client.add_DownloadProgressChanged({
        try {
            $pct = [int]$args[1].ProgressPercentage
            if ($pct -lt 0) { $pct = 0 }
            if ($pct -gt 100) { $pct = 100 }
            $bar.Value = $pct
            $label.Text = 'Downloading the update... ' + $pct + '%'
        } catch { }
    })
    $client.add_DownloadFileCompleted({
        $state.Done = $true
        if ($args[1].Cancelled) { $state.Cancelled = $true }
        elseif ($args[1].Error) { $state.Error = $args[1].Error }
        try { if (-not $dialog.IsDisposed) { $dialog.Close() } } catch { }
    })
    $cancel.Add_Click({
        $state.Cancelled = $true
        try { $client.CancelAsync() } catch { }
    })
    $dialog.Add_Shown({
        try { $client.DownloadFileAsync([Uri]$url, $dest) }
        catch {
            $state.Done = $true
            $state.Error = $_.Exception
            try { $dialog.Close() } catch { }
        }
    })
    [void]$dialog.ShowDialog($script:Form)
    $client.Dispose()
    if ($state.Cancelled) {
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
        Set-Status 'Update cancelled.' 'idle'
        Write-Activity 'Update cancelled.' 'dim'
        return $false
    }
    if ($state.Error -or -not (Test-Path -LiteralPath $dest)) {
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue }
        Set-Status 'The download did not finish.' 'err'
        Write-Activity 'The download did not finish.' 'err'
        return $false
    }
    $got = [int64](Get-Item -LiteralPath $dest).Length
    if ($expected -gt 0 -and $got -ne $expected) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        Set-Status 'The download did not match the size published on GitHub.' 'err'
        Write-Activity ('The download was ' + $got + ' bytes. GitHub published ' + $expected + ' bytes.') 'err'
        return $false
    }
    return $true
}

function Start-UpdateInstall {
    if (Test-UpdateBusy) {
        [Windows.Forms.MessageBox]::Show($script:Form, 'Finish or cancel the current job before updating.', $script:UpdateProduct, 'OK', 'Information') | Out-Null
        return
    }
    $offer = $script:UpdateOffer
    if ($null -eq $offer -or -not $offer.Newer) { return }
    $prompt = 'Version ' + $offer.Version + ' is ready to install. This window will close and the setup program will open.'
    if (-not (Test-InstalledCopy)) {
        $prompt = 'Version ' + $offer.Version + ' is ready to install. This folder was not installed by the setup program, so the setup installs the new version for this Windows user and leaves this folder as it is. This window will close.'
    }
    $answer = [Windows.Forms.MessageBox]::Show($script:Form, $prompt, $script:UpdateProduct, 'OKCancel', 'Question')
    if ($answer -ne [Windows.Forms.DialogResult]::OK) { return }
    $dest = Join-Path $env:TEMP ($script:UpdateAsset.Replace('.exe', '') + '-' + $offer.Version + '.exe')
    if (-not (Receive-SetupFile $offer.Url $dest $offer.Size)) { return }
    Start-Process -FilePath $dest | Out-Null
    $script:UpdateClosing = $true
    $script:Form.Close()
}

$settings = Load-Settings
$script:AutoAccept = [bool]$settings.AutoAccept
$script:Detailed = [bool]$settings.Detailed
$script:UnusedMonths = [int]$settings.UnusedMonths
$script:UpdatePrompt = [string]$settings.UpdatePrompt

$script:Form = New-Object Windows.Forms.Form
$script:Form.Text = 'Clean Installer'
$script:Form.Font = $script:FontUi
$script:Form.BackColor = $script:ColorPage
$script:Form.StartPosition = 'CenterScreen'
$script:Form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::None
$script:Form.KeyPreview = $true
$area = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$wantW = 1100
$wantH = 900
if ($wantW -gt ($area.Width - 24)) { $wantW = [Math]::Max(780, $area.Width - 24) }
if ($wantH -gt ($area.Height - 24)) { $wantH = [Math]::Max(640, $area.Height - 24) }
$script:Form.ClientSize = New-Object Drawing.Size($wantW, $wantH)
$script:Form.MinimumSize = New-Object Drawing.Size([Math]::Min(1000, $area.Width), [Math]::Min(780, $area.Height))
$appIcon = Get-AppIcon
if ($appIcon) { $script:Form.Icon = $appIcon }
else {
    try { $script:Form.Icon = [CleanInstaller.ShellIcon]::Load((Join-Path $env:SystemRoot 'System32\imageres.dll'), 189) } catch { }
}
Enable-DoubleBuffer $script:Form

$script:Header = New-Object Windows.Forms.Panel
$script:Header.Dock = 'Top'
$script:Header.Height = 112
$script:Header.BackColor = $script:ColorHeader
$script:TitleLabel = New-Object Windows.Forms.Label
$script:TitleLabel.Text = 'Clean Installer'
$script:TitleLabel.Font = $script:FontTitle
$script:TitleLabel.ForeColor = [Drawing.Color]::White
$script:TitleLabel.BackColor = $script:ColorHeader
$script:SubtitleLabel = New-Object Windows.Forms.Label
$script:SubtitleLabel.Text = 'Install and uninstall programs with winget. Leftovers stay until you choose them.'
$script:SubtitleLabel.Font = $script:FontSubtitle
$script:SubtitleLabel.ForeColor = $script:ColorHeaderMuted
$script:SubtitleLabel.BackColor = $script:ColorHeader
$script:Header.Controls.Add($script:TitleLabel)
$script:Header.Controls.Add($script:SubtitleLabel)
$script:CheckUpdateButton = New-Button 'Check for updates' 'secondary' 168 34
$script:UpdateButton = New-Button 'Update' 'primary' 100 34
$script:UpdateButton.Enabled = $false
$script:DonateButton = New-Button 'Donate' 'secondary' 96 28
$script:ReportBugButton = New-Button 'Report a bug' 'secondary' 132 28
$script:Header.Controls.Add($script:CheckUpdateButton)
$script:Header.Controls.Add($script:UpdateButton)
$script:Header.Controls.Add($script:DonateButton)
$script:Header.Controls.Add($script:ReportBugButton)

$script:StatusPanel = New-Object Windows.Forms.Panel
$script:StatusPanel.Dock = 'Bottom'
$script:StatusPanel.Height = 58
$script:StatusPanel.BackColor = [Drawing.Color]::White
$script:StatusLabel = New-Object Windows.Forms.Label
$script:StatusLabel.Text = 'Ready'
$script:StatusLabel.Font = $script:FontUi
$script:StatusLabel.ForeColor = $script:ColorMuted
$script:StatusLabel.AutoEllipsis = $true
$script:StatusLabel.BackColor = [Drawing.Color]::White
$script:VersionLabel = New-Object Windows.Forms.Label
$script:VersionLabel.Text = Get-AppVersion
$script:VersionLabel.Font = $script:FontHint
$script:VersionLabel.ForeColor = $script:ColorMuted
$script:VersionLabel.BackColor = [Drawing.Color]::White
$script:VersionLabel.TextAlign = 'MiddleRight'
$script:VersionLabel.AutoSize = $true
$script:ProgressTrack = New-Object Windows.Forms.Panel
$script:ProgressTrack.BackColor = [Drawing.Color]::FromArgb(229, 231, 235)
$script:ProgressTrack.Height = 8
$script:ProgressFill = New-Object Windows.Forms.Panel
$script:ProgressFill.BackColor = $script:ColorPrimary
$script:ProgressFill.Height = 8
$script:ProgressFill.Width = 0
$script:ProgressTrack.Controls.Add($script:ProgressFill)
$script:StatusPanel.Controls.Add($script:StatusLabel)
$script:StatusPanel.Controls.Add($script:VersionLabel)
$script:StatusPanel.Controls.Add($script:ProgressTrack)
$script:StatusPanel.Add_Paint({
    $pen = New-Object Drawing.Pen $script:ColorLine
    $_.Graphics.DrawLine($pen, 0, 0, $script:StatusPanel.Width, 0)
    $pen.Dispose()
})

$table = New-Object Windows.Forms.TableLayoutPanel
$table.Dock = 'Fill'
$table.BackColor = $script:ColorPage
$table.ColumnCount = 1
$table.RowCount = 8
$table.Padding = New-Object Windows.Forms.Padding(24, 12, 24, 8)
$table.Margin = New-Object Windows.Forms.Padding(0)
[void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent, 100)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 46)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 46)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 62)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 40)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 150)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 56)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute, 28)))
[void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent, 38)))

$script:ViewRow = New-Object Windows.Forms.Panel
$script:ViewRow.Dock = 'Fill'
$script:ViewRow.BackColor = $script:ColorPage
$script:ViewSearch = New-Button 'Search' 'primary' 120 34
$script:ViewInstalled = New-Button 'Installed' 'secondary' 132 34
$script:ViewUpdates = New-Button 'Updates' 'secondary' 120 34
$script:ViewSuspects = New-Button 'Suspects' 'secondary' 120 34
$script:SourceButton = New-Button 'Update catalog' 'secondary' 156 34
$script:ViewRow.Controls.AddRange(@($script:ViewSearch, $script:ViewInstalled, $script:ViewUpdates, $script:ViewSuspects, $script:SourceButton))

$script:QueryPanel = New-Object Windows.Forms.Panel
$script:QueryPanel.Dock = 'Fill'
$script:QueryPanel.BackColor = $script:ColorPage
$script:SearchHost = New-Object Windows.Forms.Panel
$script:SearchHost.BackColor = [Drawing.Color]::White
$script:SearchHost.Height = 36
$script:SearchBox = New-Object Windows.Forms.TextBox
$script:SearchBox.BorderStyle = 'None'
$script:SearchBox.Font = $script:FontUi
$script:SearchBox.Dock = 'Fill'
$script:SearchHost.Padding = New-Object Windows.Forms.Padding(8, 8, 8, 4)
$script:SearchHost.Controls.Add($script:SearchBox)
$script:SearchHost.Add_Paint({
    $pen = New-Object Drawing.Pen $script:ColorLine
    $_.Graphics.DrawRectangle($pen, 0, 0, ($script:SearchHost.Width - 1), ($script:SearchHost.Height - 1))
    $pen.Dispose()
})
$script:SearchButton = New-Button 'Search' 'primary' 112 34
$script:RefreshButton = New-Button 'Refresh' 'secondary' 112 34
$script:UpgradeAllButton = New-Button 'Upgrade all' 'secondary' 128 34
$script:ViewHint = New-Object Windows.Forms.Label
$script:ViewHint.Font = $script:FontUi
$script:ViewHint.ForeColor = $script:ColorMuted
$script:ViewHint.BackColor = $script:ColorPage
$script:ViewHint.AutoEllipsis = $true
$script:QueryPanel.Controls.AddRange(@($script:SearchHost, $script:SearchButton, $script:RefreshButton, $script:UpgradeAllButton, $script:ViewHint))

$listHost = New-Object Windows.Forms.Panel
$listHost.Dock = 'Fill'
$listHost.BackColor = [Drawing.Color]::White
$listHost.Padding = New-Object Windows.Forms.Padding(1)
$listHost.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 0)
$script:Files = New-Object Windows.Forms.ListView
$script:Files.Dock = 'Fill'
$script:Files.View = 'Details'
$script:Files.FullRowSelect = $true
$script:Files.GridLines = $false
$script:Files.MultiSelect = $false
$script:Files.HideSelection = $false
$script:Files.BorderStyle = 'None'
$script:Files.Font = $script:FontUi
$script:Files.BackColor = [Drawing.Color]::White
$script:Files.ForeColor = $script:ColorInk
$listHost.Controls.Add($script:Files)
$listHost.Add_Paint({
    $pen = New-Object Drawing.Pen $script:ColorLine
    $_.Graphics.DrawRectangle($pen, 0, 0, ($this.Width - 1), ($this.Height - 1))
    $pen.Dispose()
})
Enable-DoubleBuffer $script:Files

$script:HintLabel = New-Object Windows.Forms.Label
$script:HintLabel.Font = $script:FontHint
$script:HintLabel.ForeColor = $script:ColorMuted
$script:HintLabel.BackColor = $script:ColorPage
$script:HintLabel.Dock = 'Fill'
$script:HintLabel.TextAlign = 'MiddleLeft'

$script:OptionsCard = New-Object Windows.Forms.Panel
$script:OptionsCard.Dock = 'Fill'
$script:OptionsCard.BackColor = [Drawing.Color]::White
$script:OptionsCard.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 4)
$script:OptionsTitle = New-Object Windows.Forms.Label
$script:OptionsTitle.Text = 'Options'
$script:OptionsTitle.Font = $script:FontSection
$script:OptionsTitle.ForeColor = $script:ColorInk
$script:OptionsTitle.BackColor = [Drawing.Color]::White
$script:AutoAcceptCheck = New-Check 'Auto-accept agreements and install quietly'
$script:DetailedCheck = New-Check 'Show detailed activity'
$script:AutoAcceptCheck.Checked = $script:AutoAccept
$script:DetailedCheck.Checked = $script:Detailed
$script:MonthsLabel = New-Object Windows.Forms.Label
$script:MonthsLabel.Text = 'Flag after not used for: (suspects)'
$script:MonthsLabel.AutoSize = $true
$script:MonthsLabel.Font = $script:FontUi
$script:MonthsLabel.ForeColor = $script:ColorInk
$script:MonthsLabel.BackColor = [Drawing.Color]::White
$script:MonthsBox = New-Object Windows.Forms.ComboBox
$script:MonthsBox.DropDownStyle = 'DropDownList'
$script:MonthsBox.Font = $script:FontUi
$script:MonthsBox.Width = 140
$script:MonthValues = @(1, 3, 6, 12, 24, 36)
foreach ($month in $script:MonthValues) {
    $word = 'months'
    if ($month -eq 1) { $word = 'month' }
    [void]$script:MonthsBox.Items.Add("$month $word")
}
$monthIndex = [array]::IndexOf($script:MonthValues, $script:UnusedMonths)
if ($monthIndex -lt 0) { $monthIndex = 2 }
$script:MonthsBox.SelectedIndex = $monthIndex
$script:OptionsCard.Controls.AddRange(@($script:OptionsTitle, $script:AutoAcceptCheck, $script:DetailedCheck, $script:MonthsLabel, $script:MonthsBox))
$script:OptionsCard.Add_Paint({
    $pen = New-Object Drawing.Pen $script:ColorLine
    $_.Graphics.DrawRectangle($pen, 0, 0, ($script:OptionsCard.Width - 1), ($script:OptionsCard.Height - 1))
    $pen.Dispose()
})

$script:ActionPanel = New-Object Windows.Forms.Panel
$script:ActionPanel.Dock = 'Fill'
$script:ActionPanel.BackColor = $script:ColorPage
$script:InstallButton = New-Button 'Install' 'primary' 108 38
$script:UpgradeButton = New-Button 'Upgrade' 'secondary' 108 34
$script:UninstallButton = New-Button 'Uninstall' 'danger' 118 34
$script:LeftoverButton = New-Button 'Scan leftovers' 'secondary' 146 34
$script:DetailsButton = New-Button 'Details' 'secondary' 96 34
$script:CancelButton = New-Button 'Cancel' 'danger' 96 34
$script:HelpButton = New-Button 'How this works' 'secondary' 148 34
$script:CancelButton.Enabled = $false
$script:ActionPanel.Controls.AddRange(@($script:InstallButton, $script:UpgradeButton, $script:UninstallButton, $script:LeftoverButton, $script:DetailsButton, $script:CancelButton, $script:HelpButton))

$activityLabel = New-Object Windows.Forms.Label
$activityLabel.Text = 'Activity'
$activityLabel.Font = $script:FontSection
$activityLabel.ForeColor = $script:ColorInk
$activityLabel.BackColor = $script:ColorPage
$activityLabel.Dock = 'Fill'
$activityLabel.TextAlign = 'BottomLeft'

$logHost = New-Object Windows.Forms.Panel
$logHost.Dock = 'Fill'
$logHost.BackColor = $script:ColorLogBg
$logHost.Padding = New-Object Windows.Forms.Padding(10, 8, 10, 8)
$logHost.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 0)
$script:Log = New-Object Windows.Forms.RichTextBox
$script:Log.Dock = 'Fill'
$script:Log.BorderStyle = 'None'
$script:Log.ReadOnly = $true
$script:Log.BackColor = $script:ColorLogBg
$script:Log.ForeColor = $script:ColorLogText
$script:Log.Font = $script:FontLog
$script:Log.DetectUrls = $false
$script:Log.ScrollBars = 'Vertical'
$script:Log.WordWrap = $true
$logHost.Controls.Add($script:Log)
$logHost.Add_Paint({
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(55, 65, 81))
    $_.Graphics.DrawRectangle($pen, 0, 0, ($this.Width - 1), ($this.Height - 1))
    $pen.Dispose()
})

[void]$table.Controls.Add($script:ViewRow, 0, 0)
[void]$table.Controls.Add($script:QueryPanel, 0, 1)
[void]$table.Controls.Add($listHost, 0, 2)
[void]$table.Controls.Add($script:HintLabel, 0, 3)
[void]$table.Controls.Add($script:OptionsCard, 0, 4)
[void]$table.Controls.Add($script:ActionPanel, 0, 5)
[void]$table.Controls.Add($activityLabel, 0, 6)
[void]$table.Controls.Add($logHost, 0, 7)
$script:Form.Controls.Add($table)
$script:Form.Controls.Add($script:StatusPanel)
$script:Form.Controls.Add($script:Header)

$script:Tips = New-Object Windows.Forms.ToolTip
$script:Tips.InitialDelay = 400
$script:Tips.ReshowDelay = 200
$script:Tips.AutoPopDelay = 20000
$script:Tips.ShowAlways = $true
$script:DisabledTips = New-Object Windows.Forms.ToolTip
$script:DisabledTips.ShowAlways = $true
$script:DisabledTipChild = $null
$script:DisabledTipParent = $null
$script:DisabledTipText = ''
$script:DisabledTipAt = [datetime]::MinValue
$script:DisabledTipShown = $null
Enable-DisabledButtonTips $script:ViewRow
Enable-DisabledButtonTips $script:QueryPanel
Enable-DisabledButtonTips $script:ActionPanel
Enable-DisabledButtonTips $script:Header
Set-Tip $script:ViewSearch 'Open the catalog search.'
Set-Tip $script:ViewInstalled 'Open the list of programs installed on this PC.'
Set-Tip $script:ViewUpdates 'Open packages that have a newer version.'
Set-Tip $script:ViewSuspects 'Open known problem software and programs with no recorded launches.'
Set-Tip $script:SourceButton 'Download the latest winget package list. Clean Installer also does this each time it opens.'
Set-Tip $script:SearchBox 'Type at least two characters, then Search. This looks in the winget catalog.'
Set-Tip $script:SearchButton 'Search the winget catalog.'
Set-Tip $script:RefreshButton 'Read this list from winget again.'
Set-Tip $script:UpgradeAllButton 'Upgrade every package winget can upgrade. Cancel is the default.'
Set-Tip $script:InstallButton 'Install the selected catalog package with winget install --id --exact.'
Set-Tip $script:UpgradeButton 'Upgrade the selected package.'
Set-Tip $script:UninstallButton 'Uninstall the selected program, then review leftovers. Nothing else is removed until you tick it.'
Set-Tip $script:LeftoverButton 'Look for leftover registry keys and folders without uninstalling. Steam libraries are skipped.'
Set-Tip $script:DetailsButton 'Show the summary, publisher, homepage, and a web search.'
Set-Tip $script:CancelButton 'Stop the current winget command.'
Set-Tip $script:HelpButton 'Open a short guide to search, uninstall, leftovers, and suspects.'
Set-Tip $script:CheckUpdateButton 'Look on GitHub for a newer version of Clean Installer.'
Set-Tip $script:DonateButton 'Free forever. Tips of $5 or more can include a feature suggestion.'
Set-Tip $script:ReportBugButton 'Open a GitHub bug report with this version and the Windows version filled in. Include latest activity is optional. Leave it unchecked and nothing else is added.'
Set-Tip $script:UpdateButton 'Download the newer version and open its setup program. This window closes while that setup runs.'
Set-Tip $script:StatusLabel 'What the program is doing right now.'
Set-Tip $script:VersionLabel 'This copy of Clean Installer.'
Set-Tip $script:AutoAcceptCheck 'When this is on, install and upgrade accept package agreements and run quietly. Uninstall runs quietly too.'
Set-Tip $script:DetailedCheck 'Show winget progress lines in the activity box.'
Set-Tip $script:MonthsLabel 'This only changes Suspects. A program is flagged when Windows has no recorded launch in the time you pick. Shared tools such as FFmpeg are left off, because background use is not recorded.'
Set-Tip $script:MonthsBox 'Suspects includes programs with no recorded launches in this many months.'
Set-Tip $script:Files 'Select one program. Double-click it for details.'
Set-Tip $script:Log 'Commands, results, and leftover decisions are listed here.'

$script:ViewSearch.Add_Click({ if (-not $script:Busy) { Set-View 'search' $false } })
$script:ViewInstalled.Add_Click({ if (-not $script:Busy) { Set-View 'installed' $true } })
$script:ViewUpdates.Add_Click({ if (-not $script:Busy) { Set-View 'updates' $true } })
$script:ViewSuspects.Add_Click({ if (-not $script:Busy) { Set-View 'suspects' $true } })
$script:SourceButton.Add_Click({ Start-SourceUpdate })
$script:SearchButton.Add_Click({ Start-Search })
$script:RefreshButton.Add_Click({ Start-ViewLoad $script:View })
$script:UpgradeAllButton.Add_Click({ Start-UpgradeAll })
$script:InstallButton.Add_Click({ Start-Install })
$script:UpgradeButton.Add_Click({ Start-Upgrade })
$script:UninstallButton.Add_Click({ Start-Uninstall })
$script:LeftoverButton.Add_Click({ Start-LeftoverScan })
$script:DetailsButton.Add_Click({ Start-Details })
$script:CancelButton.Add_Click({ Stop-CurrentJob })
$script:HelpButton.Add_Click({ Show-Help })
$script:CheckUpdateButton.Add_Click({ Start-UpdateCheck })
$script:DonateButton.Add_Click({ Open-HttpLink 'https://ko-fi.com/philipvern' })
$script:ReportBugButton.Add_Click({ Show-BugReport })
$script:UpdateButton.Add_Click({ Start-UpdateInstall })
$script:Files.Add_SelectedIndexChanged({ Update-Actions })
$script:Files.Add_DoubleClick({ Start-Details })
$script:SearchBox.Add_KeyDown({
    if ($_.KeyCode -eq [Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        Start-Search
    }
})
$script:AutoAcceptCheck.Add_CheckedChanged({
    $script:AutoAccept = [bool]$script:AutoAcceptCheck.Checked
    Save-Settings
})
$script:DetailedCheck.Add_CheckedChanged({
    $script:Detailed = [bool]$script:DetailedCheck.Checked
    Save-Settings
})
$script:MonthsBox.Add_SelectedIndexChanged({
    if ($script:MonthsBox.SelectedIndex -ge 0) {
        $script:UnusedMonths = [int]$script:MonthValues[$script:MonthsBox.SelectedIndex]
        $script:InstalledCache = $script:InstalledCache
        Save-Settings
    }
})
$script:Form.Add_Resize({ Update-ChromeLayout })
$script:Form.Add_Shown({
    Update-ChromeLayout
    if (-not $script:SmokeTest) { Start-UpdateCheck -Automatic }
})
$script:Form.Add_KeyDown({
    if ($_.KeyCode -eq [Windows.Forms.Keys]::F1) { Show-Help; $_.SuppressKeyPress = $true }
    elseif ($_.KeyCode -eq [Windows.Forms.Keys]::Escape -and $script:Busy) { Stop-CurrentJob; $_.SuppressKeyPress = $true }
    elseif ($_.Control -and $_.KeyCode -eq [Windows.Forms.Keys]::F) { $script:SearchBox.Focus(); $_.SuppressKeyPress = $true }
})
$script:Form.Add_FormClosing({
    if ($script:UpdateClosing) { return }
    if ($script:Busy -and -not $script:AllowClose) {
        $answer = [Windows.Forms.MessageBox]::Show($script:Form, 'A command is still running. Close the window anyway?', 'Clean Installer', 'OKCancel', 'Warning', 'Button2')
        if ($answer -ne [Windows.Forms.DialogResult]::OK) { $_.Cancel = $true; return }
        Stop-CurrentJob
    }
})

$script:Timer = New-Object Windows.Forms.Timer
$script:Timer.Interval = 200
$script:Timer.Add_Tick({ Invoke-WorkTick })
$script:Timer.Start()

$script:LoadingSettings = $false
Update-Shortcut
Set-View 'search' $false
$winget = Get-WingetPath
if ($winget) {
    $script:ToolsOk = $true
    Set-Status 'Ready' 'idle'
    Write-Activity 'Ready. Search the catalog, or open Installed, Updates, or Suspects.' 'text'
    Write-Activity ('winget: ' + $winget) 'dim'
    if (-not $script:SmokeTest) { Start-SourceUpdate }
} else {
    $script:ToolsOk = $false
    $message = 'winget was not found. Install App Installer from the Microsoft Store, then open Clean Installer again.'
    Set-Status $message 'err'
    Write-Activity $message 'err'
    if (-not $script:SmokeTest) {
        [Windows.Forms.MessageBox]::Show($script:Form, $message, 'Clean Installer', 'OK', 'Error') | Out-Null
    }
}
Update-Actions

if ($script:SmokeTest) {
    try {
        Invoke-SmokeTest
        exit 0
    } catch {
        Write-Output ("SMOKE FAIL " + $_.Exception.Message)
        exit 1
    }
}

[Windows.Forms.Application]::Run($script:Form)
