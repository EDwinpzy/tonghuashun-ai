[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceFile,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $SourceFile)) {
    throw "Source file not found: $SourceFile"
}

$lines = Get-Content -LiteralPath $SourceFile
$routes = [System.Collections.Generic.List[object]]::new()
$routeIndexes = @(
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*(GET|POST|PUT|DELETE|PATCH)\s+(/\S+)\s*$') {
            $i
        }
    }
)
$routePosition = 0

for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -notmatch '^\s*(GET|POST|PUT|DELETE|PATCH)\s+(/\S+)\s*$') {
        continue
    }

    $method = $Matches[1]
    $path = $Matches[2]
    $routeLine = $i

    $title = ''
    for ($j = $i - 1; $j -ge 0; $j--) {
        if ($lines[$j] -match '^##\s+(.+?)\s*$' -and $lines[$j] -notmatch '^###') {
            $title = $Matches[1].Trim()
            $title = $title -replace '\s*\{#[^}]+\}\s*$', ''
            break
        }
    }

    $pageUrl = ''
    $pageSourceLine = 0
    for ($j = $i - 1; $j -ge 0; $j--) {
        if ($lines[$j] -match '^来源：\s*(\S+)') {
            $pageUrl = $Matches[1]
            $pageSourceLine = $j
            break
        }
    }

    $nextRouteLine = if ($routePosition + 1 -lt $routeIndexes.Count) {
        $routeIndexes[$routePosition + 1]
    }
    else {
        $lines.Count
    }
    $sectionEnd = $nextRouteLine - 1
    $subheadingPattern = '^(请求参数|请求示例|响应示例|响应字段|返回字段|字段说明|参数说明)'
    for ($j = $i + 1; $j -lt $nextRouteLine; $j++) {
        if ($lines[$j] -match '^##\s+(.+?)\s*$' -and $lines[$j] -notmatch '^###') {
            $headingText = $Matches[1].Trim() -replace '\s*\{#[^}]+\}\s*$', ''
            if ($headingText -notmatch $subheadingPattern) {
                $sectionEnd = $j - 1
                break
            }
        }
    }
    $routePosition++

    $introEnd = if ($pageSourceLine -gt 0) {
        [Math]::Min($i, $pageSourceLine + 30)
    }
    else {
        [Math]::Max(0, $i - 40)
    }
    $availabilityText = @(
        $lines[$introEnd..$i]
        $lines[$i..$sectionEnd]
    ) -join "`n"
    $availability = if ($availabilityText -match '不可用于外部调用|仅在同花顺AI客户端内|已经接入同花顺AI客户端|仅供同花顺AI客户端') {
        'client-only'
    }
    else {
        'api-key'
    }

    $parameters = [System.Collections.Generic.List[object]]::new()
    $requestHeading = -1
    for ($j = $i + 1; $j -le $sectionEnd; $j++) {
        if ($lines[$j] -match '^#{2,3}\s*请求参数') {
            $requestHeading = $j
            break
        }
    }

    if ($requestHeading -ge 0) {
        $tableLines = [System.Collections.Generic.List[string]]::new()
        for ($j = $requestHeading + 1; $j -le $sectionEnd; $j++) {
            if ($lines[$j] -match '^#{2,4}\s+') {
                break
            }
            if ($lines[$j].TrimStart().StartsWith('|')) {
                $tableLines.Add($lines[$j])
            }
            elseif ($tableLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$j])) {
                break
            }
        }

        if ($tableLines.Count -ge 2) {
            $headers = @(
                $tableLines[0].Trim().Trim('|') -split '\|' |
                    ForEach-Object { $_.Trim().Trim('`') }
            )
            $nameIndex = [Array]::IndexOf($headers, '参数')
            if ($nameIndex -lt 0) {
                $nameIndex = 0
            }
            $typeIndex = [Array]::IndexOf($headers, '类型')
            $requiredIndex = [Array]::IndexOf($headers, '必需')
            $descriptionIndex = [Array]::IndexOf($headers, '说明')
            $defaultIndex = [Array]::IndexOf($headers, '默认值')
            $locationIndex = [Array]::IndexOf($headers, '位置')

            for ($j = 2; $j -lt $tableLines.Count; $j++) {
                if ($tableLines[$j] -match '^\s*\|[\s:|-]+\|\s*$') {
                    continue
                }
                $cells = @(
                    $tableLines[$j].Trim().Trim('|') -split '\|' |
                        ForEach-Object { $_.Trim().Trim('`') }
                )
                if ($cells.Count -le $nameIndex -or [string]::IsNullOrWhiteSpace($cells[$nameIndex])) {
                    continue
                }
                $parameters.Add([ordered]@{
                    name = $cells[$nameIndex]
                    type = if ($typeIndex -ge 0 -and $cells.Count -gt $typeIndex) { $cells[$typeIndex] } else { '' }
                    required = if (
                        $requiredIndex -ge 0 -and
                        $cells.Count -gt $requiredIndex -and
                        $cells[$requiredIndex] -in @('是', 'true', 'True', '必需')
                    ) { $true } else { $false }
                    location = if ($locationIndex -ge 0 -and $cells.Count -gt $locationIndex) { $cells[$locationIndex] } else { '' }
                    description = if ($descriptionIndex -ge 0 -and $cells.Count -gt $descriptionIndex) { $cells[$descriptionIndex] } else { '' }
                    default = if ($defaultIndex -ge 0 -and $cells.Count -gt $defaultIndex) { $cells[$defaultIndex] } else { '' }
                })
            }
        }
    }

    $required = @($parameters | Where-Object { $_.required } | ForEach-Object { $_.name })
    $optional = @($parameters | Where-Object { -not $_.required } | ForEach-Object { $_.name })

    $routes.Add([ordered]@{
        method = $method
        path = $path
        title = $title
        availability = $availability
        requiredParams = $required
        optionalParams = $optional
        pageUrl = $pageUrl
        sourceLine = $routeLine + 1
        parameters = @($parameters)
    })
}

