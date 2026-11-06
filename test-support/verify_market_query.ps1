param(
    [string]$ScriptPath = ".\plugin-update\market-query-3.23.12\skills\market-query\scripts\market_query.ps1",
    [string]$TestUser = "user_793297329"
)

$ErrorActionPreference = "Stop"

function Invoke-MarketQuery {
    param([string[]]$CliArgs)

    $effectiveArgs = @($CliArgs)
    if ($TestUser) {
        $effectiveArgs += @("-User", $TestUser)
    }
    $raw = & pwsh -NoProfile -File $ScriptPath @effectiveArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (($raw | ForEach-Object { [string]$_ }) -join "`n")
    }
    return (($raw -join "`n") | ConvertFrom-Json)
}

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

$checks = [System.Collections.Generic.List[object]]::new()

$search = Invoke-MarketQuery @("search", "600519")
Assert-True ($search.results[0].hits[0].code -eq "600519") "search failed"
$checks.Add([pscustomobject]@{ Action = "search"; Result = $search.results[0].hits[0].security })

$blocks = Invoke-MarketQuery @("blocks", "沪深")
Assert-True ($blocks.total -eq 1) "blocks failed"
$checks.Add([pscustomobject]@{ Action = "blocks"; Result = $blocks.data[0].name })

$realtime = Invoke-MarketQuery @("realtime", "600519", "-Fields", "10,55,199112")
Assert-True ($realtime.securities.Count -eq 1) "realtime failed"
$checks.Add([pscustomobject]@{ Action = "realtime"; Result = $realtime.securities[0].security })

$candle = Invoke-MarketQuery @("candle", "600519", "-Period", "5", "-Count", "2")
$candleKey = $candle.data.PSObject.Properties.Name | Select-Object -First 1
Assert-True (@($candle.data.$candleKey).Count -ge 1) "candle failed"
$checks.Add([pscustomobject]@{ Action = "candle"; Result = @($candle.data.$candleKey).Count })

$trend = Invoke-MarketQuery @("trend", "600519")
$trendKey = $trend.data.PSObject.Properties.Name | Select-Object -First 1
Assert-True (@($trend.data.$trendKey).Count -ge 1) "trend failed"
$checks.Add([pscustomobject]@{ Action = "trend"; Result = @($trend.data.$trendKey).Count })

$tick = Invoke-MarketQuery @("tick", "600519", "-Count", "5")
$tickKey = $tick.data.PSObject.Properties.Name | Select-Object -First 1
Assert-True (@($tick.data.$tickKey).Count -ge 1) "tick failed"
$checks.Add([pscustomobject]@{ Action = "tick"; Result = @($tick.data.$tickKey).Count })

$sort = Invoke-MarketQuery @("sort", "-Block", "14", "-SortField", "199112", "-SortOrder", "1", "-Count", "5")
Assert-True ($sort.total -eq 1) "sort failed"
$checks.Add([pscustomobject]@{ Action = "sort"; Result = $sort.items[0].security })

$datahub = Invoke-MarketQuery @("datahub-get", "/api/a-share/prices/snapshot?thscodes=600519.SH")
Assert-True ($datahub.code -eq 0) "datahub-get failed"
$checks.Add([pscustomobject]@{ Action = "datahub-get"; Result = $datahub.message })

$sectors = Invoke-MarketQuery @("sectors")
Assert-True (@($sectors).Count -eq 2) "sectors failed"
$checks.Add([pscustomobject]@{ Action = "sectors"; Result = @($sectors).Count })

$watchlist = Invoke-MarketQuery @("watchlist")
Assert-True ($watchlist.stockCount -eq 2) "watchlist failed"
$checks.Add([pscustomobject]@{ Action = "watchlist"; Result = $watchlist.stockCount })

$sector = Invoke-MarketQuery @("sector", "-Target", "234")
Assert-True ($sector.sectorName -eq "医药") "sector failed"
$checks.Add([pscustomobject]@{ Action = "sector"; Result = $sector.sectorName })

$subscribe = Invoke-MarketQuery @(
    "subscribe",
    "-SubscribeApi",
    "SubscribeRealtime",
    "-Target",
    "600519",
    "-Fields",
    "10,55"
)
Assert-True ($null -ne $subscribe.first_frame) "subscribe failed"
$checks.Add([pscustomobject]@{ Action = "subscribe"; Result = "first_frame" })

$tools = Invoke-MarketQuery @("tools", "-Limit", "3")
Assert-True ($tools.count -eq 3) "tools failed"
$checks.Add([pscustomobject]@{ Action = "tools"; Result = $tools.count })

$wencai = Invoke-MarketQuery @(
    "call",
    "-Tool",
    "wencai_query",
    "-ArgumentsJson",
    '{"skillId":"hithink-market-query","query":"今日涨幅前20","limit":20}'
)
Assert-True ($wencai.row_count -eq 1) "wencai call failed"
$checks.Add([pscustomobject]@{ Action = "call/wencai"; Result = $wencai.row_count })

$indicator = Invoke-MarketQuery @(
    "call",
    "-Tool",
    "indicator_query",
    "-ArgumentsJson",
    '{"securities":[{"market":"USHA","code":"600519"}],"indicators":["MA20"],"mode":"latest"}'
)
Assert-True ($null -ne $indicator) "indicator call failed"
$checks.Add([pscustomobject]@{ Action = "call/indicator"; Result = "ok" })

foreach ($catalogSpec in @(
    @{ Source = "datahub"; Expected = 118 },
    @{ Source = "dataaccessor"; Expected = 20 },
    @{ Source = "subscribe"; Expected = 6 },
    @{ Source = "fields"; Expected = 276 }
)) {
    $catalog = Invoke-MarketQuery @("catalog", "-Source", $catalogSpec.Source, "-All")
    Assert-True ($catalog.total -eq $catalogSpec.Expected) "catalog $($catalogSpec.Source) failed"
    $checks.Add([pscustomobject]@{ Action = "catalog/$($catalogSpec.Source)"; Result = $catalog.total })
}

$checks | Format-Table -AutoSize
