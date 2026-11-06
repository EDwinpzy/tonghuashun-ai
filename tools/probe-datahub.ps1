param(
    [string]$InventoryPath = (Join-Path $PSScriptRoot '..\inventory\datahub-apis.json'),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\artifacts\datahub-runtime-matrix.json'),
    [string]$SampleOverridesPath = (Join-Path $PSScriptRoot '..\inventory\datahub-sample-overrides.json'),
    [string[]]$Paths,
    [string]$User,
    [int]$DelayMs = 150
)

$ErrorActionPreference = 'Stop'

function Get-LumiMcpConnection {
    $relativeConfigPath = 'agent-sdk\opencode\config\opencode.jsonc'
    $candidates = @()
    if ($User) {
        $candidates = @(
            Join-Path $env:USERPROFILE "lumi\users\$User\$relativeConfigPath"
        )
    }
    else {
        $usersRoot = Join-Path $env:USERPROFILE 'lumi\users'
        if (Test-Path -LiteralPath $usersRoot) {
            $candidates = @(
                Get-ChildItem -LiteralPath $usersRoot -Directory |
                    Sort-Object LastWriteTime -Descending |
                    ForEach-Object {
                        Join-Path $_.FullName $relativeConfigPath
                    }
            )
        }
    }

    foreach ($configPath in $candidates) {
        if (-not (Test-Path -LiteralPath $configPath)) {
            continue
        }

        $config = Get-Content -LiteralPath $configPath -Raw
        $tokenMatch = [regex]::Match(
            $config,
            '"lumi"\s*:\s*\{[\s\S]*?"Authorization"\s*:\s*"Bearer\s+([^"]+)"'
        )
        $urlMatch = [regex]::Match(
            $config,
            '"lumi"\s*:\s*\{[\s\S]*?"url"\s*:\s*"([^"]+)"'
        )

        if ($tokenMatch.Success -and $urlMatch.Success) {
            return @{
                Url = $urlMatch.Groups[1].Value
                Token = $tokenMatch.Groups[1].Value
            }
        }
    }

    throw 'The local Lumi MCP endpoint or authorization was not found. Start Lumi with its MCP bridge enabled, or pass -User explicitly.'
}

function Invoke-McpPost {
    param(
        [hashtable]$Connection,
        [string]$Body,
        [string]$SessionId
    )

    $headers = @{
        Authorization = "Bearer $($Connection.Token)"
        Accept = 'application/json, text/event-stream'
    }
    if ($SessionId) {
        $headers['mcp-session-id'] = $SessionId
    }
    return Invoke-WebRequest `
        -Uri $Connection.Url `
        -Method Post `
        -Headers $headers `
        -ContentType 'application/json' `
        -Body $Body `
        -TimeoutSec 40
}

function Convert-McpResponse {
    param([string]$Content)

    $data = ($Content -split "`n" | Where-Object { $_ -like 'data: *' } | Select-Object -Last 1)
    if (-not $data) {
        throw 'No JSON data returned by MCP.'
    }
    return ($data.Substring(6) | ConvertFrom-Json)
}

$inventory = Get-Content -LiteralPath $InventoryPath -Raw | ConvertFrom-Json
$sampleOverrides = @{}
if (Test-Path -LiteralPath $SampleOverridesPath) {
    $overrideDocument = Get-Content -LiteralPath $SampleOverridesPath -Raw |
        ConvertFrom-Json -AsHashtable
    if ($overrideDocument.samples) {
        $sampleOverrides = $overrideDocument.samples
    }
}
$connection = Get-LumiMcpConnection

$initialize = @{
    jsonrpc = '2.0'
    id = 1
    method = 'initialize'
    params = @{
        protocolVersion = '2025-03-26'
        capabilities = @{}
        clientInfo = @{
            name = 'datahub-runtime-probe'
            version = '1.0'
        }
    }
} | ConvertTo-Json -Depth 12 -Compress

$initResponse = Invoke-McpPost -Connection $connection -Body $initialize
$null = Convert-McpResponse $initResponse.Content
$sessionId = [string]$initResponse.Headers['mcp-session-id']

$initialized = @{
    jsonrpc = '2.0'
    method = 'notifications/initialized'
} | ConvertTo-Json -Compress
try {
    $null = Invoke-McpPost -Connection $connection -Body $initialized -SessionId $sessionId
}
catch {
}

