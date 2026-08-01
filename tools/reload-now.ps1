# Force an immediate reload of every page in the dashboard browser started by
# split-chrome.ps1. Independent of whatever auto-refresh the page itself has.
#
# Usage:
#   .\reload-now.ps1
#   .\reload-now.ps1 -Match 'example.com'   # only pages whose URL contains this

param(
    [string]$Match = '',
    [int]$Port = 9223
)

$ErrorActionPreference = 'Stop'

try {
    # Assign first: piping Invoke-RestMethod straight into Where-Object hands the
    # whole JSON array through as a single Object[] instead of enumerating it,
    # which silently defeats the filter.
    $response = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json" -TimeoutSec 5
} catch {
    throw "No dashboard browser listening on port $Port - is split-chrome.ps1 running?"
}

$pages = @($response | Where-Object { $_.type -eq 'page' })

if ($Match) { $pages = @($pages | Where-Object { $_.url -like "*$Match*" }) }
if ($pages.Count -eq 0) { throw 'No matching page found' }

foreach ($page in $pages) {
    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $token = [System.Threading.CancellationToken]::None
    try {
        $socket.ConnectAsync([Uri]$page.webSocketDebuggerUrl, $token).GetAwaiter().GetResult() | Out-Null
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"id":1,"method":"Page.reload","params":{"ignoreCache":true}}')
        $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(, $bytes)
        $socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $token).GetAwaiter().GetResult() | Out-Null
        Start-Sleep -Milliseconds 500  # let the frame flush before tearing down
        Write-Host "reloaded: $($page.url)"
    } finally {
        try { $socket.Abort() } catch { }
        $socket.Dispose()
    }
}
