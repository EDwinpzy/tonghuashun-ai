param(
    [string]$ScriptPath = '.\plugin-update\market-query-3.23.13\skills\market-query\scripts\market_query.ps1'
)

$ErrorActionPreference = 'Stop'

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

function Wait-Port {
    param([int]$Port, [int]$TimeoutSeconds = 10)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $task = $client.ConnectAsync('127.0.0.1', $Port)
            if ($task.Wait(300) -and $client.Connected) {
                return
            }
        }
        catch {
        }
        finally {
            $client.Dispose()
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Port $Port did not become ready."
}

$python = (Get-Command python -ErrorAction Stop).Source
$scriptFullPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$profileRoot = Join-Path $PSScriptRoot 'mock-profiles'
$profilePath = Join-Path $profileRoot "run-$PID-$([DateTime]::UtcNow.Ticks)"
$configPath = Join-Path $profilePath 'lumi\users\mocktest\agent-sdk\opencode\config\opencode.jsonc'

$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $configPath)
@'
{
  "mcp": {
    "lumi": {
      "url": "http://127.0.0.1:64014/mcp",
      "headers": {
        "Authorization": "Bearer mock-token"
      }
    }
  }
}
'@ | Set-Content -LiteralPath $configPath -Encoding utf8

$oldProfile = $env:USERPROFILE
$oldApiKey = $env:HITHINK_API_KEY
$oldCloudBase = $env:THS_MARKET_CLOUD_BASE_URL
$lumiProcess = $null
$cloudProcess = $null
$outputs = [System.Collections.Generic.List[string]]::new()

function Invoke-MarketQuery {
    param(
        [string[]]$CliArgs,
        [switch]$AllowFailure
    )

    $raw = & pwsh -NoProfile -File $scriptFullPath @CliArgs 2>&1
    $text = ($raw | ForEach-Object { [string]$_ }) -join "`n"
    $outputs.Add($text)
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        throw $text
    }
    if ($AllowFailure) {
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Text = $text
        }
    }
    return $text | ConvertFrom-Json
}

