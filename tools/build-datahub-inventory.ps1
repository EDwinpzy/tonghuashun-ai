param(
    [string]$ApiRoot = 'C:\应用\同花顺AI版\同花顺远航版\lumi\resources\built-in-skills\datahub-lumi\snapshot\api',
    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\inventory'),
    [string]$RuntimeMatrixPath = (Join-Path $PSScriptRoot '..\artifacts\datahub-runtime-matrix-merged.json')
)

$ErrorActionPreference = 'Stop'

function Get-CleanCell {
    param([string]$Value)

    return (
        $Value.Trim() `
            -replace '^`(.*)`$', '$1' `
            -replace '`', '' `
            -replace '\[([^\]]+)\]\([^\)]+\)', '$1' `
            -replace '\\\|', '|'
    )
}

function Get-CleanProse {
    param([string]$Value)

    $clean = Get-CleanCell $Value
    $clean = $clean -replace '<a\s+id="[^"]*"\s*>\s*</a>', ' '
    $clean = $clean -replace '(?s)\s*#{2,6}\s*(请求参数|请求示例|响应示例|返回字段|响应字段|字段说明|接口)\b.*$', ''
    $clean = $clean -replace '\s*GET\s+(?:https?://\S+|/api/\S+).*$', ''
    $clean = $clean -replace '\s+', ' '
    return $clean.Trim()
}

function Get-RuntimeStatus {
    param($Result)

    if (-not $Result) {
        return 'not_probed'
    }
    if ($Result.status -eq 'skipped') {
        if ($Result.path -like '/api/dump/*') {
            return 'skipped_sensitive_dump'
        }
        return 'skipped'
    }
    if ($Result.status -eq 'transport_error') {
        return 'transport_error'
    }
    if ($Result.transportSuccess -and $Result.businessCode -eq 0) {
        return 'verified_success'
    }
    if (
        $Result.businessCode -eq 2003 -or
        $Result.businessMessage -match 'Permission denied'
    ) {
        return 'permission_denied'
    }
    if ($Result.businessCode -eq 5003) {
        return 'upstream_unavailable'
    }
    if ($Result.businessCode -in @(1002, 1003, 3001)) {
        return 'document_example_rejected'
    }
    if ($null -ne $Result.businessCode) {
        return 'business_error'
    }
    return 'transport_error'
}

function Get-MarkdownTables {
    param(
        [string[]]$Lines,
        [int]$StartIndex,
        [int]$EndIndex
    )

    $tables = @()
    $index = $StartIndex
    while ($index -lt $EndIndex -and $index -lt $Lines.Count) {
        if (
            $Lines[$index].Trim().StartsWith('|') -and
            $index + 1 -lt $EndIndex -and
            $Lines[$index + 1] -match '^\s*\|(?:\s*:?-+:?\s*\|)+\s*$'
        ) {
            $headerLine = $Lines[$index].Trim().Trim('|')
            $headers = @(
                [regex]::Split($headerLine, '(?<!\\)\|') |
                    ForEach-Object { Get-CleanCell $_ }
            )
            $rows = @()
            $rowIndex = $index + 2
            while ($rowIndex -lt $EndIndex -and $Lines[$rowIndex].Trim().StartsWith('|')) {
                $rowLine = $Lines[$rowIndex].Trim().Trim('|')
                $cells = @(
                    [regex]::Split($rowLine, '(?<!\\)\|') |
                        ForEach-Object { Get-CleanCell $_ }
                )
                if ($cells.Count -gt 0) {
                    $row = [ordered]@{}
                    for ($column = 0; $column -lt $headers.Count; $column++) {
                        $value = if ($column -lt $cells.Count) { $cells[$column] } else { '' }
                        $row[$headers[$column]] = $value
                    }
                    $rows += [pscustomobject]$row
                }
                $rowIndex++
            }
            $tables += , @{
                Headers = $headers
                Rows = $rows
                StartLine = $index + 1
            }
            $index = $rowIndex
            continue
        }
        $index++
    }
    return $tables
}

