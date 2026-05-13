# Teams Always Green
# Bare-bones tray runtime. Keeps Teams presence active by periodically tapping
# Scroll Lock off/on without leaving the key state changed.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

Add-Type -ReferencedAssemblies @("System.Drawing", "System.Windows.Forms") -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Windows.Forms;

public static class TagKeyboard {
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
}

public static class NativeIcon {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);
}

public class TagMenuColorTable : ProfessionalColorTable {
    private Color backColor;
    private Color borderColor;
    private Color selectedColor;
    private Color separatorColor;

    public TagMenuColorTable(Color backColor, Color borderColor, Color selectedColor, Color separatorColor) {
        this.backColor = backColor;
        this.borderColor = borderColor;
        this.selectedColor = selectedColor;
        this.separatorColor = separatorColor;
    }

    public override Color ToolStripDropDownBackground { get { return backColor; } }
    public override Color ImageMarginGradientBegin { get { return backColor; } }
    public override Color ImageMarginGradientMiddle { get { return backColor; } }
    public override Color ImageMarginGradientEnd { get { return backColor; } }
    public override Color MenuBorder { get { return borderColor; } }
    public override Color MenuItemBorder { get { return selectedColor; } }
    public override Color MenuItemSelected { get { return selectedColor; } }
    public override Color SeparatorDark { get { return separatorColor; } }
    public override Color SeparatorLight { get { return separatorColor; } }
}
"@

$script:AppName = "Teams Always Green"
$script:IntervalSeconds = 60
$script:IsRunning = $true
$script:ToggleCount = 0
$script:LastRunAt = $null
$script:NextRunAt = (Get-Date).AddSeconds($script:IntervalSeconds)
$script:IsShuttingDown = $false
$script:RunningTextColor = [System.Drawing.Color]::FromArgb(34, 197, 94)
$script:StoppedTextColor = [System.Drawing.Color]::FromArgb(239, 68, 68)
$script:DarkMenuBackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
$script:DarkMenuForeColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
$script:DarkMenuBorderColor = [System.Drawing.Color]::FromArgb(72, 72, 72)
$script:DarkMenuSelectedColor = [System.Drawing.Color]::FromArgb(64, 64, 64)
$script:DarkMenuSeparatorColor = [System.Drawing.Color]::FromArgb(88, 88, 88)

$script:DataRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "TeamsAlwaysGreen"
$script:LogDirectory = Join-Path $script:DataRoot "Logs"
$script:LogRetentionDays = 5

function Ensure-LogDirectory {
    if (-not (Test-Path -LiteralPath $script:LogDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
    }
}

function Write-AppLog {
    param([string]$Message)

    try {
        Ensure-LogDirectory
        Remove-OldLogFiles
        $logPath = Join-Path $script:LogDirectory ("Teams-Always-Green-{0}.log" -f (Get-Date).ToString("yyyy-MM-dd"))
        $line = "[{0}] {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"), $Message
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch {
        $null = $_
    }
}

function Remove-OldLogFiles {
    try {
        if (-not (Test-Path -LiteralPath $script:LogDirectory -PathType Container)) { return }
        $cutoff = (Get-Date).AddDays(-[double]$script:LogRetentionDays)
        Get-ChildItem -LiteralPath $script:LogDirectory -Filter "*.log" -File -ErrorAction Stop |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        $null = $_
    }
}

$mutexName = "Local\TeamsAlwaysGreen-BareBones"
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-AppLog "Another instance is already running; exiting."
    return
}

function Resolve-AppRoot {
    $runtimeDir = $PSScriptRoot
    $appDir = Split-Path -Parent $runtimeDir
    return (Split-Path -Parent $appDir)
}

function Get-BaseIcon {
    $appRoot = Resolve-AppRoot
    $iconPath = Join-Path $appRoot "assets\icons\Tray_Icon.ico"
    if (Test-Path -LiteralPath $iconPath -PathType Leaf) {
        try {
            return New-Object System.Drawing.Icon($iconPath)
        } catch {
            Write-AppLog ("Failed to load tray icon: {0}" -f $_.Exception.Message)
        }
    }
    return [System.Drawing.SystemIcons]::Application
}

