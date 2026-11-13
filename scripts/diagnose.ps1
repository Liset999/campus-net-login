[CmdletBinding()]
param(
    [string]$TargetSsid,
    [string]$ProbeUrl = "http://www.msftconnecttest.com/connecttest.txt",
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Get-ActualSsid {
    $lines = @(& netsh wlan show interfaces 2>$null | ForEach-Object { "$_" })

    foreach ($line in $lines) {
        if ($line -match "^\s*SSID\s*:\s*(.+?)\s*$") {
            return $Matches[1].Trim()
        }
    }

    return $null
}

function Remove-QueryString {
    param([string]$Line)

    if ($Line -match "^(Location:\s*)([^?]+)(\?.*)$") {
        return "$($Matches[1])$($Matches[2])"
    }

    return $Line
}

function Invoke-CurlProbe {
    param([bool]$NoProxy)

    $curlArgs = @("-i", "--silent", "--show-error", "--max-time", "10")

    if ($NoProxy) {
        $curlArgs += @("--noproxy", "*")
    }

    $curlArgs += $ProbeUrl
    $raw = @(& curl.exe @curlArgs 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    $evidence = @(
        $raw |
            Where-Object { $_ -match "^(HTTP/|Location:|Content-Type:|Proxy-Connection:|curl:)" } |
            ForEach-Object { Remove-QueryString $_ }
    )

    return [ordered]@{
        no_proxy = $NoProxy
        exit_code = $exitCode
        headers = $evidence
    }
}

function Get-ProxyProcesses {
    $names = @("clash", "clash-verge", "clash-verge-service", "mihomo", "verge-mihomo", "v2ray", "nekoray", "sing-box", "surge")

    return @(
        Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $names -contains $_.ProcessName } |
            Select-Object -ExpandProperty ProcessName -Unique
    )
}

$profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
$wifiProfile = $profiles |
    Where-Object { $_.InterfaceAlias -match "WLAN|Wi-Fi|无线" } |
    Select-Object -First 1

$actualSsid = Get-ActualSsid
$wifiAlias = if ($wifiProfile) { $wifiProfile.InterfaceAlias } else { $null }
$ipConfig = if ($wifiAlias) { Get-NetIPConfiguration -InterfaceAlias $wifiAlias -ErrorAction SilentlyContinue } else { $null }

$internetSettings = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue

$proxyEnvironment = @(
    Get-ChildItem Env: |
        Where-Object { $_.Name -match "proxy" } |
        ForEach-Object {
            [ordered]@{
                name = $_.Name
                value = $_.Value
            }
        }
)

$defaultRoutes = @(
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Select-Object InterfaceAlias, NextHop, RouteMetric, PolicyStore
)

$dhcpEnabled = $null
if ($wifiAlias) {
    $ipInterface = Get-NetIPInterface -InterfaceAlias $wifiAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue

    if ($ipInterface) {
        $dhcpEnabled = "$($ipInterface.Dhcp)"
    }
}

$result = [ordered]@{
    schema_version = "0.2"
    captured_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    target_ssid = $TargetSsid
    current_wifi = [ordered]@{
        ssid = if ($actualSsid) { $actualSsid } elseif ($wifiProfile) { $wifiProfile.Name } else { $null }
        profile_name = if ($wifiProfile) { $wifiProfile.Name } else { $null }
        interface_alias = $wifiAlias
        ipv4_connectivity = if ($wifiProfile) { "$($wifiProfile.IPv4Connectivity)" } else { $null }
        ipv6_connectivity = if ($wifiProfile) { "$($wifiProfile.IPv6Connectivity)" } else { $null }
        target_matches = if ($TargetSsid) { [bool]($actualSsid -and $actualSsid -eq $TargetSsid) } else { $null }
    }
    ip = [ordered]@{
        addresses = if ($ipConfig) { @($ipConfig.IPv4Address | ForEach-Object { $_.IPAddress }) } else { @() }
        default_gateways = if ($ipConfig) { @($ipConfig.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) } else { @() }
        dns_servers = if ($ipConfig) { @($ipConfig.DNSServer.ServerAddresses) } else { @() }
        dhcp_enabled = $dhcpEnabled
    }
    default_routes = $defaultRoutes
    proxy = [ordered]@{
        winhttp = @(& netsh winhttp show proxy 2>&1 | ForEach-Object { "$_" })
        wininet = [ordered]@{
            enabled = [bool]$internetSettings.ProxyEnable
            server = $internetSettings.ProxyServer
            auto_config_url = $internetSettings.AutoConfigURL
            bypass = $internetSettings.ProxyOverride
        }
        environment = $proxyEnvironment
        processes = @(Get-ProxyProcesses)
    }
    probes = @(
        (Invoke-CurlProbe -NoProxy $true),
        (Invoke-CurlProbe -NoProxy $false)
    )
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot "..\diagnostics\latest.json"
}

$outputFullPath = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $outputFullPath
New-Item -ItemType Directory -Force $outputDirectory | Out-Null
$result | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $outputFullPath

Write-Output ($result | ConvertTo-Json -Depth 10)
Write-Output "Saved diagnostic report to: $outputFullPath"