function Get-NearestTitle {
    param(
        [string[]]$Lines,
        [int]$LineIndex,
        [string]$DocumentTitle
    )

    $genericHeadings = @(
        '请求参数',
        '请求示例',
        '响应示例',
        '返回字段',
        '响应字段',
        '字段说明',
        '接口'
    )

    for ($index = $LineIndex; $index -ge 0; $index--) {
        if ($Lines[$index] -match '^##\s+(.+?)\s*$') {
            $candidate = $Matches[1]
            $candidate = $candidate -replace '\s*\{#[^}]+\}\s*$', ''
            if ($candidate -notin $genericHeadings) {
                return $candidate
            }
        }
    }

    for ($index = $LineIndex; $index -ge 0; $index--) {
        if ($Lines[$index] -match '<a id="([^"]+)"></a>') {
            $anchor = $Matches[1]
            if ($anchor -match '[\p{IsCJKUnifiedIdeographs}]') {
                return $anchor
            }
        }
        if ($Lines[$index] -match '^\*\*(.+?)\*\*\s*$') {
            $candidate = Get-CleanCell $Matches[1]
            if ($candidate -notin $genericHeadings) {
                return $candidate
            }
        }
    }

    return $DocumentTitle
}

function Get-EndpointOccurrences {
    param(
        [string[]]$Lines,
        [string]$RelativePath
    )

    $occurrences = @()
    $insideCodeBlock = $false
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^```') {
            $insideCodeBlock = -not $insideCodeBlock
            continue
        }

        $matchesInLine = [regex]::Matches(
            $Lines[$index],
            'GET\s+(?:https://datahub\.10jqka\.com\.cn)?(/api/[^\s`<>\)|]+)'
        )
        foreach ($match in $matchesInLine) {
            $path = $match.Groups[1].Value
            if ($path -match '[?]') {
                $path = $path.Substring(0, $path.IndexOf('?'))
            }
            $occurrences += [pscustomobject]@{
                Path = $path
                LineIndex = $index
                IsCodeBlock = $insideCodeBlock
                IsStandalone = $Lines[$index].Trim().StartsWith('GET ')
                IsTableRow = $Lines[$index].Trim().StartsWith('|')
                IsCanonicalSignature = (
                    ($Lines[$index].Trim().Trim('`')) -match '^GET\s+/api/\S+$' -and
                    $Lines[$index] -notmatch '\?'
                )
                RelativePath = $RelativePath
                Line = $Lines[$index]
            }
        }
    }
    return $occurrences
}

function Get-ModuleDescription {
    param([string[]]$Lines)

    $paragraphs = @()
    $current = @()
    $seenHeading = $false
    foreach ($line in $Lines) {
        if ($line -match '^#\s+') {
            $seenHeading = $true
            continue
        }
        if (-not $seenHeading) {
            continue
        }
        if (
            $line -match '^##\s+|^<a id=|^- \[|^\[业务目录\]|^```|^\||^\*\*[^*]+\*\*\s*$'
        ) {
            if ($current.Count -gt 0) {
                $paragraphs += ($current -join '')
                $current = @()
            }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($current.Count -gt 0) {
                $paragraphs += ($current -join '')
                $current = @()
            }
            continue
        }
        if ($line -match '^\s*GET\s+/api/') {
            continue
        }
        if ($line -match '^>\s*') {
            if ($current.Count -gt 0) {
                $paragraphs += ($current -join '')
                $current = @()
            }
            continue
        }
        $current += $line.Trim()
    }
    if ($current.Count -gt 0) {
        $paragraphs += ($current -join '')
    }
    return ((($paragraphs | Select-Object -First 2) -join ' ') | ForEach-Object {
        Get-CleanCell $_
    })
}

