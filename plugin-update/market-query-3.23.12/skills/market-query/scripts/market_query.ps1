[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet(
        'catalog',
        'tools',
        'search',
        'blocks',
        'realtime',
        'candle',
        'trend',
        'tick',
        'sort',
        'subscribe',
        'fields',
        'datahub-get',
        'sectors',
        'watchlist',
        'sector',
        'call'
    )]
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

    [ValidateSet(
        'datahub',
        'dataaccessor',
        'subscribe',
        'fields'
    )]
    [string]$Source = 'datahub',

    [ValidateSet('realtime', 'candle', 'trend', 'tick')]
    [string]$DataType,

    [string]$Query,
    [int]$Limit = 20,
    [switch]$All,
    [string]$Tool,
    [string]$ArgumentsJson = '{}',

    [ValidateSet(
        'SubscribeRealtime',
        'SubscribeIntradayCandle',
        'SubscribeIntradayTrend',
        'SubscribeTrend',
        'SubscribeIntradayTick',
        'SubscribeTick'
    )]
    [string]$SubscribeApi,

    [int]$TimeoutMs = 10000,
    [string]$User
)

$ErrorActionPreference = 'Stop'

$helper = Join-Path $PSScriptRoot 'lumi_mcp.ps1'
$referenceRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'references'

function Invoke-LumiTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [hashtable]$Arguments
    )

    $toolArguments = @{
        name = $Name
        args = $Arguments
    } | ConvertTo-Json -Depth 30 -Compress

    $helperArguments = @(
        '-NoProfile',
        '-File', $helper,
        '-Action', 'call-tool',
        '-ToolName', 'tool_execute',
        '-ArgumentsJson', $toolArguments
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

function Split-SecurityTargets {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'A security code, name, or pinyin keyword is required.'
    }

    $targets = @(
        $Value -split '[,，;；]+' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    if ($targets.Count -eq 0) {
        throw 'A security code, name, or pinyin keyword is required.'
    }
    return $targets
}

function Get-LumiSearchHits {
    param($Data)

    if ($null -eq $Data) {
        return @()
    }
    if ($Data.PSObject.Properties.Name -contains 'results') {
        return @(
            $Data.results |
                ForEach-Object { @($_.hits) } |
                Where-Object { $_ }
        )
    }
    if ($Data -is [System.Array]) {
        return @($Data)
    }
    return @($Data)
}

function Resolve-LumiSecurities {
    param([string]$Value)

    $targets = Split-SecurityTargets $Value
    $securities = @()

    foreach ($keyword in $targets) {
        $result = Invoke-LumiTool -Name 'search_securities' -Arguments @{
            keyword = $keyword
            limit = 5
        }
        $hit = Get-LumiSearchHits $result | Select-Object -First 1
        if (-not $hit -or -not $hit.market -or -not $hit.code) {
            throw "No security matched '$keyword'."
        }
        $securities += @{
            market = [string]$hit.market
            code = [string]$hit.code
            keyword = $keyword
            name = [string]$hit.name
            security = [string]$hit.security
        }
    }

    return $securities
}

function Invoke-SecurityQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolName,

        [Parameter(Mandatory = $true)]
        [hashtable]$Arguments,

        [switch]$Single
    )

    $securities = @(Resolve-LumiSecurities $Target)
    if ($Single -and $securities.Count -ne 1) {
        throw "$ToolName only accepts one security per request."
    }

    $Arguments['securities'] = @(
        $securities | ForEach-Object {
            @{
                market = $_.market
                code = $_.code
            }
        }
    )
    $data = Invoke-LumiTool -Name $ToolName -Arguments $Arguments
    return [ordered]@{
        securities = @(
            $securities | ForEach-Object {
                [ordered]@{
                    keyword = $_.keyword
                    name = $_.name
                    security = $_.security
                    market = $_.market
                    code = $_.code
                }
            }
        )
        data = $data
    }
}

function ConvertFrom-ArgumentsJson {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @{}
    }
    try {
        $parsed = $Value | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "ArgumentsJson is not a valid JSON object: $($_.Exception.Message)"
    }
    if ($parsed -isnot [hashtable]) {
        throw 'ArgumentsJson must contain one JSON object.'
    }
    return $parsed
}

