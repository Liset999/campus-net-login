[CmdletBinding()]
param(
    [int]$Port = 0,
    [switch]$NoOpen
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$server = Join-Path $PSScriptRoot "mvp-server.mjs"
$portFile = Join-Path $root "diagnostics\mvp-port.json"
$node = Get-Command node -ErrorAction Stop
$actualPort = $Port
$running = $false

function Get-HealthUrl {
    if ($actualPort -gt 0) {
        return "http://127.0.0.1:$actualPort/api/health"
    }
    return $null
}

$healthUrl = Get-HealthUrl
if ($healthUrl) {
    try {
        $response = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 2 -UseBasicParsing
        $running = $response.StatusCode -eq 200
    } catch {
        $running = $false
    }
}

if (-not $running) {
    Start-Process -FilePath $node.Source -ArgumentList @($server, "--port", "$Port") -WorkingDirectory $root -WindowStyle Hidden | Out-Null

    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Milliseconds 250

        if ($actualPort -eq 0 -and (Test-Path -LiteralPath $portFile)) {
            try {
                $portInfo = Get-Content -LiteralPath $portFile -Raw | ConvertFrom-Json
                if ([int]$portInfo.port -gt 0) {
                    $actualPort = [int]$portInfo.port
                }
            } catch {}
        }

        $healthUrl = Get-HealthUrl
        if ($healthUrl) {
            try {
                $response = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 2 -UseBasicParsing
                if ($response.StatusCode -eq 200) {
                    $running = $true
                    break
                }
            } catch {}
        }
    }
}

if (-not $running) {
    throw "MVP 服务没有启动"
}

$homeUrl = "http://127.0.0.1:$actualPort/"
if (-not $NoOpen)
{
    Start-Process $homeUrl
}
Write-Output "Campus Link MVP: $homeUrl"