function Get-ParameterRows {
    param(
        [string[]]$Lines,
        [int]$StartIndex,
        [int]$EndIndex
    )

    $parameterHeadingIndex = -1
    for ($index = $StartIndex; $index -lt $EndIndex; $index++) {
        if ($Lines[$index] -match '^#{2,4}\s*请求参数') {
            $parameterHeadingIndex = $index
            break
        }
    }
    if ($parameterHeadingIndex -lt 0) {
        return @()
    }

    $tableEnd = $EndIndex
    for ($index = $parameterHeadingIndex + 1; $index -lt $EndIndex; $index++) {
        if ($Lines[$index] -match '^#{2,4}\s+') {
            $tableEnd = $index
            break
        }
    }

    $tables = Get-MarkdownTables -Lines $Lines -StartIndex $parameterHeadingIndex -EndIndex $tableEnd
    if ($tables.Count -eq 0) {
        return @()
    }

    return ($tables | Select-Object -First 1).Rows
}

function Get-ResponseFieldTables {
    param(
        [string[]]$Lines,
        [int]$StartIndex,
        [int]$EndIndex
    )

    $responseHeadingIndex = -1
    for ($index = $StartIndex; $index -lt $EndIndex; $index++) {
        if ($Lines[$index] -match '^#{2,4}\s*(返回字段|响应字段|字段说明)') {
            $responseHeadingIndex = $index
            break
        }
    }
    if ($responseHeadingIndex -lt 0) {
        return @()
    }

    $tableEnd = $EndIndex
    for ($index = $responseHeadingIndex + 1; $index -lt $EndIndex; $index++) {
        if ($Lines[$index] -match '^#{2,4}\s+') {
            $tableEnd = $index
            break
        }
    }

    return @(
        Get-MarkdownTables -Lines $Lines -StartIndex $responseHeadingIndex -EndIndex $tableEnd |
            ForEach-Object { $_.Rows }
    )
}

function Get-ParameterNote {
    param(
        [string[]]$Lines,
        [int]$StartIndex,
        [int]$EndIndex
    )

    $parameterHeadingIndex = -1
    for ($index = $StartIndex; $index -lt $EndIndex; $index++) {
        if ($Lines[$index] -match '^#{2,4}\s*请求参数') {
            $parameterHeadingIndex = $index
            break
        }
    }
    if ($parameterHeadingIndex -lt 0) {
        return $null
    }

    $notes = @()
    for ($index = $parameterHeadingIndex + 1; $index -lt $EndIndex; $index++) {
        if ($Lines[$index] -match '^#{2,4}\s+') {
            break
        }
        if (
            -not [string]::IsNullOrWhiteSpace($Lines[$index]) -and
            -not $Lines[$index].Trim().StartsWith('|')
        ) {
            $notes += $Lines[$index].Trim()
        }
    }
    if ($notes.Count -gt 0) {
        return (Get-CleanProse ($notes -join ' '))
    }
    return $null
}

function Get-EndpointDescription {
    param(
        [string[]]$Lines,
        [int]$StartIndex,
        [int]$EndIndex,
        [string]$Fallback
    )

    $parts = @()
    $started = $false
    for ($index = $StartIndex + 1; $index -lt $EndIndex; $index++) {
        $line = $Lines[$index]
        if (-not $started -and ($line -match '^```|^<a id=|^GET\s+')) {
            continue
        }
        if ($line -match '^#{2,4}\s+|^```|^<a id=|^\|') {
            break
        }
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($parts.Count -gt 0) {
                break
            }
            continue
        }
        if ($line -match '^>\s*') {
            continue
        }
        $started = $true
        $parts += $line.Trim()
    }
    $description = Get-CleanProse ($parts -join ' ')
    if ($description) {
        return $description
    }
    return Get-CleanProse $Fallback
}

