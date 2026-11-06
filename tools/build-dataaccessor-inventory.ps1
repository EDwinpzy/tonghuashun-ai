param(
    [string]$DocsRoot = (Join-Path $PSScriptRoot '..\artifacts\docs'),
    [string]$ToolSchemaOne = (Join-Path $PSScriptRoot '..\artifacts\lumi-tools-1.json'),
    [string]$ToolSchemaTwo = (Join-Path $PSScriptRoot '..\artifacts\lumi-tools-2.json'),
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\inventory')
)

$ErrorActionPreference = 'Stop'

function Get-MarkdownTableRows {
    param(
        [string[]]$Lines,
        [string]$HeaderPrefix
    )

    for ($index = 0; $index -lt ($Lines.Count - 2); $index++) {
        if (
            $Lines[$index].Trim().StartsWith('|') -and
            $Lines[$index] -match [regex]::Escape($HeaderPrefix) -and
            $Lines[$index + 1] -match '^\s*\|(?:\s*:?-+:?\s*\|)+\s*$'
        ) {
            $headerLine = $Lines[$index].Trim().Trim('|')
            $headers = @(
                [regex]::Split($headerLine, '(?<!\\)\|') |
                    ForEach-Object { $_.Trim().Trim('`') -replace '\\\|', '|' }
            )
            $rows = @()
            for ($rowIndex = $index + 2; $rowIndex -lt $Lines.Count; $rowIndex++) {
                if (-not $Lines[$rowIndex].Trim().StartsWith('|')) {
                    break
                }
                $rowLine = $Lines[$rowIndex].Trim().Trim('|')
                $cells = @(
                    [regex]::Split($rowLine, '(?<!\\)\|') |
                        ForEach-Object {
                            $_.Trim().Trim('`') -replace '\\\|', '|' -replace '`', ''
                        }
                )
                $row = [ordered]@{}
                for ($column = 0; $column -lt $headers.Count; $column++) {
                    $row[$headers[$column]] = if ($column -lt $cells.Count) {
                        $cells[$column]
                    }
                    else {
                        ''
                    }
                }
                $rows += [pscustomobject]$row
            }
            return $rows
        }
    }
    return @()
}

function Get-ToolSchemas {
    param([string]$Path)

    $response = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $textPart = $response.result.content |
        Where-Object { $_.type -eq 'text' } |
        Select-Object -First 1
    $payload = $textPart.text | ConvertFrom-Json
    return @($payload.tools)
}

$tools = @(
    Get-ToolSchemas -Path $ToolSchemaOne
    Get-ToolSchemas -Path $ToolSchemaTwo
) | Sort-Object name -Unique

$realtimeFields = Get-MarkdownTableRows `
    -Lines (Get-Content -LiteralPath (Join-Path $DocsRoot 'data-apis__reference__fields__realtimeFields.md')) `
    -HeaderPrefix '字段ID'
$candleFields = Get-MarkdownTableRows `
    -Lines (Get-Content -LiteralPath (Join-Path $DocsRoot 'data-apis__reference__fields__candleFields.md')) `
    -HeaderPrefix '字段ID'
$trendFields = Get-MarkdownTableRows `
    -Lines (Get-Content -LiteralPath (Join-Path $DocsRoot 'data-apis__reference__fields__trendFields.md')) `
    -HeaderPrefix '字段ID'
$tickFields = Get-MarkdownTableRows `
    -Lines (Get-Content -LiteralPath (Join-Path $DocsRoot 'data-apis__reference__fields__tickFields.md')) `
    -HeaderPrefix '字段ID'

$commonSecurityParameter = @{
    name = 'securities'
    type = 'Array<{market:string, code:string}>'
    required = $true
    description = '证券列表；market/code 必须来自 SearchSecuritiesAsync 或可信配置。'
}
$commonFieldsParameter = @{
    name = 'fields'
    type = 'number[]'
    required = $true
    description = '数字 FieldID 数组；不接受字符串字段名。'
}
$commonTimeRangeParameter = @{
    name = 'timeRange'
    type = 'object'
    required = $false
    description = '支持 offset + toLatest、beginTime/endTime、tradeDate。'
}

