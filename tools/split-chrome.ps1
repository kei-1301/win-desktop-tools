# Open two URLs as chrome-less app windows tiled left / right, then watch both
# and reload whichever one breaks, until stopped with Ctrl+C. A fixed-interval
# reload is available too but off by default (-IntervalMinutes).
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
#   * CDP requires --remote-debugging-port, which Chrome only honours on a
#     non-default data directory, so this runs on a profile of its own. That
#     also means your everyday Chrome can stay open while it runs. See the note
#     further down for the two measurements behind this.
#
#   * Health is judged from the rendered text (CDP Runtime.evaluate), not from
#     HTTP status, because the failure being watched for is a page that loads
#     fine and then shows an error on screen. Two guards keep this from looping:
#     a page that is not readyState=complete is never judged (it is momentarily
#     blank during every navigation), and a pane that stays broken backs off
#     30s -> 60s -> ... -> 600s instead of reloading forever.
#
# The debugging port listens on 127.0.0.1 only, but note that any local process
# can drive this browser through it while the script runs.
#
# Progress output is silent by default; pass -Verbose to see placement and each
# reload.
#
# Usage:
#   .\split-chrome.ps1 -Left https://a.example -Right https://b.example
#   .\split-chrome.ps1 -Left ... -Right ... -ErrorPattern "session expired"
#   .\split-chrome.ps1 -Left ... -Right ... -IntervalMinutes 10 -CoverTaskbar

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Left,
    [Parameter(Mandatory = $true)][string]$Right,
    # 0 disables the timer; pages are then reloaded only when they look broken.
    [int]$IntervalMinutes = 0,
    # How often each page is inspected for an error state. Each check is a
    # single CDP evaluate (a few ms), so a short interval is cheap and makes
    # recovery feel immediate.
    [int]$CheckIntervalSeconds = 3,
    # Text that means "this page is broken". Written with \uXXXX escapes on
    # purpose: PowerShell 5.1 reads a BOM-less UTF-8 script as ANSI, so literal
    # Japanese here would arrive mangled and break parsing (measured). The regex
    # engine decodes the escapes, so Japanese page text still matches.
    #   \u30a8\u30e9\u30fc = "error" (katakana)
    #   \u5931\u6557 = "failure"
    #   \u30bf\u30a4\u30e0\u30a2\u30a6\u30c8 = "timeout"
    [string]$ErrorPattern = 'error|exception|ERR_|DNS_PROBE|Bad Gateway|Service Unavailable|\u30a8\u30e9\u30fc|\u5931\u6557|\u30bf\u30a4\u30e0\u30a2\u30a6\u30c8|\u30a2\u30af\u30bb\u30b9\u3067\u304d\u307e\u305b\u3093',
    # Treat an empty page as broken too (blank / hung screens).
    [switch]$NoBlankCheck,
    # Extend windows over the taskbar strip (pair with taskbar auto-hide).
    [switch]$CoverTaskbar,
    [int]$Port = 9223,
    # Dedicated Chrome profile for the dashboard. It has to be separate from
    # your everyday one -- see the note below the parameters for why.
    [string]$ProfileDir = "$env:LOCALAPPDATA\ChromeDashboard",
    # Just open and place the windows, then exit: no debugging port, no watching.
    # This is the mode to use with your normal signed-in profile, letting the
    # auto-reload-extension do the reloading from inside the page instead.
    [switch]$NoWatch
)

$ErrorActionPreference = 'Stop'

# Why this cannot run on your everyday Chrome profile, both measured on 150:
#
#   * Chrome refuses --remote-debugging-port whenever the data directory is the
#     default one, whether that is implied or spelled out in full. The port
#     simply never opens, so there is no way to drive reloads.
#
#   * Copying the signed-in cookies into another directory does not help either:
#     since Chrome 127 they are sealed with app-bound encryption and a second
#     profile just gets a sign-in screen.
#
# So a dedicated profile it is. Sign in once inside the window it opens and the
# session persists there from then on -- and unlike the default profile, this
# needs no closing of your normal Chrome.
$isFirstRun = -not (Test-Path $ProfileDir)

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

# Browser processes (not renderers) sharing the given data directory, counting
# both the explicit spelling and the implicit default.
function Get-BrowsersOnDataDir {
    param([string]$DataDir)
    return @(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue -Verbose:$false |
        Where-Object {
            $_.CommandLine -and $_.CommandLine -notlike '*--type=*' -and
            ($_.CommandLine -notlike '*--user-data-dir=*' -or $_.CommandLine -like "*--user-data-dir=$DataDir*")
        })
}