function New-StatusIcon {
    param(
        [System.Drawing.Icon]$BaseIcon,
        [System.Drawing.Color]$StatusColor
    )

    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.Clear([System.Drawing.Color]::Transparent)
        $graphics.DrawIcon($BaseIcon, (New-Object System.Drawing.Rectangle 0, 0, 32, 32))

        $outlineBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $statusBrush = New-Object System.Drawing.SolidBrush($StatusColor)
        try {
            $graphics.FillEllipse($outlineBrush, 18, 18, 13, 13)
            $graphics.FillEllipse($statusBrush, 20, 20, 9, 9)
        } finally {
            $outlineBrush.Dispose()
            $statusBrush.Dispose()
        }

        $handle = [IntPtr]::Zero
        try {
            $handle = $bitmap.GetHicon()
            $icon = [System.Drawing.Icon]::FromHandle($handle)
            return $icon.Clone()
        } finally {
            if ($handle -ne [IntPtr]::Zero) {
                [NativeIcon]::DestroyIcon($handle) | Out-Null
            }
        }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Format-TimeSpanShort {
    param([TimeSpan]$TimeSpan)

    if ($TimeSpan.TotalSeconds -lt 0) { return "now" }
    if ($TimeSpan.TotalHours -ge 1) {
        return "{0}h {1}m {2}s" -f [int]$TimeSpan.TotalHours, $TimeSpan.Minutes, $TimeSpan.Seconds
    }
    if ($TimeSpan.TotalMinutes -ge 1) {
        return "{0}m {1}s" -f [int]$TimeSpan.TotalMinutes, $TimeSpan.Seconds
    }
    return "{0}s" -f [Math]::Max(0, [int][Math]::Ceiling($TimeSpan.TotalSeconds))
}

function Get-NextRunText {
    if (-not $script:IsRunning) { return "Next run: stopped" }
    return "Next run: {0}" -f (Format-TimeSpanShort ($script:NextRunAt - (Get-Date)))
}

function Invoke-PresenceTap {
    param([string]$Reason = "timer")

    try {
        $key = [byte]0x91
        $keyUp = [uint32]0x0002
        [TagKeyboard]::keybd_event($key, 0, 0, [UIntPtr]::Zero)
        [TagKeyboard]::keybd_event($key, 0, $keyUp, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 60
        [TagKeyboard]::keybd_event($key, 0, 0, [UIntPtr]::Zero)
        [TagKeyboard]::keybd_event($key, 0, $keyUp, [UIntPtr]::Zero)

        $script:ToggleCount++
        $script:LastRunAt = Get-Date
        $script:NextRunAt = $script:LastRunAt.AddSeconds($script:IntervalSeconds)
        Write-AppLog ("Presence tap completed. Reason={0}; Count={1}" -f $Reason, $script:ToggleCount)
    } catch {
        Write-AppLog ("Presence tap failed: {0}" -f $_.Exception.Message)
    }
}

function Start-AppLoop {
    $script:IsRunning = $true
    $script:NextRunAt = (Get-Date).AddSeconds($script:IntervalSeconds)
    Write-AppLog "Started."
    Update-Tray
}

function Stop-AppLoop {
    $script:IsRunning = $false
    Write-AppLog "Stopped."
    Update-Tray
}

function Exit-App {
    $script:IsShuttingDown = $true
    Write-AppLog "Exiting."
    [System.Windows.Forms.Application]::Exit()
}

function Restart-App {
    try {
        $appRoot = Resolve-AppRoot
        $launcherPath = Join-Path $appRoot "Teams Always Green.VBS"
        if (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf)) {
            Write-AppLog ("Restart failed: launcher not found at {0}." -f $launcherPath)
            return
        }

        Start-Process -FilePath wscript.exe -ArgumentList ('"{0}"' -f $launcherPath) -WorkingDirectory $appRoot | Out-Null
        Write-AppLog "Restart requested."
        Exit-App
    } catch {
        Write-AppLog ("Restart failed: {0}" -f $_.Exception.Message)
    }
}

function Test-WindowsAppsDarkMode {
    try {
        $theme = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name AppsUseLightTheme -ErrorAction Stop
        return ([int]$theme.AppsUseLightTheme -eq 0)
    } catch {
        return $false
    }
}

function Set-ToolStripItemTheme {
    param(
        [System.Windows.Forms.ToolStripItem]$Item,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor
    )

    if (-not $Item) { return }
    $Item.BackColor = $BackColor
    if ($Item -isnot [System.Windows.Forms.ToolStripSeparator]) {
        $Item.ForeColor = $ForeColor
    }
    if ($Item -is [System.Windows.Forms.ToolStripMenuItem] -and $Item.DropDownItems) {
        foreach ($child in $Item.DropDownItems) {
            Set-ToolStripItemTheme $child $BackColor $ForeColor
        }
    }
}

function Get-StatusTextColor {
    if ($script:IsRunning) {
        return $script:RunningTextColor
    }
    return $script:StoppedTextColor
}

function Update-StatusDisplay {
    $statusText = if ($script:IsRunning) { "Running" } else { "Stopped" }
    if ($script:StatusValueLabel) {
        $script:StatusValueLabel.Text = $statusText
        $script:StatusValueLabel.ForeColor = Get-StatusTextColor
    }
    return $statusText
}

function Apply-SystemMenuTheme {
    if (-not $script:Menu) { return }

    $isDark = Test-WindowsAppsDarkMode
    if ($isDark) {
        $backColor = $script:DarkMenuBackColor
        $foreColor = $script:DarkMenuForeColor
        $borderColor = $script:DarkMenuBorderColor
        $selectedColor = $script:DarkMenuSelectedColor
        $separatorColor = $script:DarkMenuSeparatorColor
    } else {
        $backColor = [System.Drawing.SystemColors]::Menu
        $foreColor = [System.Drawing.SystemColors]::MenuText
        $borderColor = [System.Drawing.SystemColors]::ControlDark
        $selectedColor = [System.Drawing.SystemColors]::MenuHighlight
        $separatorColor = [System.Drawing.SystemColors]::ControlDark
    }

    $script:Menu.BackColor = $backColor
    $script:Menu.ForeColor = $foreColor
    $colorTable = New-Object TagMenuColorTable -ArgumentList @($backColor, $borderColor, $selectedColor, $separatorColor)
    $script:Menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer($colorTable)
    foreach ($item in $script:Menu.Items) {
        Set-ToolStripItemTheme $item $backColor $foreColor
    }
    if ($script:StatusPanel) {
        $script:StatusPanel.BackColor = $backColor
    }
    if ($script:StatusPrefixLabel) {
        $script:StatusPrefixLabel.BackColor = $backColor
        $script:StatusPrefixLabel.ForeColor = $foreColor
    }
    if ($script:StatusValueLabel) {
        $script:StatusValueLabel.BackColor = $backColor
        $script:StatusValueLabel.ForeColor = Get-StatusTextColor
    }
}

$script:BaseIcon = Get-BaseIcon
$script:GreenIcon = New-StatusIcon $script:BaseIcon ([System.Drawing.Color]::FromArgb(34, 197, 94))
$script:RedIcon = New-StatusIcon $script:BaseIcon ([System.Drawing.Color]::FromArgb(239, 68, 68))

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotifyIcon.Text = $script:AppName
$script:NotifyIcon.Icon = $script:GreenIcon
$script:NotifyIcon.Visible = $true

$script:Menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:Menu.ShowImageMargin = $false
$script:StatusPanel = New-Object System.Windows.Forms.TableLayoutPanel
$script:StatusPanel.AutoSize = $true
$script:StatusPanel.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
$script:StatusPanel.ColumnCount = 2
$script:StatusPanel.RowCount = 1
$script:StatusPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$script:StatusPanel.Padding = New-Object System.Windows.Forms.Padding(0)
$script:StatusPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 20))) | Out-Null
$script:StatusPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$script:StatusPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null