$requestApis = @(
    [ordered]@{
        name = 'RequestRealtimeDataAsync'
        family = 'realtime'
        description = '通用实时行情；盘中默认入口。'
        mcpTool = 'realtime_query'
        parameters = @(
            $commonSecurityParameter,
            $commonFieldsParameter
        )
        responseShape = '{ [market+code]: { [fieldId:string]: number|string|null } }'
    },
    [ordered]@{
        name = 'RequestIntradayRealtimeDataAsync'
        family = 'realtime'
        description = '盘中实时行情。'
        mcpTool = 'realtime_query（MCP 目录工具未暴露 api 变体参数）'
        parameters = @($commonSecurityParameter, $commonFieldsParameter)
        responseShape = '同 RequestRealtimeDataAsync'
    },
    [ordered]@{
        name = 'RequestPreMarketRealtimeDataAsync'
        family = 'realtime'
        description = '盘前实时行情。'
        mcpTool = 'realtime_query（MCP 目录工具未暴露 api 变体参数）'
        parameters = @($commonSecurityParameter, $commonFieldsParameter)
        responseShape = '同 RequestRealtimeDataAsync'
    },
    [ordered]@{
        name = 'RequestPostMarketRealtimeDataAsync'
        family = 'realtime'
        description = '盘后实时行情。'
        mcpTool = 'realtime_query（MCP 目录工具未暴露 api 变体参数）'
        parameters = @($commonSecurityParameter, $commonFieldsParameter)
        responseShape = '同 RequestRealtimeDataAsync'
    },
    [ordered]@{
        name = 'RequestCandleDataAsync'
        family = 'candle'
        description = 'K 线查询，支持日/周/月和分钟周期。'
        mcpTool = 'candle_query'
        parameters = @(
            @{
                name = 'securities'
                type = 'Array<{market,code}>'
                required = $true
                description = '仅允许一只证券。'
            },
            $commonFieldsParameter,
            @{
                name = 'period'
                type = 'number'
                required = $true
                description = '5=日、11=周、12=月、15=1分、16=5分、17=15分、18=30分、19=60分。'
            },
            @{
                name = 'adjustType'
                type = 'number'
                required = $false
                description = '0=不复权、1=前复权、2=后复权，默认 0。'
            },
            $commonTimeRangeParameter
        )
        responseShape = '{ [market+code]: Array<{ time:number, [fieldId:string]: value }> }'
    },
    [ordered]@{
        name = 'RequestTrendDataAsync'
        family = 'trend'
        description = '通用分时，可指定交易时段和历史交易日。'
        mcpTool = 'trend_query'
        parameters = @(
            $commonSecurityParameter,
            $commonFieldsParameter,
            @{
                name = 'tradeClass'
                type = 'number'
                required = $true
                description = '2=盘前、1=盘中、3=盘后。'
            },
            $commonTimeRangeParameter
        )
        responseShape = '{ [market+code]: Array<{ time:number, [fieldId:string]: number }> }'
    },
    [ordered]@{
        name = 'RequestIntradayTrendDataAsync'
        family = 'trend'
        description = '盘中分时快捷入口。'
        mcpTool = 'trend_query（api 默认值）'
        parameters = @($commonSecurityParameter, $commonFieldsParameter)
        responseShape = '{ [market+code]: Array<{ time:number, [fieldId:string]: number }> }'
    },
    [ordered]@{
        name = 'RequestPreMarketTrendDataAsync'
        family = 'trend'
        description = '盘前分时快捷入口。'
        mcpTool = 'trend_query'
        parameters = @($commonSecurityParameter, $commonFieldsParameter)
        responseShape = '同 RequestIntradayTrendDataAsync'
    },
    [ordered]@{
        name = 'RequestPostMarketTrendDataAsync'
        family = 'trend'
        description = '盘后分时快捷入口。'
        mcpTool = 'trend_query'
        parameters = @($commonSecurityParameter, $commonFieldsParameter)
        responseShape = '同 RequestIntradayTrendDataAsync'
    },
    [ordered]@{
        name = 'RequestCallAuctionDataAsync'
        family = 'trend'
        description = '集合竞价分时。'
        mcpTool = 'trend_query'
        parameters = @($commonSecurityParameter, $commonFieldsParameter)
        responseShape = '同 RequestIntradayTrendDataAsync'
    },
    [ordered]@{
        name = 'RequestTickDataAsync'
        family = 'tick'
        description = '通用逐笔，可指定交易时段。'
        mcpTool = 'tick_query'
        parameters = @(
            $commonSecurityParameter,
            $commonFieldsParameter,
            @{
                name = 'tradeClass'
                type = 'number'
                required = $true
                description = '文档口径：0=盘前、1=盘中、2=盘后。'
            },
            @{
                name = 'count'
                type = 'number'
                required = $false
                description = '最新 N 条，默认 100；与 timeRange 二选一。'
            },
            $commonTimeRangeParameter
        )
        responseShape = '{ [market+code]: Array<{ time:number, [fieldId:string]: number }> }'
    },
    [ordered]@{
        name = 'RequestIntradayTickDataAsync'
        family = 'tick'
        description = '盘中逐笔快捷入口。'
        mcpTool = 'tick_query（api 默认值）'
        parameters = @(
            $commonSecurityParameter,
            $commonFieldsParameter,
            @{
                name = 'count'
                type = 'number'
                required = $false
                description = '最新 N 条，默认 100；与 timeRange 二选一。'
            },
            $commonTimeRangeParameter
        )
        responseShape = '{ [market+code]: Array<{ time:number, [fieldId:string]: number }> }'
    },
    [ordered]@{
        name = 'RequestPreMarketTickDataAsync'
        family = 'tick'
        description = '盘前逐笔快捷入口。'
        mcpTool = 'tick_query'
        parameters = @(
            $commonSecurityParameter,
            $commonFieldsParameter,
            @{
                name = 'count'
                type = 'number'
                required = $false
                description = '最新 N 条，默认 100；与 timeRange 二选一。'
            },
            $commonTimeRangeParameter
        )
        responseShape = '同 RequestIntradayTickDataAsync'
    },
    [ordered]@{
        name = 'RequestPostMarketTickDataAsync'
        family = 'tick'
        description = '盘后逐笔快捷入口。'
        mcpTool = 'tick_query'
        parameters = @(
            $commonSecurityParameter,
            $commonFieldsParameter,
            @{
                name = 'count'
                type = 'number'
                required = $false
                description = '最新 N 条，默认 100；与 timeRange 二选一。'
            },
            $commonTimeRangeParameter
        )
        responseShape = '同 RequestIntradayTickDataAsync'
    },
    [ordered]@{
        name = 'RequestSortDataAsync'
        family = 'sort'
        description = '按板块返回排序后的证券代码列表。'
        mcpTool = 'sort_query'
        parameters = @(
            @{ name = 'block'; type = 'number'; required = $true; description = '板块 ID，如 14=沪深A股、50854=全部A股。' },
            @{ name = 'sortField'; type = 'number'; required = $true; description = '排序 FieldID；涨跌幅用 199112。' },
            @{ name = 'sortOrder'; type = 'number'; required = $true; description = '0=升序、1=降序。' },
            @{ name = 'offset'; type = 'number'; required = $true; description = '分页偏移，从 0 开始。' },
            @{ name = 'count'; type = 'number'; required = $true; description = '分页大小，最大 200。' },
            @{ name = 'excludeBlocks'; type = 'number[]'; required = $false; description = '排除板块，如 55301=ST。' }
        )
        responseShape = '{ total:number, items:Array<{security:string}> }'
    },
    [ordered]@{
        name = 'SearchSecuritiesAsync'
        family = 'search'
        description = '把代码、中文名或拼音解析成 market+code。'
        mcpTool = 'search_securities'
        parameters = @(
            @{ name = 'keyword'; type = 'string'; required = $true; description = '搜索关键词。' },
            @{ name = 'limit'; type = 'number'; required = $false; description = '最大返回数量，默认 20。' }
        )
        responseShape = 'Array<{security,name,code,market}>'
    },
    [ordered]@{
        name = 'SearchBlocksAsync'
        family = 'search'
        description = '按名称模糊搜索客户端市场/行业/概念板块。'
        mcpTool = 'search_blocks'
        parameters = @(
            @{ name = 'keyword'; type = 'string'; required = $true; description = '板块名称关键词。' },
            @{ name = 'limit'; type = 'number'; required = $false; description = '默认 50，范围 1-200。' }
        )
        responseShape = '{ data:Array<{id,idHex,name}>, total:number }'
    },
    [ordered]@{
        name = 'HttpGetAsync'
        family = 'http'
        description = '经客户端管道代理的 GET。DataHub 接口依赖此通道复用登录态。'
        mcpTool = 'http_get'
        parameters = @(
            @{ name = 'url'; type = 'string'; required = $true; description = '完整 GET URL。' },
            @{ name = 'headers'; type = 'object'; required = $false; description = '可选请求头；不要传入或读取 Cookie。' }
        )
        responseShape = '业务方原始响应；MCP 中常为 JSON 字符串。'
    },
    [ordered]@{
        name = 'HttpPostAsync'
        family = 'http'
        description = '经客户端管道代理的 POST。'
        mcpTool = 'http_post'
        parameters = @(
            @{ name = 'url'; type = 'string'; required = $true; description = '完整 POST URL。' },
            @{ name = 'body'; type = 'string'; required = $false; description = '原始请求体。' },
            @{ name = 'headers'; type = 'object'; required = $false; description = '可选请求头。' }
        )
        responseShape = '业务方原始响应。'
    },
    [ordered]@{
        name = 'GetCookie'
        family = 'auth'
        description = '内部登录态辅助接口；仅出现在接口目录，当前 MCP 不提供，也不应提取或输出 Cookie。'
        mcpTool = $null
        parameters = @()
        responseShape = '敏感登录凭据，不在交付范围内。'
        supportedForReuse = $false
    }
)