function Test-CdpPort {
    param([int]$Port)
    try {
        # -Verbose:$false so -Verbose on the script shows only our own progress,
        # not the HTTP chatter of every poll.
        Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/version" -TimeoutSec 2 -Verbose:$false | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Get-CdpPages {
    param([int]$Port, [int]$TimeoutSec = 3)
    try {
        $all = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json" -TimeoutSec $TimeoutSec -Verbose:$false
        return @($all | Where-Object { $_.type -eq 'page' })
    } catch {
        return @()
    }
}

function Receive-CdpMessage {
    param($Socket, $Token)

    $buffer = New-Object byte[] 32768
    $sb = New-Object System.Text.StringBuilder
    do {
        $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $buffer)
        $res = $Socket.ReceiveAsync($seg, $Token).GetAwaiter().GetResult()
        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        [void]$sb.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $res.Count))
    } while (-not $res.EndOfMessage)
    return $sb.ToString()
}

# Send one CDP command. Returns the reply object, or $true/$false with -NoReply.
function Invoke-CdpCommand {
    param(
        [string]$TargetId,
        [int]$Port,
        [string]$Method,
        $Params,
        [int]$TimeoutSec = 8,
        [switch]$NoReply
    )

    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $cts = New-Object System.Threading.CancellationTokenSource
    $cts.CancelAfter($TimeoutSec * 1000)   # ReceiveAsync would block forever otherwise
    $token = $cts.Token
    try {
        $socket.ConnectAsync([Uri]"ws://127.0.0.1:$Port/devtools/page/$TargetId", $token).GetAwaiter().GetResult() | Out-Null
        $payload = @{ id = 1; method = $Method }
        if ($Params) { $payload['params'] = $Params }
        $json = $payload | ConvertTo-Json -Depth 6 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $bytes)
        $socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $token).GetAwaiter().GetResult() | Out-Null

        if ($NoReply) {
            Start-Sleep -Milliseconds 300  # let the frame flush before tearing down
            return $true
        }
        # Events arrive interleaved with replies, so read until our id shows up.
        while (-not $token.IsCancellationRequested) {
            $text = Receive-CdpMessage -Socket $socket -Token $token
            if (-not $text) { break }
            $obj = $text | ConvertFrom-Json
            if ($obj.PSObject.Properties.Name -contains 'id' -and $obj.id -eq 1) { return $obj }
        }
        return $null
    } catch {
        Write-Verbose "CDP $Method failed: $($_.Exception.Message)"
        if ($NoReply) { return $false }
        return $null
    } finally {
        # Abort, not CloseAsync: a pending CDP response makes a graceful close throw.
        try { $socket.Abort() } catch { }
        $socket.Dispose()
        $cts.Dispose()
    }
}

function Invoke-CdpReload {
    param([string]$TargetId, [int]$Port)
    return [bool](Invoke-CdpCommand -TargetId $TargetId -Port $Port -Method 'Page.reload' -Params @{ ignoreCache = $true } -NoReply)
}