$script:StatusPrefixLabel = New-Object System.Windows.Forms.Label
$script:StatusPrefixLabel.AutoSize = $true
$script:StatusPrefixLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$script:StatusPrefixLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
$script:StatusPrefixLabel.Padding = New-Object System.Windows.Forms.Padding(0)
$script:StatusPrefixLabel.Text = "Status: "
$script:StatusPrefixLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

$script:StatusValueLabel = New-Object System.Windows.Forms.Label
$script:StatusValueLabel.AutoSize = $true
$script:StatusValueLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Left
$script:StatusValueLabel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 0)
$script:StatusValueLabel.Padding = New-Object System.Windows.Forms.Padding(0)
$script:StatusValueLabel.Text = "Running"
$script:StatusValueLabel.Font = New-Object System.Drawing.Font($script:StatusValueLabel.Font, [System.Drawing.FontStyle]::Bold)
$script:StatusValueLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft

[void]$script:StatusPanel.Controls.Add($script:StatusPrefixLabel, 0, 0)
[void]$script:StatusPanel.Controls.Add($script:StatusValueLabel, 1, 0)
$script:StatusItem = New-Object System.Windows.Forms.ToolStripControlHost($script:StatusPanel)
$script:StatusItem.Margin = New-Object System.Windows.Forms.Padding(0, 1, 0, 1)
$script:StatusItem.Padding = New-Object System.Windows.Forms.Padding(0)
$script:NextRunItem = New-Object System.Windows.Forms.ToolStripMenuItem("Next run: 60s")
$script:NextRunItem.Enabled = $false
$script:LastRunItem = New-Object System.Windows.Forms.ToolStripMenuItem("Last run: never")
$script:LastRunItem.Enabled = $false
$script:StartStopItem = New-Object System.Windows.Forms.ToolStripMenuItem("Stop")
$script:RunOnceItem = New-Object System.Windows.Forms.ToolStripMenuItem("Run Once Now")
$script:RestartItem = New-Object System.Windows.Forms.ToolStripMenuItem("Restart")
$script:ExitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")