$subscribeApis = @(
    @{ name = 'SubscribeRealtime'; description = '实时行情差量推送。'; fields = '[6,7,8,9,10,13,55,199112,264648]'; parameters = 'securities, fields'; pushShape = '{ [market+code]: { [changedFieldId:string]: value } }' },
    @{ name = 'SubscribeIntradayCandle'; description = '单证券日内 K 线增量推送。'; fields = '[1,7,8,9,11,13,19]'; parameters = 'securities(单只), fields, period?, adjustType?'; pushShape = '{ [market+code]: Array<row> }' },
    @{ name = 'SubscribeIntradayTrend'; description = '单证券盘中分时增量推送。'; fields = '[1,10,13,19]'; parameters = 'securities(单只), fields'; pushShape = '{ [market+code]: Array<row> }' },
    @{ name = 'SubscribeTrend'; description = '单证券通用分时增量推送。'; fields = '[1,10,13,19]'; parameters = 'securities(单只), fields, tradeClass'; pushShape = '{ [market+code]: Array<row> }' },
    @{ name = 'SubscribeIntradayTick'; description = '单证券盘中逐笔增量推送。'; fields = '[1,10,12,18,49]'; parameters = 'securities(单只), fields'; pushShape = '{ [market+code]: Array<row> }' },
    @{ name = 'SubscribeTick'; description = '单证券通用逐笔增量推送。'; fields = '[1,10,12,18,49]'; parameters = 'securities(单只), fields, tradeClass'; pushShape = '{ [market+code]: Array<row> }' }
)