function Get-ResponseExample {
    param(
        [string[]]$Lines,
        [int]$StartIndex,
        [int]$EndIndex
    )

    $headingIndex = -1
    for ($index = $StartIndex; $index -lt $EndIndex; $index++) {
        if ($Lines[$index] -match '^#{2,4}\s*响应示例') {
            $headingIndex = $index
            break
        }
    }
    if ($headingIndex -lt 0) {
        return $null
    }

    $codeStart = -1
    for ($index = $headingIndex + 1; $index -lt $EndIndex; $index++) {
        if ($Lines[$index] -match '^```json\s*$') {
            $codeStart = $index + 1
            break
        }
        if ($Lines[$index] -match '^#{2,4}\s+') {
            break
        }
    }
    if ($codeStart -lt 0) {
        return $null
    }

    $exampleLines = @()
    for ($index = $codeStart; $index -lt $EndIndex; $index++) {
        if ($Lines[$index] -match '^```') {
            break
        }
        $exampleLines += $Lines[$index]
    }
    if ($exampleLines.Count -eq 0) {
        return $null
    }
    return ($exampleLines -join "`n")
}

function Get-RequestExample {
    param(
        [string[]]$Lines,
        [int]$StartIndex,
        [int]$EndIndex
    )

    $exampleHeadingIndex = -1
    for ($index = $StartIndex; $index -lt $EndIndex; $index++) {
        if ($Lines[$index] -match '^#{2,4}\s*请求示例') {
            $exampleHeadingIndex = $index
            break
        }
    }
    if ($exampleHeadingIndex -lt 0) {
        return $null
    }

    for ($index = $exampleHeadingIndex + 1; $index -lt $EndIndex; $index++) {
        if ($Lines[$index] -match '^#{2,4}\s+') {
            break
        }
        if ($Lines[$index] -match 'GET\s+(https?://\S+)') {
            return $Matches[1]
        }
    }
    return $null
}

$sourceFiles = Get-ChildItem -LiteralPath $ApiRoot -Recurse -File -Filter '*.md'
$allOccurrences = @()
$documents = @{}
foreach ($file in $sourceFiles) {
    $relativePath = $file.FullName.Substring($ApiRoot.Length + 1)
    $lines = Get-Content -LiteralPath $file.FullName
    $titleLine = $lines | Where-Object { $_ -match '^#\s+' } | Select-Object -First 1
    $documentTitle = if ($titleLine -and $titleLine -match '^#\s+(.+?)\s*$') {
        $Matches[1]
    }
    else {
        [IO.Path]::GetFileNameWithoutExtension($file.Name)
    }
    $documents[$relativePath] = @{
        Lines = $lines
        Title = $documentTitle
        Description = Get-CleanProse (Get-ModuleDescription $lines)
    }
    $allOccurrences += Get-EndpointOccurrences -Lines $lines -RelativePath $relativePath
}