# Classify a page as 'ok', 'blank', 'error', or $null when it cannot be judged
# (still loading, or CDP did not answer). Callers must not reload on $null.
function Get-PageHealth {
    param([string]$TargetId, [int]$Port, [string]$Pattern, [bool]$CheckBlank)

    $expression = @'
(function () {
  var body = document.body;
  var text = body ? (body.innerText || "") : "";
  return JSON.stringify({
    ready: document.readyState,
    len: text.replace(/\s+/g, "").length,
    text: text.slice(0, 4000)
  });
})()
'@
    $reply = Invoke-CdpCommand -TargetId $TargetId -Port $Port -Method 'Runtime.evaluate' -Params @{
        expression    = $expression
        returnByValue = $true
    }
    if (-not $reply) { return $null }

    $raw = $reply.result.result.value
    if (-not $raw) { return $null }
    try { $state = $raw | ConvertFrom-Json } catch { return $null }

    # A page mid-navigation is legitimately empty; judging it would cause a
    # reload loop right after every reload.
    if ($state.ready -ne 'complete') { return $null }

    if ($Pattern -and $state.text -match $Pattern) { return 'error' }
    if ($CheckBlank -and $state.len -eq 0) { return 'blank' }
    return 'ok'
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

# A port already answering belongs to a browser this script started earlier and
# is fine to join. One that answers while no dashboard browser is running means
# something else took it, and waiting would hang on a target that never appears.
if (-not $NoWatch) {
    $servingThisProfile = @(Get-BrowsersOnDataDir -DataDir $ProfileDir |
        Where-Object { $_.CommandLine -like "*--remote-debugging-port=$Port*" })
    if ($servingThisProfile.Count -eq 0 -and (Test-CdpPort -Port $Port)) {
        Write-Host ''
        Write-Host "Port $Port is already used by another browser instance." -ForegroundColor Yellow
        Write-Host '  Pick a free one with -Port, or stop that instance.'
        Write-Host ''
        exit 1
    }
}

if ($isFirstRun -and -not $NoWatch) {
    Write-Host ''
    Write-Host 'Setting up the dashboard profile for the first time.' -ForegroundColor Cyan
    Write-Host '  Pages needing a login (Gmail and friends) will show a sign-in screen.'
    Write-Host '  Sign in once in that window - this profile remembers it from then on.'
    Write-Host ''
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
    $pageIdsBefore = if ($NoWatch) { @() } else { @(Get-CdpPages -Port $Port | ForEach-Object { $_.id }) }

    # Start-Process, not the call operator: with a dedicated profile the first
    # invocation becomes the browser process itself and would block until exit.
    # The throttling flags keep timers alive while a window sits in the
    # background, which Chrome otherwise slows to a crawl or freezes -- that is
    # what the in-page extension relies on under -NoWatch.
    $chromeArgs = @()
    # Under -NoWatch nothing needs the debugging port, so the everyday profile is
    # used: no --user-data-dir, which keeps the windows signed in as usual.
    # Quoted because the path may contain spaces and Start-Process does not quote
    # list items for you; unquoted, it splits at the space and Chrome silently
    # creates a stray profile directory from the first fragment.
    if (-not $NoWatch) {
        $chromeArgs += "--user-data-dir=`"$ProfileDir`""
        $chromeArgs += "--remote-debugging-port=$Port"
    }
    $chromeArgs += @(
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

    if (-not $NoWatch) {
        $page = Wait-NewCdpPage -BeforeIds $pageIdsBefore -Port $Port -ExpectUrl $pane.Url
        $tracked += @{ Name = $pane.Name; Url = $pane.Url; TargetId = $page.id }
    }

    Write-Verbose ("{0,-6} placed at {1},{2} {3}x{4}" -f $pane.Name, $pane.X, $area.Y, $halfWidth, $area.Height)
}

if ($NoWatch) {
    Write-Verbose 'placed both windows; reloading is left to the extension'
    return
}

if ($IntervalMinutes -gt 0) {
    Write-Verbose ("watching every {0}s, plus a timed reload every {1} min - Ctrl+C to stop" -f $CheckIntervalSeconds, $IntervalMinutes)
} else {
    Write-Verbose ("watching every {0}s, reloading only on errors - Ctrl+C to stop" -f $CheckIntervalSeconds)
}

# Reloading cannot fix a page that is broken at the source, so an unchanged
# error must not spin the loop. After each reload a pane is left alone for
# GraceSeconds, doubling up to MaxGrace while the error persists, and reset as
# soon as the page comes back healthy.
$graceSeconds = 30
$maxGraceSeconds = 600
$state = @{}
foreach ($pane in $tracked) {
    # LastReload starts far enough back that a pane which is already broken gets
    # reloaded at the first check instead of waiting out a grace period it never
    # earned. Pages still loading are excluded by the readyState guard.
    $state[$pane.TargetId] = @{
        LastReload = [Environment]::TickCount - ($graceSeconds * 1000)
        Grace      = $graceSeconds
        Strikes    = 0
    }
}

while ($true) {
    Start-Sleep -Seconds $CheckIntervalSeconds

    $live = @(Get-CdpPages -Port $Port | ForEach-Object { $_.id })
    if ($live.Count -eq 0) {
        Write-Verbose 'browser is gone - stopping'
        break
    }

    foreach ($pane in $tracked) {
        if ($live -notcontains $pane.TargetId) {
            Write-Verbose "$($pane.Name) window was closed - skipping"
            continue
        }

        $paneState = $state[$pane.TargetId]
        $sinceReload = ([Environment]::TickCount - $paneState.LastReload) / 1000
        $stamp = (Get-Date).ToString('HH:mm:ss')

        if ($IntervalMinutes -gt 0 -and $sinceReload -ge ($IntervalMinutes * 60)) {
            if (Invoke-CdpReload -TargetId $pane.TargetId -Port $Port) {
                $paneState.LastReload = [Environment]::TickCount
                Write-Verbose "$stamp reloaded $($pane.Name) (timer)"
            }
            continue
        }

        $health = Get-PageHealth -TargetId $pane.TargetId -Port $Port -Pattern $ErrorPattern -CheckBlank (-not $NoBlankCheck)
        if (-not $health) { continue }   # loading or unreachable: not a verdict

        if ($health -eq 'ok') {
            $paneState.Grace = $graceSeconds
            $paneState.Strikes = 0
            continue
        }

        if ($sinceReload -lt $paneState.Grace) { continue }

        if (Invoke-CdpReload -TargetId $pane.TargetId -Port $Port) {
            $paneState.LastReload = [Environment]::TickCount
            $paneState.Strikes++
            Write-Verbose "$stamp reloaded $($pane.Name) ($health, attempt $($paneState.Strikes))"
            if ($paneState.Strikes -ge 2) {
                $paneState.Grace = [Math]::Min($paneState.Grace * 2, $maxGraceSeconds)
                Write-Verbose "$stamp $($pane.Name) still failing - backing off to $($paneState.Grace)s"
            }
        }
    }
}