$results = @()
$requestId = 2
$endpointsToProbe = if ($Paths) {
    @($inventory.endpoints | Where-Object { $Paths -contains $_.path })
}
else {
    @($inventory.endpoints)
}
if ($Paths -and $endpointsToProbe.Count -eq 0) {
    throw 'None of the requested paths were found in the inventory.'
}

foreach ($endpoint in $endpointsToProbe) {
    if ($endpoint.path -like '/api/dump/*') {
        $results += [pscustomobject][ordered]@{
            path = $endpoint.path
            title = $endpoint.title
            category = $endpoint.category
            status = 'skipped'
            reason = 'Sensitive short-lived download URL; not requested.'
        }
        continue
    }

    $exampleUrl = $endpoint.exampleUrl
    $exampleSource = 'document'
    if ($sampleOverrides.ContainsKey($endpoint.path)) {
        $exampleUrl = [string]$sampleOverrides[$endpoint.path]
        $exampleSource = 'override'
    }

    if (-not $exampleUrl) {
        $results += [pscustomobject][ordered]@{
            path = $endpoint.path
            title = $endpoint.title
            category = $endpoint.category
            status = 'skipped'
            reason = 'No documented request example.'
        }
        continue
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $toolRequest = @{
        jsonrpc = '2.0'
        id = $requestId
        method = 'tools/call'
        params = @{
            name = 'tool_execute'
            arguments = @{
                name = 'http_get'
                args = @{
                    url = $exampleUrl
                }
            }
        }
    } | ConvertTo-Json -Depth 12 -Compress
    $requestId++

    try {
        $mcpResponse = Invoke-McpPost `
            -Connection $connection `
            -Body $toolRequest `
            -SessionId $sessionId
        $envelope = Convert-McpResponse $mcpResponse.Content
        $textPart = $envelope.result.content |
            Where-Object { $_.type -eq 'text' } |
            Select-Object -First 1
        $action = $textPart.text | ConvertFrom-Json
        $stopwatch.Stop()

        $transportSuccess = [bool]$action.success
        $businessCode = $null
        $businessMessage = $null
        $bodyBytes = $null
        $responseKeys = @()

        if ($action.data -and $action.data.success -and $action.data.data) {
            $bodyText = [string]$action.data.data
            $bodyBytes = [Text.Encoding]::UTF8.GetByteCount($bodyText)
            $body = $bodyText | ConvertFrom-Json
            $businessCode = $body.code
            $businessMessage = $body.message
            if ($body.data) {
                $responseKeys = @($body.data.PSObject.Properties.Name)
            }
        }
        elseif ($action.error) {
            $businessMessage = [string]$action.error
        }

        $results += [pscustomobject][ordered]@{
            path = $endpoint.path
            title = $endpoint.title
            category = $endpoint.category
            status = 'requested'
            url = $exampleUrl
            exampleSource = $exampleSource
            transportSuccess = $transportSuccess
            businessCode = $businessCode
            businessMessage = $businessMessage
            responseBytes = $bodyBytes
            responseKeys = $responseKeys
            elapsedMs = $stopwatch.ElapsedMilliseconds
        }
    }
    catch {
        $stopwatch.Stop()
        $results += [pscustomobject][ordered]@{
            path = $endpoint.path
            title = $endpoint.title
            category = $endpoint.category
            status = 'transport_error'
            url = $exampleUrl
            exampleSource = $exampleSource
            transportSuccess = $false
            businessMessage = $_.Exception.Message
            elapsedMs = $stopwatch.ElapsedMilliseconds
        }
    }

    if ($DelayMs -gt 0) {
        Start-Sleep -Milliseconds $DelayMs
    }
}

$summary = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    inventoryPath = (Resolve-Path -LiteralPath $InventoryPath).Path
    requested = @($results | Where-Object status -eq 'requested').Count
    transportErrors = @($results | Where-Object status -eq 'transport_error').Count
    businessSuccess = @(
        $results |
            Where-Object { $_.status -eq 'requested' -and $_.businessCode -eq 0 }
    ).Count
    businessFailures = @(
        $results |
            Where-Object { $_.status -eq 'requested' -and $_.businessCode -ne 0 }
    ).Count
    skipped = @($results | Where-Object status -eq 'skipped').Count
    results = $results
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8

$summary.GetEnumerator() |
    Where-Object Key -ne 'results' |
    ForEach-Object { Write-Output ("$($_.Key)=$($_.Value)") }
Write-Output "Output: $OutputPath"
