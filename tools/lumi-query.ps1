<#
.SYNOPSIS
通过本机同花顺远航版/Lumi 的 MCP 桥查询行情。

.EXAMPLE
pwsh -NoProfile -File .\tools\lumi-query.ps1 search 贵州茅台

.EXAMPLE
pwsh -NoProfile -File .\tools\lumi-query.ps1 realtime 600519 -Fields 10,55,199112

.EXAMPLE
pwsh -NoProfile -File .\tools\lumi-query.ps1 candle 600519 -Period 5 -Count 20 -AdjustType 1

.EXAMPLE
pwsh -NoProfile -File .\tools\lumi-query.ps1 datahub-get '/api/a-share/prices/snapshot?thscodes=600519.SH,000001.SZ'
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('search', 'blocks', 'realtime', 'candle', 'trend', 'tick', 'sort', 'datahub-get')]
    [string]$Action,

    [Parameter(Position = 1)]
    [string]$Target,

    [string]$Fields,
    [int]$Period = 5,
    [int]$AdjustType = 0,
    [int]$Count = 60,
    [int]$Offset = 0,
    [long]$BeginTime,
    [long]$EndTime,
    [long]$TradeDate,
    [int]$TradeClass,
    [string]$Api,
    [int]$Block = 14,
    [int]$SortField = 199112,
    [int]$SortOrder = 1,
    [string]$ExcludeBlocks,
    [string]$User
)

$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'lumi-mcp.ps1'

function Invoke-LumiTool {
    param(
        [string]$Name,
        [hashtable]$Arguments
    )

    $argumentsJson = @{
        name = $Name
        args = $Arguments
    } | ConvertTo-Json -Depth 30 -Compress
    $helperArguments = @(
        '-NoProfile',
        '-File', $helper,
        '-Action', 'call-tool',
        '-ToolName', 'tool_execute',
        '-ArgumentsJson', $argumentsJson
    )
    if ($User) {
        $helperArguments += @('-User', $User)
    }

    $output = & pwsh @helperArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Lumi MCP call failed: $($output -join ' ')"
    }

    $envelope = ($output -join "`n") | ConvertFrom-Json
    if ($envelope.error) {
        throw ($envelope.error | ConvertTo-Json -Depth 8 -Compress)
    }
    if ($envelope.result.isError) {
        throw "Lumi tool '$Name' returned an error."
    }

    $textPart = $envelope.result.content |
        Where-Object { $_.type -eq 'text' } |
        Select-Object -First 1
    if (-not $textPart) {
        throw "Lumi tool '$Name' returned no text payload."
    }

    $result = $textPart.text | ConvertFrom-Json
    if (-not $result.success) {
        $message = if ($result.error) {
            [string]$result.error
        }
        else {
            'unknown tool error'
        }
        throw "Lumi tool '$Name' failed: $message"
    }

    $payload = $result.data
    if (
        $null -ne $payload -and
        $payload -isnot [System.Array] -and
        $payload.PSObject.Properties.Name -contains 'success'
    ) {
        if (-not $payload.success) {
            $message = if ($payload.error) {
                [string]$payload.error
            }
            else {
                'unknown data error'
            }
            throw "Lumi tool '$Name' failed: $message"
        }
        if ($payload.PSObject.Properties.Name -contains 'data') {
            return $payload.data
        }
    }

    return $payload
}

function ConvertTo-IdList {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }
    return @(
        $Value -split '[,\s;]+' |
            Where-Object { $_ } |
            ForEach-Object { [int]$_ }
    )
}

function Resolve-LumiSecurity {
    param([string]$Keyword)

    if ([string]::IsNullOrWhiteSpace($Keyword)) {
        throw 'A security code, name, or pinyin keyword is required.'
    }

    $result = Invoke-LumiTool -Name 'search_securities' -Arguments @{
        keyword = $Keyword
        limit = 5
    }
    $data = $result
    $hits = if ($data.results) {
        @($data.results | ForEach-Object { $_.hits } | Where-Object { $_ })
    }
    elseif ($data -is [array]) {
        @($data)
    }
    else {
        @($data)
    }
    $hit = $hits | Select-Object -First 1
    if (-not $hit -or -not $hit.market -or -not $hit.code) {
        throw "No security matched '$Keyword'."
    }
    return $hit
}