function Get-CatalogRows {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('datahub', 'dataaccessor', 'subscribe', 'fields')]
        [string]$CatalogSource
    )

    $file = switch ($CatalogSource) {
        'datahub' { 'datahub-apis.csv' }
        'dataaccessor' { 'dataaccessor-apis.csv' }
        'subscribe' { 'dataaccessor-subscribe-apis.csv' }
        'fields' { 'dataaccessor-fields.csv' }
    }
    return @(
        Import-Csv -LiteralPath (Join-Path $referenceRoot $file) |
            ForEach-Object {
                $row = $_
                $properties = [ordered]@{ catalog = $CatalogSource }
                foreach ($property in $row.PSObject.Properties) {
                    $properties[$property.Name] = $property.Value
                }
                [pscustomobject]$properties
            }
    )
}

function Invoke-DataHubGet {
    param([string]$UrlOrPath)

    if ([string]::IsNullOrWhiteSpace($UrlOrPath)) {
        throw 'datahub-get requires an absolute URL or /api/... path.'
    }

    $url = $UrlOrPath
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
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'datahub.10jqka.com.cn') {
        throw 'datahub-get only permits https://datahub.10jqka.com.cn URLs.'
    }
    if (-not $uri.AbsolutePath.StartsWith('/api/')) {
        throw 'datahub-get only permits /api/ paths on DataHub.'
    }
    if ($uri.UserInfo -or $uri.Fragment) {
        throw 'datahub-get rejects URL credentials and fragments.'
    }
    if ($uri.AbsolutePath -match '/dump/.*/download-url$') {
        throw 'Short-lived market dump download URLs are intentionally blocked.'
    }

    $body = Invoke-LumiTool -Name 'http_get' -Arguments @{ url = $url }
    if ($body -is [string]) {
        try {
            $body = $body | ConvertFrom-Json
        }
        catch {
        }
    }
    return $body
}

