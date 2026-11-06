param(
    [switch]$Live
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function Assert-Condition {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$datahubPath = Join-Path $root 'inventory\datahub-apis.json'
$datahub = Get-Content -LiteralPath $datahubPath -Raw | ConvertFrom-Json
$endpoints = @($datahub.endpoints)

Assert-Condition ($datahub.contractCount -eq 118) 'DataHub contractCount is not 118.'
Assert-Condition ($endpoints.Count -eq 118) 'DataHub endpoint count is not 118.'
Assert-Condition (
    @($endpoints | Group-Object path | Where-Object Count -gt 1).Count -eq 0
) 'DataHub contains duplicate paths.'
Assert-Condition (
    @($endpoints | Where-Object { -not $_.title -or -not $_.description }).Count -eq 0
) 'DataHub contains an empty title or description.'
Assert-Condition (
    (@($datahub.categories | Measure-Object count -Sum).Sum) -eq 118
) 'DataHub category counts do not sum to 118.'

$verified = @($endpoints | Where-Object runtimeStatus -eq 'verified_success').Count
$skipped = @($endpoints | Where-Object runtimeStatus -eq 'skipped_sensitive_dump').Count
Assert-Condition ($verified -ge 100) 'Fewer than 100 DataHub contracts have runtime success evidence.'
Assert-Condition ($skipped -eq 3) 'Expected exactly three skipped sensitive dump contracts.'

$dataAccessorPath = Join-Path $root 'inventory\dataaccessor-apis.json'
$dataAccessor = Get-Content -LiteralPath $dataAccessorPath -Raw | ConvertFrom-Json
Assert-Condition (@($dataAccessor.requestApis).Count -eq 20) 'DataAccessor request API count is not 20.'
Assert-Condition (@($dataAccessor.subscribeApis).Count -eq 6) 'DataAccessor subscription API count is not 6.'
Assert-Condition (@($dataAccessor.mcpTools).Count -eq 15) 'MCP tool count is not 15.'
$fieldCount = @(
    $dataAccessor.fieldCatalogs.realtime
    $dataAccessor.fieldCatalogs.candle
    $dataAccessor.fieldCatalogs.trend
    $dataAccessor.fieldCatalogs.tick
).Count
Assert-Condition ($fieldCount -eq 276) 'DataAccessor field count is not 276.'
Assert-Condition (
    @($dataAccessor.requestApis | Where-Object { $_.name -eq 'GetCookie' -and $_.supportedForReuse -ne $false }).Count -eq 0
) 'GetCookie must be explicitly excluded from reuse.'

Write-Output "static=ok datahub=$($endpoints.Count) verified=$verified accessor=20 subscribe=6 fields=$fieldCount"

if (-not $Live) {
    Write-Output 'live=skipped'
    exit 0
}

$query = Join-Path $PSScriptRoot 'lumi-query.ps1'

function Invoke-Query {
    param([string[]]$Arguments)

    $output = & pwsh -NoProfile -File $query @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Query failed: $($output -join ' ')"
    }
    return (($output -join "`n") | ConvertFrom-Json)
}

$search = Invoke-Query @('search', '600519')
Assert-Condition ($search.market -eq 'USHA' -and $search.code -eq '600519') 'Search did not resolve 600519.'

$realtime = Invoke-Query @('realtime', '600519', '-Fields', '10,55,199112')
Assert-Condition ($null -ne $realtime.data.USHA600519) 'Realtime query returned no USHA600519 data.'

$candle = Invoke-Query @('candle', '600519', '-Period', '5', '-Count', '2')
Assert-Condition (@($candle.data.USHA600519).Count -ge 2) 'Candle query returned too few rows.'

$sort = Invoke-Query @('sort', '-Block', '14', '-SortField', '199112', '-SortOrder', '1', '-Count', '2')
Assert-Condition ($sort.total -gt 0 -and @($sort.items).Count -ge 1) 'Sort query returned no rows.'

$snapshot = Invoke-Query @('datahub-get', '/api/a-share/prices/snapshot?thscodes=600519.SH')
Assert-Condition ($snapshot.code -eq 0 -and @($snapshot.data.item).Count -ge 1) 'DataHub snapshot query failed.'

Write-Output 'live=ok search=ok realtime=ok candle=ok sort=ok datahub-get=ok'