$script:StartStopItem.Add_Click({
    if ($script:IsRunning) {
        Stop-AppLoop
    } else {
        Start-AppLoop
    }
})

$script:RunOnceItem.Add_Click({
    Invoke-PresenceTap "manual"
    Update-Tray
})

$script:ExitItem.Add_Click({ Exit-App })
$script:RestartItem.Add_Click({ Restart-App })

[void]$script:Menu.Items.Add($script:StatusItem)
[void]$script:Menu.Items.Add($script:NextRunItem)
[void]$script:Menu.Items.Add($script:LastRunItem)
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:Menu.Items.Add($script:StartStopItem)
[void]$script:Menu.Items.Add($script:RunOnceItem)
[void]$script:Menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$script:Menu.Items.Add($script:RestartItem)
[void]$script:Menu.Items.Add($script:ExitItem)
$script:NotifyIcon.ContextMenuStrip = $script:Menu
$script:Menu.Add_Opening({ Apply-SystemMenuTheme })
Apply-SystemMenuTheme

function Update-Tray {
    if (-not $script:NotifyIcon) { return }

    $statusText = Update-StatusDisplay
    $script:NotifyIcon.Icon = if ($script:IsRunning) { $script:GreenIcon } else { $script:RedIcon }
    $script:NextRunItem.Text = Get-NextRunText
    $script:LastRunItem.Text = if ($script:LastRunAt) { "Last run: {0}" -f $script:LastRunAt.ToString("h:mm:ss tt") } else { "Last run: never" }
    $script:StartStopItem.Text = if ($script:IsRunning) { "Stop" } else { "Start" }
    $script:NotifyIcon.Text = "{0} - {1}" -f $script:AppName, $statusText
}

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 1000
$script:Timer.Add_Tick({
    if ($script:IsShuttingDown) { return }
    if ($script:IsRunning -and (Get-Date) -ge $script:NextRunAt) {
        Invoke-PresenceTap "timer"
    }
    Update-Tray
})
$script:Timer.Start()

[System.Windows.Forms.Application]::Add_ApplicationExit({
    try {
        if ($script:Timer) {
            $script:Timer.Stop()
            $script:Timer.Dispose()
        }
        if ($script:NotifyIcon) {
            $script:NotifyIcon.Visible = $false
            $script:NotifyIcon.Dispose()
        }
        if ($script:GreenIcon) { $script:GreenIcon.Dispose() }
        if ($script:RedIcon) { $script:RedIcon.Dispose() }
        if ($script:BaseIcon) { $script:BaseIcon.Dispose() }
        if ($script:Mutex) {
            $script:Mutex.ReleaseMutex()
            $script:Mutex.Dispose()
        }
    } catch {
        $null = $_
    }
})

Write-AppLog "Bare-bones tray runtime started."
Update-Tray
[System.Windows.Forms.Application]::Run()
