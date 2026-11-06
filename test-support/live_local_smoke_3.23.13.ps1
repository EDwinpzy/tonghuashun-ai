param(
    [string]$ScriptPath = '.\plugin-update\market-query-3.23.13\skills\market-query\scripts\market_query.ps1',
    [int]$ReadyTimeoutSeconds = 100
)

$ErrorActionPreference = 'Stop'

$installRoot = 'C:\应用\同花顺AI版\同花顺远航版'
$exe = Join-Path $installRoot 'bin\happ.exe'
if (-not (Test-Path -LiteralPath $exe)) {
    throw "Client executable not found: $exe"
}

$scriptFullPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$startedAt = Get-Date
$appProcess = $null

function Test-TcpPort {
    param([string]$Url)

    $uri = [uri]$Url
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($uri.Host, $uri.Port)
        return $task.Wait(500) -and $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-ReadyConfig {
    param([datetime]$Since)

    $configs = Get-ChildItem "$env:USERPROFILE\lumi\users\*\agent-sdk\opencode\config\opencode.jsonc" `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Since } |
        Sort-Object LastWriteTime -Descending

    foreach ($config in $configs) {
        $text = Get-Content -LiteralPath $config.FullName -Raw
        $url = [regex]::Match(
            $text,
            '"lumi"\s*:\s*\{[\s\S]*?"url"\s*:\s*"([^"]+)"'
        ).Groups[1].Value
        if ($url -and (Test-TcpPort $url)) {
            return $config
        }
    }
    return $null
}

function Invoke-Query {
    param([string[]]$Arguments)

    $raw = & pwsh -NoProfile -File $scriptFullPath @Arguments 2>&1
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    if ($LASTEXITCODE -ne 0) {
        throw $text
    }
    return $text | ConvertFrom-Json
}

try {
    $appProcess = Start-Process `
        -FilePath $exe `
        -WorkingDirectory (Split-Path -Parent $exe) `
        -PassThru `
        -WindowStyle Hidden

    $deadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
    $readyConfig = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        $readyConfig = Get-ReadyConfig -Since $startedAt
        if ($readyConfig) {
            break
        }
    }
    if (-not $readyConfig) {
        throw 'The client started, but its MCP endpoint did not become ready.'
    }

    $search = Invoke-Query @('search', '600519', '-Mode', 'local', '-IncludeMeta')
    $realtime = Invoke-Query @('realtime', '600519', '-Fields', '10,55,199112', '-Mode', 'local', '-IncludeMeta')
    $candle = Invoke-Query @('candle', '600519', '-Period', '5', '-Count', '3', '-Mode', 'local', '-IncludeMeta')
    $sectors = Invoke-Query @('sectors', '-Mode', 'local', '-IncludeMeta')
    $watchlist = Invoke-Query @('watchlist', '-Mode', 'local', '-IncludeMeta')

    $realtimeKey = $realtime.data.data.PSObject.Properties.Name | Select-Object -First 1
    $candleKey = $candle.data.data.PSObject.Properties.Name | Select-Object -First 1

    [ordered]@{
        ready = $true
        search = [ordered]@{
            returned = $null -ne $search.data
            source = $search._meta.source
        }
        realtime = [ordered]@{
            security = $realtimeKey
            lastPrice = $realtime.data.data.$realtimeKey.'10'
            name = $realtime.data.data.$realtimeKey.'55'
            source = $realtime._meta.source
        }
        candle = [ordered]@{
            bars = @($candle.data.data.$candleKey).Count
            source = $candle._meta.source
        }
        sectors = [ordered]@{
            count = @($sectors.data).Count
            source = $sectors._meta.source
        }
        watchlist = [ordered]@{
            stockCount = $watchlist.data.stockCount
            source = $watchlist._meta.source
        }
    } | ConvertTo-Json -Depth 10
}
finally {
    Start-Sleep -Milliseconds 300
    $targets = Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.StartTime -ge $startedAt.AddSeconds(-2) -and
            $_.Path -like "$installRoot\*"
        }
    $targets | Stop-Process -Force -ErrorAction SilentlyContinue
}