function Invoke-SecurityQuery {
    param(
        [string]$Tool,
        [hashtable]$Arguments
    )

    $security = Resolve-LumiSecurity $Target
    $Arguments['securities'] = @(
        @{
            market = [string]$security.market
            code = [string]$security.code
        }
    )
    $data = Invoke-LumiTool -Name $Tool -Arguments $Arguments
    return [ordered]@{
        security = $security
        data = $data
    }
}

$output = switch ($Action) {
    'search' {
        $result = Invoke-LumiTool -Name 'search_securities' -Arguments @{
            keyword = $Target
            limit = 10
        }
        $result
    }
    'blocks' {
        $result = Invoke-LumiTool -Name 'search_blocks' -Arguments @{
            keyword = $Target
            limit = 50
        }
        $result
    }
    'realtime' {
        if (-not $PSBoundParameters.ContainsKey('Fields')) {
            $Fields = '6,7,8,9,10,13,19,55,199112,264648'
        }
        Invoke-SecurityQuery -Tool 'realtime_query' -Arguments @{
            fields = ConvertTo-IdList $Fields
        }
    }
    'candle' {
        if (-not $PSBoundParameters.ContainsKey('Fields')) {
            $Fields = '1,7,8,9,11,13,19'
        }
        $timeRange = if ($PSBoundParameters.ContainsKey('BeginTime') -or $PSBoundParameters.ContainsKey('EndTime')) {
            if (-not $PSBoundParameters.ContainsKey('BeginTime') -or -not $PSBoundParameters.ContainsKey('EndTime')) {
                throw 'candle requires both -BeginTime and -EndTime, or neither.'
            }
            @{ beginTime = $BeginTime; endTime = $EndTime }
        }
        elseif ($PSBoundParameters.ContainsKey('TradeDate')) {
            @{ tradeDate = $TradeDate }
        }
        else {
            @{ offset = $Count; toLatest = $true }
        }

        Invoke-SecurityQuery -Tool 'candle_query' -Arguments @{
            fields = ConvertTo-IdList $Fields
            period = $Period
            adjustType = $AdjustType
            timeRange = $timeRange
        }
    }
    'trend' {
        if (-not $PSBoundParameters.ContainsKey('Fields')) {
            $Fields = '1,10,13,19'
        }
        $arguments = @{
            fields = ConvertTo-IdList $Fields
        }
        if ($Api) {
            $arguments['api'] = $Api
        }
        if ($PSBoundParameters.ContainsKey('TradeClass')) {
            $arguments['tradeClass'] = $TradeClass
        }
        if ($PSBoundParameters.ContainsKey('TradeDate')) {
            $arguments['tradeDate'] = $TradeDate
        }
        Invoke-SecurityQuery -Tool 'trend_query' -Arguments $arguments
    }
    'tick' {
        if (-not $PSBoundParameters.ContainsKey('Fields')) {
            $Fields = '1,10,12,18,49'
        }
        $arguments = @{
            fields = ConvertTo-IdList $Fields
            count = $Count
        }
        if ($Api) {
            $arguments['api'] = $Api
        }
        Invoke-SecurityQuery -Tool 'tick_query' -Arguments $arguments
    }
    'sort' {
        $arguments = @{
            block = $Block
            sortField = $SortField
            sortOrder = $SortOrder
            offset = $Offset
            count = $Count
        }
        if ($ExcludeBlocks) {
            $arguments['excludeBlocks'] = ConvertTo-IdList $ExcludeBlocks
        }
        $result = Invoke-LumiTool -Name 'sort_query' -Arguments $arguments
        $result
    }
    'datahub-get' {
        $url = $Target
        if ($url -match '^/api/') {
            $url = "https://datahub.10jqka.com.cn$url"
        }
        elseif ($url -match '^api/') {
            $url = "https://datahub.10jqka.com.cn/$url"
        }

        $uri = $null
        if (-not [uri]::TryCreate($url, [UriKind]::Absolute, [ref]$uri)) {
            throw 'datahub-get requires an absolute URL or /api/... path.'
        }
        if ($uri.Host -ne 'datahub.10jqka.com.cn' -or $uri.Scheme -ne 'https') {
            throw 'datahub-get only permits https://datahub.10jqka.com.cn URLs.'
        }
        if (-not $uri.AbsolutePath.StartsWith('/api/')) {
            throw 'datahub-get only permits /api/ paths on DataHub.'
        }

        $body = Invoke-LumiTool -Name 'http_get' -Arguments @{ url = $url }
        if ($body -is [string]) {
            try {
                $body = $body | ConvertFrom-Json
            }
            catch {
            }
        }
        $body
    }
}

$output | ConvertTo-Json -Depth 40