if ($routes.Count -eq 0) {
    throw 'No REST routes were found in the source document.'
}

$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$jsonPath = Join-Path $OutputDirectory 'cloud-apis.json'
$csvPath = Join-Path $OutputDirectory 'cloud-apis.csv'
$markdownPath = Join-Path $OutputDirectory 'cloud-apis.md'

$routes | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$routes |
    ForEach-Object {
        [pscustomobject]@{
            method = $_.method
            path = $_.path
            title = $_.title
            availability = $_.availability
            requiredParams = $_.requiredParams -join ','
            optionalParams = $_.optionalParams -join ','
            pageUrl = $_.pageUrl
        }
    } |
    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

$markdown = [System.Collections.Generic.List[string]]::new()
$markdown.Add('# 同花顺金融数据（扶摇）REST API 目录')
$markdown.Add('')
$markdown.Add("共 $($routes.Count) 个 GET 端点。请求头使用 ``X-api-key``，Base URL 为 ``https://fuyao.aicubes.cn``。")
$markdown.Add('')
$markdown.Add('| 接口 | 路径 | 必需参数 | 可用性 | 文档 |')
$markdown.Add('|---|---|---|---|---|')
foreach ($route in $routes) {
    $required = if ($route.requiredParams.Count -gt 0) {
        ($route.requiredParams | ForEach-Object { "``$_``" }) -join ', '
    }
    else {
        '-'
    }
    $availability = if ($route.availability -eq 'client-only') { '仅客户端' } else { 'API Key' }
    $markdown.Add("| $($route.title) | ``$($route.path)`` | $required | $availability | [文档]($($route.pageUrl)) |")
}
$markdown | Set-Content -LiteralPath $markdownPath -Encoding utf8

[ordered]@{
    count = $routes.Count
    json = $jsonPath
    csv = $csvPath
    markdown = $markdownPath
} | ConvertTo-Json