$marketCodes = @(
    @{ code = 'USHA'; meaning = '沪市 A 股'; example = '600519' },
    @{ code = 'USZA'; meaning = '深市 A 股'; example = '000001' },
    @{ code = 'USBA'; meaning = '北交所 A 股'; example = '430047' },
    @{ code = 'USHI'; meaning = '沪市指数'; example = '1A0001 / 1B0300' },
    @{ code = 'USZI'; meaning = '深市指数'; example = '399001 / 399006' },
    @{ code = 'URFI'; meaning = '同花顺行业/概念指数'; example = '881279 / 885517' },
    @{ code = 'URFA'; meaning = '同花顺三级行业'; example = '884168' },
    @{ code = 'USHJ'; meaning = '沪市基金'; example = '510300' },
    @{ code = 'USZJ'; meaning = '深市基金'; example = '159919' },
    @{ code = 'UHK'; meaning = '港股'; example = '按搜索结果' },
    @{ code = 'UCF'; meaning = '国内商品期货'; example = '按搜索结果' },
    @{ code = 'UFI'; meaning = '全球指数'; example = '按搜索结果' }
)

$inventory = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    application = '同花顺远航版 / Lumi 1.0.69'
    transport = 'Electron preload -> IPC -> Windows named pipe -> 同花顺客户端 PipeServer'
    requestApis = $requestApis
    subscribeApis = $subscribeApis
    mcpTools = $tools
    fieldCatalogs = [ordered]@{
        realtime = $realtimeFields
        candle = $candleFields
        trend = $trendFields
        tick = $tickFields
    }
    marketCodes = $marketCodes
    enums = [ordered]@{
        candlePeriods = [ordered]@{
            '5' = '日K'
            '11' = '周K'
            '12' = '月K'
            '15' = '1分钟'
            '16' = '5分钟'
            '17' = '15分钟'
            '18' = '30分钟'
            '19' = '60分钟'
        }
        trendTradeClass = [ordered]@{ '1' = '盘中'; '2' = '盘前'; '3' = '盘后' }
        tickTradeClass = [ordered]@{ '0' = '盘前'; '1' = '盘中'; '2' = '盘后' }
        subscribeTradeClass = [ordered]@{ '0' = '全部'; '1' = '盘中'; '2' = '盘前'; '3' = '盘后' }
        sortOrder = [ordered]@{ '0' = '升序'; '1' = '降序' }
    }
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$jsonPath = Join-Path $OutputRoot 'dataaccessor-apis.json'
$markdownPath = Join-Path $OutputRoot 'dataaccessor-apis.md'
$fieldsPath = Join-Path $OutputRoot 'dataaccessor-fields.json'
$inventory | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $jsonPath -Encoding utf8
$inventory.fieldCatalogs | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $fieldsPath -Encoding utf8

