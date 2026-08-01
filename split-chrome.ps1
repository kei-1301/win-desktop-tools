# Open two URLs as chrome-less app windows tiled left / right, then reload
# both on a fixed interval until stopped with Ctrl+C.
#
# Why it works this way (all points below were verified by measurement):
#
#   * --window-position / --window-size are discarded when the invocation is
#     delegated to an already-running browser session, so windows are placed
#     afterwards with SetWindowPos instead.
#
#   * Synthetic F5 (PostMessage WM_KEYDOWN) only reloads a FOREGROUND window;
#     Chromium ignores it in the background. Driving reloads that way would
#     steal focus every interval, so reloads go through the DevTools Protocol,
#     which needs no focus at all -- and works even when the page's own
#     auto-refresh script is broken.
#
#   * CDP requires --remote-debugging-port, which cannot be attached to an
#     existing session. Hence the dedicated profile directory: sites needing a
#     login must be signed into once, after which the profile keeps the session.
#
# The debugging port listens on 127.0.0.1 only, but note that any local process
# can drive this browser through it while the script runs. Use a port you are
# not exposing, and keep this profile separate from your main browsing.
#
# Usage:
#   .\split-chrome.ps1 -Left https://a.example -Right https://b.example
#   .\split-chrome.ps1 -Left ... -Right ... -IntervalMinutes 10 -CoverTaskbar

param(
    [Parameter(Mandatory = $true)][string]$Left,
    [Parameter(Mandatory = $true)][string]$Right,
    [int]$IntervalMinutes = 30,
    # Extend windows over the taskbar strip (pair with taskbar auto-hide).
    [switch]$CoverTaskbar,
    [int]$Port = 9223,
    [string]$ProfileDir = "$env:LOCALAPPDATA\ChromeDashboard"
)

$ErrorActionPreference = 'Stop'

$chromePaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
)
$chrome = $chromePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $chrome) { throw 'chrome.exe not found' }

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class ChromeWin {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    const uint SWP_NOZORDER = 0x0004;
    const uint SWP_NOACTIVATE = 0x0010;
    const int SW_RESTORE = 9;
    const uint GW_OWNER = 4;
    const int GWL_STYLE = -16;
    const int GWL_EXSTYLE = -20;
    const int WS_CAPTION = 0x00C00000;
    const int WS_EX_TOOLWINDOW = 0x00000080;

    // Real Chrome browser/app windows only.
    //
    // Transient UI such as the "translate this page?" bubble also reports class
    // Chrome_WidgetWin_1 with a non-empty title, so it must be excluded or the
    // new-window detection latches onto the bubble and tiles that instead.
    // Bubbles are owned tool windows without a caption; real windows are not.
    public static IntPtr[] Handles() {
        var found = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            if (!IsWindowVisible(h)) return true;
            var cls = new StringBuilder(64);
            GetClassNameW(h, cls, 64);
            if (cls.ToString() != "Chrome_WidgetWin_1") return true;
            var title = new StringBuilder(512);
            if (GetWindowTextW(h, title, 512) == 0) return true;
            if (GetWindow(h, GW_OWNER) != IntPtr.Zero) return true;
            if ((GetWindowLong(h, GWL_STYLE) & WS_CAPTION) != WS_CAPTION) return true;
            if ((GetWindowLong(h, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) != 0) return true;
            found.Add(h);
            return true;
        }, IntPtr.Zero);
        return found.ToArray();
    }

    public static long Area(IntPtr h) {
        RECT r;
        if (!GetWindowRect(h, out r)) return 0;
        return (long)(r.Right - r.Left) * (r.Bottom - r.Top);
    }

    public static void Place(IntPtr h, int x, int y, int w, int hgt) {
        ShowWindow(h, SW_RESTORE);  // SetWindowPos is a no-op on a maximized window
        SetWindowPos(h, IntPtr.Zero, x, y, w, hgt, SWP_NOZORDER | SWP_NOACTIVATE);
    }
}
'@

function Get-CdpPages {
    param([int]$Port, [int]$TimeoutSec = 3)
    try {
        $all = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json" -TimeoutSec $TimeoutSec
        return @($all | Where-Object { $_.type -eq 'page' })
    } catch {
        return @()
    }
}

function Invoke-CdpReload {
    param([string]$TargetId, [int]$Port)

    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $token = [System.Threading.CancellationToken]::None
    try {
        $socket.ConnectAsync([Uri]"ws://127.0.0.1:$Port/devtools/page/$TargetId", $token).GetAwaiter().GetResult() | Out-Null
        $payload = '{"id":1,"method":"Page.reload","params":{"ignoreCache":true}}'
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $bytes)
        $socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $token).GetAwaiter().GetResult() | Out-Null
        Start-Sleep -Milliseconds 500  # let the frame flush before tearing down
        return $true
    } catch {
        Write-Warning "reload failed for $TargetId : $($_.Exception.Message)"
        return $false
    } finally {
        # Abort, not CloseAsync: the pending CDP response would make a graceful
        # close throw, and the command has already been sent by this point.
        try { $socket.Abort() } catch { }
        $socket.Dispose()
    }
}

