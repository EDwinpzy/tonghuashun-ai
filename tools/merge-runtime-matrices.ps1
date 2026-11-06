param(
    [string[]]$InputPaths = @(
        (Join-Path $PSScriptRoot '..\artifacts\datahub-runtime-matrix.json'),
        (Join-Path $PSScriptRoot '..\artifacts\datahub-retest.json'),
        (Join-Path $PSScriptRoot '..\artifacts\datahub-retest2.json')
    ),
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\artifacts\datahub-runtime-matrix-merged.json')
)

$ErrorActionPreference = 'Stop'

$attemptsByPath = @{}
foreach ($inputPath in $InputPaths) {
    if (-not (Test-Path -LiteralPath $inputPath)) {
        continue
    }

    $document = Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json
    foreach ($result in $document.results) {
        if (-not $attemptsByPath.ContainsKey($result.path)) {
            $attemptsByPath[$result.path] = @()
        }

        $attemptsByPath[$result.path] += [pscustomobject][ordered]@{
            testedAt = $document.generatedAt
            status = $result.status
            transportSuccess = $result.transportSuccess
            businessCode = $result.businessCode
            businessMessage = $result.businessMessage
            url = $result.url
            exampleSource = $result.exampleSource
            responseBytes = $result.responseBytes
            elapsedMs = $result.elapsedMs
            reason = $result.reason
        }
    }
}

$mergedResults = @()
foreach ($path in $attemptsByPath.Keys) {
    $attempts = @($attemptsByPath[$path])
    $successes = @(
        $attempts | Where-Object {
            $_.status -eq 'requested' -and
            $_.transportSuccess -eq $true -and
            $_.businessCode -eq 0
        }
    )
    $selected = if ($successes.Count -gt 0) {
        $successes | Select-Object -Last 1
    }
    else {
        $attempts | Select-Object -Last 1
    }

    $mergedResults += [pscustomobject][ordered]@{
        path = $path
        testedAt = $selected.testedAt
        status = $selected.status
        transportSuccess = $selected.transportSuccess
        businessCode = $selected.businessCode
        businessMessage = $selected.businessMessage
        url = $selected.url
        exampleSource = $selected.exampleSource
        responseBytes = $selected.responseBytes
        elapsedMs = $selected.elapsedMs
        reason = $selected.reason
        successObserved = ($successes.Count -gt 0)
        attemptCount = $attempts.Count
        observedAttempts = $attempts
    }
}

$mergedResults = @($mergedResults | Sort-Object path)
$summary = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    sources = @($InputPaths | Where-Object { Test-Path -LiteralPath $_ })
    requested = @($mergedResults | Where-Object status -eq 'requested').Count
    transportErrors = @($mergedResults | Where-Object status -eq 'transport_error').Count
    businessSuccess = @($mergedResults | Where-Object successObserved).Count
    businessFailures = @(
        $mergedResults |
            Where-Object { $_.status -eq 'requested' -and -not $_.successObserved }
    ).Count
    skipped = @($mergedResults | Where-Object status -eq 'skipped').Count
    multipleAttempts = @($mergedResults | Where-Object attemptCount -gt 1).Count
    results = $mergedResults
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $OutputPath -Encoding utf8
$summary.GetEnumerator() |
    Where-Object Key -ne 'results' |
    ForEach-Object { Write-Output ("$($_.Key)=$($_.Value)") }
Write-Output "Output: $OutputPath"