$markdown = [System.Collections.Generic.List[string]]::new()
$markdown.Add('# Lumi DataAccessor 行情接口清单')
$markdown.Add('')
$markdown.Add('数据链路：`window.dataAccessor` / MCP `tool_execute` → IPC → Windows 命名管道 → 同花顺客户端 `PipeServer`。')
$markdown.Add('')
$markdown.Add('## 请求类 API')
$markdown.Add('')
$markdown.Add('| API | MCP 工具 | 用途 |')
$markdown.Add('|---|---|---|')
foreach ($api in $requestApis) {
    $markdown.Add("| ``$($api.name)`` | $($api.mcpTool) | $($api.description) |")
}
$markdown.Add('')
foreach ($api in $requestApis) {
    $markdown.Add("### $($api.name)")
    $markdown.Add('')
    $markdown.Add($api.description)
    $markdown.Add('')
    if ($api.supportedForReuse -eq $false) {
        $markdown.Add('> 不在复用范围内。')
        $markdown.Add('')
        continue
    }
    if ($api.parameters) {
        $markdown.Add('| 参数 | 类型 | 必填 | 说明 |')
        $markdown.Add('|---|---|---:|---|')
        foreach ($parameter in $api.parameters) {
            $markdown.Add("| ``$($parameter.name)`` | $($parameter.type) | $($parameter.required) | $($parameter.description) |")
        }
        $markdown.Add('')
    }
    $markdown.Add("返回：``$($api.responseShape)``")
    $markdown.Add('')
}
$markdown.Add('## 订阅类 API')
$markdown.Add('')
$markdown.Add('| API | 用途 | 参数 | 推送结构 |')
$markdown.Add('|---|---|---|---|')
foreach ($api in $subscribeApis) {
    $markdown.Add("| ``$($api.name)`` | $($api.description) | $($api.parameters) | ``$($api.pushShape)`` |")
}
$markdown.Add('')
$markdown.Add('## MCP 目录工具')
$markdown.Add('')
$markdown.Add('| 工具 | 用途 |')
$markdown.Add('|---|---|')
foreach ($tool in $tools) {
    $summary = if ($tool.summary) { $tool.summary } else { ($tool.description -split "`n")[0] }
    $markdown.Add("| ``$($tool.name)`` | $summary |")
}
$markdown.Add('')
$markdown.Add('## 市场编码')
$markdown.Add('')
$markdown.Add('| market | 含义 | 示例 |')
$markdown.Add('|---|---|---|')
foreach ($marketCode in $marketCodes) {
    $markdown.Add("| ``$($marketCode.code)`` | $($marketCode.meaning) | $($marketCode.example) |")
}
$markdown.Add('')
$markdown.Add('## 字段目录规模')
$markdown.Add('')
$markdown.Add("| 类型 | 字段数 |")
$markdown.Add('|---|---:|')
foreach ($property in $inventory.fieldCatalogs.GetEnumerator()) {
    $markdown.Add("| $($property.Key) | $(@($property.Value).Count) |")
}
$markdown.Add('')
$markdown | Set-Content -LiteralPath $markdownPath -Encoding utf8