$output = switch ($Action) {
    'catalog' {
        $rows = @(Get-CatalogRows -CatalogSource $Source)
        if ($Query) {
            $rows = @(
                $rows |
                    Where-Object {
                        $line = ($_.PSObject.Properties.Value | ForEach-Object { [string]$_ }) -join ' '
                        $line.IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -ge 0
                    }
            )
        }
        $total = $rows.Count
        if (-not $All -and $rows.Count -gt $Limit) {
            $rows = @($rows | Select-Object -First $Limit)
        }
        [ordered]@{
            source = $Source
            count = $rows.Count
            total = $total
            truncated = -not $All -and $total -gt $rows.Count
            items = @($rows)
        }
    }
    'tools' {
        $helperArguments = @(
            '-NoProfile',
            '-File', $helper,
            '-Action', 'list-tools'
        )
        if ($User) {
            $helperArguments += @('-User', $User)
        }
        $processOutput = & pwsh @helperArguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Lumi MCP call failed: $($processOutput -join ' ')"
        }
        $result = ($processOutput -join "`n") | ConvertFrom-Json
        $tools = @(
            $result.result.tools |
                Select-Object -First $Limit |
                ForEach-Object {
                    [ordered]@{
                        name = $_.name
                        description = $_.description
                    }
                }
        )
        [ordered]@{
            count = $tools.Count
            items = $tools
        }
    }
    'search' {
        $targets = Split-SecurityTargets $Target
        $keyword = $targets | Select-Object -First 1
        Invoke-LumiTool -Name 'search_securities' -Arguments @{
            keyword = $keyword
            limit = $Limit
        }
    }
    'blocks' {
        if ([string]::IsNullOrWhiteSpace($Target)) {
            throw 'blocks requires a block-name keyword.'
        }
        Invoke-LumiTool -Name 'search_blocks' -Arguments @{
            keyword = $Target
            limit = $Limit
        }
    }
    'realtime' {
        if (-not $PSBoundParameters.ContainsKey('Fields')) {
            $Fields = '6,7,8,9,10,13,19,55,199112,264648'
        }
        Invoke-SecurityQuery -ToolName 'realtime_query' -Arguments @{
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
            @{
                beginTime = $BeginTime
                endTime = $EndTime
            }
        }
        elseif ($PSBoundParameters.ContainsKey('TradeDate')) {
            @{ tradeDate = $TradeDate }
        }
        else {
            @{
                offset = $Count
                toLatest = $true
            }
        }

        Invoke-SecurityQuery -ToolName 'candle_query' -Arguments @{
            fields = ConvertTo-IdList $Fields
            period = $Period
            adjustType = $AdjustType
            timeRange = $timeRange
        } -Single
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
        elseif ($Api -eq 'RequestTrendDataAsync') {
            $arguments['tradeClass'] = 1
        }
        if ($PSBoundParameters.ContainsKey('TradeDate')) {
            $arguments['tradeDate'] = $TradeDate
        }
        Invoke-SecurityQuery -ToolName 'trend_query' -Arguments $arguments
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
        Invoke-SecurityQuery -ToolName 'tick_query' -Arguments $arguments
    }
    'sort' {
        $arguments = @{
            block = $Block
            sortField = $SortField
            sortOrder = $SortOrder
            offset = $Offset
            count = [Math]::Min($Count, 200)
        }
        if ($ExcludeBlocks) {
            $arguments['excludeBlocks'] = ConvertTo-IdList $ExcludeBlocks
        }
        Invoke-LumiTool -Name 'sort_query' -Arguments $arguments
    }
    'subscribe' {
        if (-not $SubscribeApi) {
            throw 'subscribe requires -SubscribeApi.'
        }
        $parameters = ConvertFrom-ArgumentsJson $ArgumentsJson
        if ($Target) {
            $securities = @(Resolve-LumiSecurities $Target)
            $parameters['securities'] = @(
                $securities | ForEach-Object {
                    @{
                        market = $_.market
                        code = $_.code
                    }
                }
            )
        }
        if ($PSBoundParameters.ContainsKey('Fields')) {
            $parameters['fields'] = ConvertTo-IdList $Fields
        }
        Invoke-LumiTool -Name 'data_subscribe' -Arguments @{
            api = $SubscribeApi
            parameters = $parameters
            timeout_ms = $TimeoutMs
        }
    }
    'fields' {
        $rows = @(Get-CatalogRows -CatalogSource 'fields')
        if ($DataType) {
            $rows = @($rows | Where-Object { $_.dataType -eq $DataType })
        }
        if ($Query) {
            $rows = @(
                $rows |
                    Where-Object {
                        $line = ($_.PSObject.Properties.Value | ForEach-Object { [string]$_ }) -join ' '
                        $line.IndexOf($Query, [StringComparison]::OrdinalIgnoreCase) -ge 0
                    }
            )
        }
        $total = $rows.Count
        if (-not $All -and $rows.Count -gt $Limit) {
            $rows = @($rows | Select-Object -First $Limit)
        }
        [ordered]@{
            count = $rows.Count
            total = $total
            truncated = -not $All -and $total -gt $rows.Count
            items = @($rows)
        }
    }
    'datahub-get' {
        Invoke-DataHubGet -UrlOrPath $Target
    }
    'sectors' {
        Invoke-LumiTool -Name 'manageSector' -Arguments @{
            operation = 'query'
        }
    }
    'watchlist' {
        Invoke-LumiTool -Name 'manageSector' -Arguments @{
            operation = 'query'
            sectorId = '-1'
        }
    }
    'sector' {
        if ([string]::IsNullOrWhiteSpace($Target)) {
            throw 'sector requires a numeric sector ID or group name.'
        }
        $arguments = @{ operation = 'query' }
        if ($Target -match '^\d+$') {
            $arguments['sectorId'] = $Target
        }
        else {
            $arguments['sectorName'] = $Target
        }
        Invoke-LumiTool -Name 'manageSector' -Arguments $arguments
    }
    'call' {
        $readOnlyTools = @(
            'search_securities',
            'search_blocks',
            'search_fields',
            'realtime_query',
            'candle_query',
            'trend_query',
            'tick_query',
            'sort_query',
            'data_subscribe',
            'indicator_query',
            'wencai_query',
            'manageSector',
            'read_doc'
        )
        if ([string]::IsNullOrWhiteSpace($Tool)) {
            throw 'call requires -Tool.'
        }
        if ($Tool -notin $readOnlyTools) {
            throw "Tool '$Tool' is not on the read-only query allowlist."
        }
        $arguments = ConvertFrom-ArgumentsJson $ArgumentsJson
        if ($Tool -eq 'manageSector' -and $arguments['operation'] -ne 'query') {
            throw 'This skill only exposes manageSector with operation=query.'
        }
        Invoke-LumiTool -Name $Tool -Arguments $arguments
    }
}

$output | ConvertTo-Json -Depth 40