try {
    $lumiProcess = Start-Process `
        -FilePath $python `
        -ArgumentList @('-u', (Join-Path $PSScriptRoot 'mock_lumi_mcp.py')) `
        -PassThru `
        -WindowStyle Hidden
    $cloudProcess = Start-Process `
        -FilePath $python `
        -ArgumentList @('-u', (Join-Path $PSScriptRoot 'mock_fuyao_api.py')) `
        -PassThru `
        -WindowStyle Hidden

    Wait-Port -Port 64014
    Wait-Port -Port 64015

    $env:USERPROFILE = $profilePath
    $env:HITHINK_API_KEY = 'mock-secret-key'
    $env:THS_MARKET_CLOUD_BASE_URL = 'http://127.0.0.1:64015'

    $checks = [System.Collections.Generic.List[object]]::new()

    $status = Invoke-MarketQuery @('status', '-IncludeMeta')
    Assert-True ($status.data.local.configured) 'local status should be configured'
    Assert-True ($status.data.cloud.configured) 'cloud status should be configured'
    $checks.Add([pscustomobject]@{ Action = 'status'; Result = 'both' })

    $search = Invoke-MarketQuery @('search', '600519', '-User', 'mocktest')
    Assert-True ($search.results[0].hits[0].code -eq '600519') 'local search failed'
    $checks.Add([pscustomobject]@{ Action = 'search/local'; Result = '600519' })

    $blocks = Invoke-MarketQuery @('blocks', '沪深', '-User', 'mocktest')
    Assert-True ($blocks.total -eq 1) 'local blocks failed'
    $checks.Add([pscustomobject]@{ Action = 'blocks/local'; Result = '1' })

    $realtime = Invoke-MarketQuery @('realtime', '600519', '-Fields', '10,55,199112', '-User', 'mocktest')
    Assert-True ($realtime.securities.Count -eq 1) 'local realtime failed'
    $checks.Add([pscustomobject]@{ Action = 'realtime/local'; Result = '1' })

    $candle = Invoke-MarketQuery @('candle', '600519', '-Period', '5', '-Count', '2', '-User', 'mocktest')
    $candleKey = $candle.data.PSObject.Properties.Name | Select-Object -First 1
    Assert-True (@($candle.data.$candleKey).Count -ge 1) 'local candle failed'
    $checks.Add([pscustomobject]@{ Action = 'candle/local'; Result = '2' })

    $trend = Invoke-MarketQuery @('trend', '600519', '-User', 'mocktest')
    Assert-True ($null -ne $trend.data) 'local trend failed'
    $checks.Add([pscustomobject]@{ Action = 'trend/local'; Result = 'ok' })

    $tick = Invoke-MarketQuery @('tick', '600519', '-Count', '5', '-User', 'mocktest')
    Assert-True ($null -ne $tick.data) 'local tick failed'
    $checks.Add([pscustomobject]@{ Action = 'tick/local'; Result = 'ok' })

    $sort = Invoke-MarketQuery @('sort', '-Block', '14', '-Count', '5', '-User', 'mocktest')
    Assert-True ($sort.total -eq 1) 'local sort failed'
    $checks.Add([pscustomobject]@{ Action = 'sort/local'; Result = '1' })

    $datahub = Invoke-MarketQuery @(
        'datahub-get',
        '/api/a-share/prices/snapshot?thscodes=600519.SH',
        '-User',
        'mocktest'
    )
    Assert-True ($datahub.code -eq 0) 'local datahub-get failed'
    $checks.Add([pscustomobject]@{ Action = 'datahub/local'; Result = '0' })

    $sectors = Invoke-MarketQuery @('sectors', '-User', 'mocktest')
    Assert-True (@($sectors).Count -eq 2) 'local sectors failed'
    $checks.Add([pscustomobject]@{ Action = 'sectors/local'; Result = '2' })

    $watchlist = Invoke-MarketQuery @('watchlist', '-User', 'mocktest')
    Assert-True ($watchlist.stockCount -eq 2) 'local watchlist failed'
    $checks.Add([pscustomobject]@{ Action = 'watchlist/local'; Result = '2' })

    $sector = Invoke-MarketQuery @('sector', '-Target', '234', '-User', 'mocktest')
    Assert-True ($sector.sectorName -eq '医药') 'local sector failed'
    $checks.Add([pscustomobject]@{ Action = 'sector/local'; Result = '医药' })

    $subscribe = Invoke-MarketQuery @(
        'subscribe',
        '-SubscribeApi',
        'SubscribeRealtime',
        '-Target',
        '600519',
        '-User',
        'mocktest'
    )
    Assert-True ($null -ne $subscribe.first_frame) 'local subscribe failed'
    $checks.Add([pscustomobject]@{ Action = 'subscribe/local'; Result = 'ok' })

    $tools = Invoke-MarketQuery @('tools', '-Limit', '3', '-User', 'mocktest')
    Assert-True ($tools.count -eq 3) 'local tools failed'
    $checks.Add([pscustomobject]@{ Action = 'tools/local'; Result = '3' })

    $wencai = Invoke-MarketQuery @(
        'call',
        '-Tool',
        'wencai_query',
        '-ArgumentsJson',
        '{"skillId":"hithink-market-query","query":"今日涨幅前20","limit":20}',
        '-User',
        'mocktest'
    )
    Assert-True ($wencai.row_count -eq 1) 'local wencai failed'
    $checks.Add([pscustomobject]@{ Action = 'call/local'; Result = '1' })

    foreach ($catalogSpec in @(
        @{ Source = 'datahub'; Expected = 118 },
        @{ Source = 'dataaccessor'; Expected = 20 },
        @{ Source = 'subscribe'; Expected = 6 },
        @{ Source = 'fields'; Expected = 276 },
        @{ Source = 'cloud'; Expected = 120 }
    )) {
        $catalog = Invoke-MarketQuery @('catalog', '-Source', $catalogSpec.Source, '-All')
        Assert-True ($catalog.total -eq $catalogSpec.Expected) "catalog $($catalogSpec.Source) failed"
        $checks.Add([pscustomobject]@{
            Action = "catalog/$($catalogSpec.Source)"
            Result = [string]$catalog.total
        })
    }

    $cloudSearch = Invoke-MarketQuery @('search', '600519', '-Mode', 'cloud')
    Assert-True ($cloudSearch.items[0].thscode -eq '600519.SH') 'cloud search failed'
    $checks.Add([pscustomobject]@{ Action = 'search/cloud'; Result = '600519.SH' })

    $cloudRealtime = Invoke-MarketQuery @('realtime', '600519', '-Mode', 'cloud')
    Assert-True ($cloudRealtime.data.USHA600519.'10' -eq 1277.8) 'cloud realtime price failed'
    Assert-True ($cloudRealtime.data.USHA600519.'55' -eq '贵州茅台') 'cloud realtime name failed'
    $checks.Add([pscustomobject]@{ Action = 'realtime/cloud'; Result = '1277.8' })

    $cloudCandle = Invoke-MarketQuery @(
        'candle',
        '600519',
        '-Mode',
        'cloud',
        '-Period',
        '5',
        '-Count',
        '2'
    )
    $cloudCandleKey = $cloudCandle.data.PSObject.Properties.Name | Select-Object -First 1
    Assert-True (@($cloudCandle.data.$cloudCandleKey).Count -eq 2) 'cloud candle failed'
    Assert-True ($cloudCandle.data.$cloudCandleKey[1].'11' -eq 1277.8) 'cloud candle close failed'
    $checks.Add([pscustomobject]@{ Action = 'candle/cloud'; Result = '2' })

    $cloudBlocks = Invoke-MarketQuery @('blocks', '光伏', '-Mode', 'cloud')
    Assert-True ($cloudBlocks.items[0].thscode -eq '886042.TI') 'cloud blocks failed'
    $checks.Add([pscustomobject]@{ Action = 'blocks/cloud'; Result = '886042.TI' })

    $cloudSector = Invoke-MarketQuery @('sector', '-Target', '886042.TI', '-Mode', 'cloud')
    Assert-True (@($cloudSector.members).Count -eq 2) 'cloud sector failed'
    $checks.Add([pscustomobject]@{ Action = 'sector/cloud'; Result = '2' })

    $cloudDatahub = Invoke-MarketQuery @(
        'datahub-get',
        '/api/a-share/prices/snapshot?thscodes=600519.SH',
        '-Mode',
        'cloud'
    )
    Assert-True ($cloudDatahub.code -eq 0) 'cloud datahub-get failed'
    $checks.Add([pscustomobject]@{ Action = 'datahub/cloud'; Result = '0' })

    $cloudGet = Invoke-MarketQuery @(
        'cloud-get',
        '/api/mock/echo',
        '-ArgumentsJson',
        '{"thscodes":"600519.SH","limit":2}',
        '-Mode',
        'cloud'
    )
    Assert-True ($cloudGet.data.query.thscodes[0] -eq '600519.SH') 'cloud-get query binding failed'
    $checks.Add([pscustomobject]@{ Action = 'cloud-get'; Result = 'ok' })

    $autoLocal = Invoke-MarketQuery @(
        'search',
        '600519',
        '-User',
        'mocktest',
        '-IncludeMeta'
    )
    Assert-True ($autoLocal._meta.source -eq 'local') 'auto should prefer local when available'

    $autoFallback = Invoke-MarketQuery @(
        'search',
        '600519',
        '-User',
        'missing-user',
        '-IncludeMeta'
    )
    Assert-True ($autoFallback._meta.source -eq 'cloud') 'auto should fall back to cloud'
    Assert-True (
        @($autoFallback._meta.attempts | Where-Object { $_.source -eq 'local' -and -not $_.success }).Count -eq 1
    ) 'fallback should record the failed local attempt'
    $checks.Add([pscustomobject]@{ Action = 'auto/fallback'; Result = 'cloud' })

    $autoBusinessFallback = Invoke-MarketQuery @(
        'datahub-get',
        '/api/mock/failover',
        '-User',
        'mocktest',
        '-IncludeMeta'
    )
    Assert-True ($autoBusinessFallback._meta.source -eq 'cloud') 'auto should fall back on a local business error'
    Assert-True ($autoBusinessFallback.data.code -eq 0) 'business-error fallback should return cloud data'
    $checks.Add([pscustomobject]@{ Action = 'auto/business-fallback'; Result = 'cloud' })

    $unsupported = Invoke-MarketQuery @('watchlist', '-Mode', 'cloud') -AllowFailure
    Assert-True ($unsupported.ExitCode -ne 0) 'cloud watchlist should fail'
    Assert-True ($unsupported.Text -match 'not available through the Fuyao cloud API') 'cloud watchlist error should be explicit'
    $checks.Add([pscustomobject]@{ Action = 'watchlist/cloud'; Result = 'rejected' })

    $allOutput = $outputs -join "`n"
    Assert-True ($allOutput -notmatch [regex]::Escape('mock-secret-key')) 'API key leaked to output'
    $checks.Add([pscustomobject]@{ Action = 'secret-scan'; Result = 'clean' })

    $checks | Format-Table -AutoSize
}
finally {
    if ($lumiProcess -and -not $lumiProcess.HasExited) {
        Stop-Process -Id $lumiProcess.Id -Force -ErrorAction SilentlyContinue
    }
    if ($cloudProcess -and -not $cloudProcess.HasExited) {
        Stop-Process -Id $cloudProcess.Id -Force -ErrorAction SilentlyContinue
    }

    $env:USERPROFILE = $oldProfile
    $env:HITHINK_API_KEY = $oldApiKey
    $env:THS_MARKET_CLOUD_BASE_URL = $oldCloudBase

    $profileRootFull = [System.IO.Path]::GetFullPath($profileRoot).TrimEnd('\') + '\'
    $profileFull = [System.IO.Path]::GetFullPath($profilePath)
    if (
        $profileFull.StartsWith($profileRootFull, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $profileFull)
    ) {
        Remove-Item -LiteralPath $profileFull -Recurse -Force
    }
}