$requestCsvPath = Join-Path $OutputRoot 'dataaccessor-apis.csv'
$requestApis |
    ForEach-Object {
        [pscustomobject][ordered]@{
            name = $_.name
            family = $_.family
            mcpTool = $_.mcpTool
            description = $_.description
            supportedForReuse = if ($_.Contains('supportedForReuse')) {
                $_.supportedForReuse
            }
            else {
                $true
            }
            responseShape = $_.responseShape
        }
    } |
    Export-Csv -LiteralPath $requestCsvPath -NoTypeInformation -Encoding utf8

$subscribeCsvPath = Join-Path $OutputRoot 'dataaccessor-subscribe-apis.csv'
$subscribeApis |
    ForEach-Object {
        [pscustomobject][ordered]@{
            name = $_.name
            description = $_.description
            parameters = $_.parameters
            fields = $_.fields
            pushShape = $_.pushShape
        }
    } |
    Export-Csv -LiteralPath $subscribeCsvPath -NoTypeInformation -Encoding utf8

$fieldsCsvPath = Join-Path $OutputRoot 'dataaccessor-fields.csv'
@(
    foreach ($property in $inventory.fieldCatalogs.GetEnumerator()) {
        foreach ($field in $property.Value) {
            [pscustomobject][ordered]@{
                dataType = $property.Key
                fieldId = $field.'字段ID'
                type = $field.'类型'
                description = $field.'说明'
            }
        }
    }
) | Export-Csv -LiteralPath $fieldsCsvPath -NoTypeInformation -Encoding utf8

Write-Output "Wrote $jsonPath"
Write-Output "Wrote $markdownPath"
Write-Output "Wrote $fieldsPath"
Write-Output "Wrote $requestCsvPath"
Write-Output "Wrote $subscribeCsvPath"
Write-Output "Wrote $fieldsCsvPath"