$endpoints = @()
foreach ($group in ($allOccurrences | Group-Object Path)) {
    $best = $group.Group |
        Sort-Object `
            @{ Expression = 'IsCanonicalSignature'; Descending = $true },
            @{ Expression = 'IsCodeBlock'; Descending = $true },
            @{ Expression = 'IsStandalone'; Descending = $true },
            @{ Expression = 'IsTableRow'; Descending = $true },
            @{ Expression = 'LineIndex'; Descending = $false } |
        Select-Object -First 1

    $document = $documents[$best.RelativePath]
    $lines = $document.Lines
    $title = Get-NearestTitle -Lines $lines -LineIndex $best.LineIndex -DocumentTitle $document.Title

    if ($best.RelativePath -eq 'a-share\market-dumps.md' -and $best.IsTableRow) {
        $cells = @(
            [regex]::Split($best.Line.Trim().Trim('|'), '(?<!\\)\|') |
                ForEach-Object { Get-CleanCell $_ }
        )
        if ($cells.Count -gt 0) {
            $title = $cells[0]
        }
    }

    $sectionEnd = $lines.Count
    for ($index = $best.LineIndex + 1; $index -lt $lines.Count; $index++) {
        $other = $allOccurrences |
            Where-Object {
                $_.RelativePath -eq $best.RelativePath -and
                $_.LineIndex -gt $best.LineIndex -and
                $_.LineIndex -lt $index -and
                ($_.IsCanonicalSignature -or $_.IsTableRow)
            } |
            Select-Object -First 1
        if ($other) {
            $sectionEnd = $other.LineIndex
            break
        }
    }

    $category = if ($best.RelativePath -match '[\\/]') {
        ($best.RelativePath -split '[\\/]')[0]
    }
    else {
        'root'
    }

    $parameters = @(
        Get-ParameterRows -Lines $lines -StartIndex $best.LineIndex -EndIndex $sectionEnd
    )
    $parameterNote = Get-ParameterNote -Lines $lines -StartIndex $best.LineIndex -EndIndex $sectionEnd
    $description = Get-EndpointDescription `
        -Lines $lines `
        -StartIndex $best.LineIndex `
        -EndIndex $sectionEnd `
        -Fallback $document.Description
    if (-not $description) {
        $description = $title
    }
    $responseFields = @(
        Get-ResponseFieldTables -Lines $lines -StartIndex $best.LineIndex -EndIndex $sectionEnd
    )
    $exampleUrl = Get-RequestExample -Lines $lines -StartIndex $best.LineIndex -EndIndex $sectionEnd
    $responseExampleJson = Get-ResponseExample -Lines $lines -StartIndex $best.LineIndex -EndIndex $sectionEnd

    $endpoints += [pscustomobject][ordered]@{
        path = $group.Name
        method = 'GET'
        title = $title
        category = $category
        moduleTitle = $document.Title
        moduleDescription = $document.Description
        description = $description
        source = $best.RelativePath
        parameterRows = $parameters
        parameterNote = $parameterNote
        responseFieldRows = $responseFields
        exampleUrl = $exampleUrl
        responseExampleJson = $responseExampleJson
        observedSourceLine = $best.LineIndex + 1
    }
}

$endpoints = @($endpoints | Sort-Object category, moduleTitle, title, path)
if ($endpoints.Count -ne 118) {
    throw "Expected 118 DataHub GET contracts, found $($endpoints.Count)."
}

$runtimeByPath = @{}
$runtimeTestedAt = $null
if (Test-Path -LiteralPath $RuntimeMatrixPath) {
    $runtimeMatrix = Get-Content -LiteralPath $RuntimeMatrixPath -Raw | ConvertFrom-Json
    $runtimeTestedAt = $runtimeMatrix.generatedAt
    foreach ($result in $runtimeMatrix.results) {
        $runtimeByPath[$result.path] = $result
    }
}

foreach ($endpoint in $endpoints) {
    $runtimeResult = $runtimeByPath[$endpoint.path]
    $runtimeStatus = Get-RuntimeStatus $runtimeResult
    $endpoint | Add-Member -NotePropertyName runtimeStatus -NotePropertyValue $runtimeStatus
    $endpoint | Add-Member -NotePropertyName runtimeEvidence -NotePropertyValue $(
        if ($runtimeResult) {
            [ordered]@{
                status = $runtimeStatus
                businessCode = $runtimeResult.businessCode
                businessMessage = $runtimeResult.businessMessage
                exampleUrl = $runtimeResult.url
                exampleSource = $runtimeResult.exampleSource
                responseBytes = $runtimeResult.responseBytes
                elapsedMs = $runtimeResult.elapsedMs
                attemptCount = $runtimeResult.attemptCount
                successObserved = $runtimeResult.successObserved
                testedAt = $runtimeResult.testedAt
            }
        }
        else {
            $null
        }
    )
}

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$jsonPath = Join-Path $OutputRoot 'datahub-apis.json'
$markdownPath = Join-Path $OutputRoot 'datahub-apis.md'

$index = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    source = $ApiRoot
    runtimeMatrix = if (Test-Path -LiteralPath $RuntimeMatrixPath) {
        (Resolve-Path -LiteralPath $RuntimeMatrixPath).Path
    }
    else {
        $null
    }
    runtimeTestedAt = $runtimeTestedAt
    contractCount = $endpoints.Count
    categories = @(
        $endpoints |
            Group-Object category |
            Sort-Object Name |
            ForEach-Object {
                [ordered]@{
                    name = $_.Name
                    count = $_.Count
                }
            }
    )
    runtimeSummary = @(
        $endpoints |
            Group-Object runtimeStatus |
            Sort-Object Name |
            ForEach-Object {
                [ordered]@{
                    status = $_.Name
                    count = $_.Count
                }
            }
    )
    endpoints = $endpoints
}
$index | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding utf8

$markdown = [System.Collections.Generic.List[string]]::new()
$markdown.Add('# DataHub 行情接口清单')
$markdown.Add('')
$markdown.Add("共 $($endpoints.Count) 个 GET 契约，来源于本机 Lumi 1.0.69 的 DataHub 快照。")
$markdown.Add('')
if ($runtimeTestedAt) {
    $markdown.Add("运行探测时间：``$runtimeTestedAt``。")
    $markdown.Add('')
    $markdown.Add('| 运行状态 | 接口数 |')
    $markdown.Add('|---|---:|')
    foreach ($item in $index.runtimeSummary) {
        $markdown.Add("| $($item.status) | $($item.count) |")
    }
    $markdown.Add('')
}
$markdown.Add('| 分类 | 接口数 |')
$markdown.Add('|---|---:|')
foreach ($category in $index.categories) {
    $markdown.Add("| $($category.name) | $($category.count) |")
}
$markdown.Add('')
foreach ($category in ($endpoints | Group-Object category | Sort-Object Name)) {
    $markdown.Add("## $($category.Name)")
    $markdown.Add('')
    foreach ($endpoint in $category.Group) {
        $markdown.Add("### $($endpoint.title)")
        $markdown.Add('')
        $markdown.Add("``GET $($endpoint.path)``")
        $markdown.Add('')
        if ($endpoint.description) {
            $markdown.Add($endpoint.description)
            $markdown.Add('')
        }
        if ($endpoint.runtimeStatus) {
            $evidence = $endpoint.runtimeEvidence
            $runtimeText = "**运行验证**：``$($endpoint.runtimeStatus)``"
            if ($evidence -and $null -ne $evidence.businessCode) {
                $runtimeText += "，``code=$($evidence.businessCode)``"
            }
            if ($evidence -and $evidence.businessMessage) {
                $runtimeText += "，$($evidence.businessMessage)"
            }
            if ($evidence -and $evidence.exampleSource -eq 'override') {
                $runtimeText += '（使用替代有效样例）'
            }
            if ($endpoint.runtimeStatus -eq 'skipped_sensitive_dump') {
                $runtimeText += '，未请求以避免短时下载链接落盘'
            }
            $markdown.Add($runtimeText)
            $markdown.Add('')
        }
        if ($endpoint.parameterRows.Count -gt 0) {
            $headers = @($endpoint.parameterRows[0].PSObject.Properties.Name)
            $markdown.Add('**请求参数**')
            $markdown.Add('')
            $markdown.Add('| ' + ($headers -join ' | ') + ' |')
            $markdown.Add('|' + (($headers | ForEach-Object { '---' }) -join '|') + '|')
            foreach ($row in $endpoint.parameterRows) {
                $values = $headers | ForEach-Object { [string]$row.$_ -replace '\|', '\|' }
                $markdown.Add('| ' + ($values -join ' | ') + ' |')
            }
            $markdown.Add('')
        }
        elseif ($endpoint.parameterNote) {
            $markdown.Add("**请求参数**：$($endpoint.parameterNote)")
            $markdown.Add('')
        }
        if ($endpoint.responseFieldRows.Count -gt 0) {
            $markdown.Add('**主要响应字段**')
            $markdown.Add('')
            $headers = @($endpoint.responseFieldRows[0].PSObject.Properties.Name)
            $markdown.Add('| ' + ($headers -join ' | ') + ' |')
            $markdown.Add('|' + (($headers | ForEach-Object { '---' }) -join '|') + '|')
            foreach ($row in ($endpoint.responseFieldRows | Select-Object -First 20)) {
                $values = $headers | ForEach-Object { [string]$row.$_ -replace '\|', '\|' }
                $markdown.Add('| ' + ($values -join ' | ') + ' |')
            }
            $markdown.Add('')
        }
        if ($endpoint.exampleUrl) {
            $markdown.Add("示例：``$($endpoint.exampleUrl)``")
            $markdown.Add('')
        }
        if ($endpoint.responseExampleJson) {
            $markdown.Add('<details>')
            $markdown.Add('<summary>响应示例</summary>')
            $markdown.Add('')
            $markdown.Add('```json')
            $markdown.Add($endpoint.responseExampleJson)
            $markdown.Add('```')
            $markdown.Add('')
            $markdown.Add('</details>')
            $markdown.Add('')
        }
    }
}
$markdown | Set-Content -LiteralPath $markdownPath -Encoding utf8