# Wait for a newly opened Chrome window and return its handle.
# If several appear at once, the largest is the app window we launched.
function Wait-NewWindow {
    param([IntPtr[]]$Before, [int]$TimeoutMs = 30000)

    $deadline = [Environment]::TickCount + $TimeoutMs
    while ([Environment]::TickCount -lt $deadline) {
        $fresh = @([ChromeWin]::Handles() | Where-Object { $Before -notcontains $_ })
        if ($fresh.Count -ge 1) {
            return ($fresh | Sort-Object { [ChromeWin]::Area($_) } -Descending)[0]
        }
        Start-Sleep -Milliseconds 200
    }
    throw 'Timed out waiting for a new Chrome window'
}

# Chrome opens unrelated page targets of its own (the web store payment page
# showed up on a fresh profile), so prefer the target whose URL is the one we
# asked for, and only fall back to "any new page" after giving it time to appear.
function Wait-NewCdpPage {
    param([string[]]$BeforeIds, [int]$Port, [string]$ExpectUrl, [int]$TimeoutMs = 30000)

    # Chrome reports a normalized URL ("https://example.com" comes back as
    # "https://example.com/"), so compare without the trailing slash.
    $wanted = $ExpectUrl.TrimEnd('/')

    $deadline = [Environment]::TickCount + $TimeoutMs
    $settleUntil = [Environment]::TickCount + 8000
    while ([Environment]::TickCount -lt $deadline) {
        $fresh = @(Get-CdpPages -Port $Port | Where-Object { $BeforeIds -notcontains $_.id })
        $exact = @($fresh | Where-Object { $_.url.TrimEnd('/') -eq $wanted })
        if ($exact.Count -ge 1) { return $exact[0] }
        # A redirect can rewrite the URL, so accept any new page once settled.
        if ($fresh.Count -ge 1 -and [Environment]::TickCount -gt $settleUntil) { return $fresh[0] }
        Start-Sleep -Milliseconds 300
    }
    throw 'Timed out waiting for a new CDP target'
}

Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen
$area = if ($CoverTaskbar) { $screen.Bounds } else { $screen.WorkingArea }
$halfWidth = [int]($area.Width / 2)

$panes = @(
    @{ Name = 'left';  Url = $Left;  X = $area.X },
    @{ Name = 'right'; Url = $Right; X = $area.X + $halfWidth }
)

$tracked = @()
foreach ($pane in $panes) {
    $windowsBefore = [ChromeWin]::Handles()
    $pageIdsBefore = @(Get-CdpPages -Port $Port | ForEach-Object { $_.id })

    # Start-Process, not the call operator: with a dedicated profile the first
    # invocation becomes the browser process itself and would block until exit.
    # The throttling flags keep a page's own setInterval/setTimeout refresh alive
    # while the window sits in the background, which Chrome otherwise slows to a
    # crawl or freezes. Reloads here do not depend on them -- CDP works either
    # way -- but they stop the page's built-in auto-refresh from stalling.
    $chromeArgs = @(
        "--user-data-dir=$ProfileDir"
        "--remote-debugging-port=$Port"
        '--no-first-run'
        '--no-default-browser-check'
        '--disable-background-timer-throttling'
        '--disable-backgrounding-occluded-windows'
        '--disable-renderer-backgrounding'
        "--app=$($pane.Url)"
    )
    Start-Process -FilePath $chrome -ArgumentList $chromeArgs | Out-Null

    $handle = Wait-NewWindow -Before $windowsBefore
    [ChromeWin]::Place($handle, $pane.X, $area.Y, $halfWidth, $area.Height)

    $page = Wait-NewCdpPage -BeforeIds $pageIdsBefore -Port $Port -ExpectUrl $pane.Url
    $tracked += @{ Name = $pane.Name; Url = $pane.Url; TargetId = $page.id }

    Write-Host ("{0,-6} placed at {1},{2} {3}x{4}" -f $pane.Name, $pane.X, $area.Y, $halfWidth, $area.Height)
}

Write-Host ("reloading every {0} min - press Ctrl+C to stop" -f $IntervalMinutes)

while ($true) {
    Start-Sleep -Seconds ($IntervalMinutes * 60)

    $live = @(Get-CdpPages -Port $Port | ForEach-Object { $_.id })
    if ($live.Count -eq 0) {
        Write-Host 'browser is gone - stopping'
        break
    }

    foreach ($pane in $tracked) {
        if ($live -notcontains $pane.TargetId) {
            Write-Warning "$($pane.Name) window was closed - skipping"
            continue
        }
        $stamp = (Get-Date).ToString('HH:mm:ss')
        if (Invoke-CdpReload -TargetId $pane.TargetId -Port $Port) {
            Write-Host "$stamp reloaded $($pane.Name)"
        }
    }
}
