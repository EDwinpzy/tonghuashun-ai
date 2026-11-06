param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\docs')
)

$ErrorActionPreference = 'Stop'

$documentIds = @(
    'data-apis/api-list',
    'data-apis/dataAccessor-api',
    'data-apis/reference/realtime',
    'data-apis/reference/candle',
    'data-apis/reference/trend',
    'data-apis/reference/tick',
    'data-apis/reference/sort',
    'data-apis/reference/search',
    'data-apis/reference/block-search',
    'data-apis/reference/market-code',
    'data-apis/reference/rise-fall-statistics',
    'data-apis/reference/subscribe-realtime',
    'data-apis/reference/subscribe-candle',
    'data-apis/reference/subscribe-trend',
    'data-apis/reference/subscribe-tick',
    'data-apis/reference/fields/realtimeFields',
    'data-apis/reference/fields/candleFields',
    'data-apis/reference/fields/trendFields',
    'data-apis/reference/fields/tickFields',
    'finance-router/lumi-data',
    'mcp-docs/client-script-guide'
)

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$helper = Join-Path $PSScriptRoot 'lumi-mcp.ps1'

foreach ($documentId in $documentIds) {
    $toolArguments = @{
        name = 'read_doc'
        args = @{
            tools = @($documentId)
        }
    } | ConvertTo-Json -Depth 10 -Compress

    $responseJson = & pwsh -NoProfile -File $helper `
        -Action call-tool `
        -ToolName tool_execute `
        -ArgumentsJson $toolArguments

    $response = $responseJson | ConvertFrom-Json
    if ($response.result.isError) {
        throw "Failed to read $documentId"
    }

    $textPart = $response.result.content |
        Where-Object { $_.type -eq 'text' } |
        Select-Object -First 1
    if (-not $textPart) {
        throw "No text content returned for $documentId"
    }

    $fileName = ($documentId -replace '/', '__') + '.md'
    $target = Join-Path $OutputDirectory $fileName
    Set-Content -LiteralPath $target -Value $textPart.text -Encoding utf8
    Write-Output "$documentId -> $target"
}