$csvPath = Join-Path $OutputRoot 'datahub-apis.csv'
$endpoints |
    Select-Object `
        path,
        category,
        title,
        description,
        runtimeStatus,
        @{ Name = 'parameterNames'; Expression = {
            @($_.parameterRows | ForEach-Object { $_.'参数' }) -join ';'
        } },
        @{ Name = 'responseFieldCount'; Expression = {
            @($_.responseFieldRows).Count
        } },
        exampleUrl,
        @{ Name = 'runtimeBusinessCode'; Expression = {
            $_.runtimeEvidence.businessCode
        } },
        @{ Name = 'runtimeBusinessMessage'; Expression = {
            $_.runtimeEvidence.businessMessage
        } },
        source |
    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

$failures = @(
    $endpoints |
        Where-Object {
            $_.runtimeStatus -notin @(
                'verified_success',
                'skipped_sensitive_dump',
                'skipped'
            )
        }
)
$skipped = @(
    $endpoints |
        Where-Object { $_.runtimeStatus -in @('skipped_sensitive_dump', 'skipped') }
)

$failureMarkdown = [System.Collections.Generic.List[string]]::new()
$failureMarkdown.Add('# DataHub 未通过验证的接口')
$failureMarkdown.Add('')
$failureMarkdown.Add('本表区分账号权限、上游暂不可用和文档示例失效，不能仅凭一次失败判断接口永久失效。')
$failureMarkdown.Add('')
$failureMarkdown.Add('## 业务失败')
$failureMarkdown.Add('')
$failureMarkdown.Add('| 状态 | 业务码 | 接口 | 说明 | 尝试次数 |')
$failureMarkdown.Add('|---|---:|---|---|---:|')
foreach ($endpoint in $failures) {
    $evidence = $endpoint.runtimeEvidence
    $message = if ($evidence.businessMessage) {
        $evidence.businessMessage
    }
    else {
        '—'
    }
    $attemptCount = if ($null -ne $evidence.attemptCount) {
        $evidence.attemptCount
    }
    else {
        '—'
    }
    $failureMarkdown.Add(
        "| $($endpoint.runtimeStatus) | $($evidence.businessCode) | ``$($endpoint.path)`` | $message | $attemptCount |"
    )
}
$failureMarkdown.Add('')
$failureMarkdown.Add('## 未请求')
$failureMarkdown.Add('')
$failureMarkdown.Add('| 状态 | 接口 | 原因 |')
$failureMarkdown.Add('|---|---|---|')
foreach ($endpoint in $skipped) {
    $reason = if ($endpoint.runtimeStatus -eq 'skipped_sensitive_dump') {
        '返回短时下载链接，未请求以避免敏感链接落盘。'
    }
    else {
        '无文档请求示例。'
    }
    $failureMarkdown.Add("| $($endpoint.runtimeStatus) | ``$($endpoint.path)`` | $reason |")
}
$failureMarkdown.Add('')
$failureMarkdownPath = Join-Path $OutputRoot 'datahub-runtime-failures.md'
$failureMarkdown | Set-Content -LiteralPath $failureMarkdownPath -Encoding utf8

Write-Output "Wrote $($endpoints.Count) contracts to $jsonPath, $markdownPath, and $csvPath"
Write-Output "Wrote runtime failure summary to $failureMarkdownPath"
