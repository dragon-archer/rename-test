param(
    [ValidateRange(1, 100)]
    [int]$Runs = 20,
    [string]$Executable = "$PSScriptRoot/build/rename-win32.exe",
    [string]$OutputDirectory = "$PSScriptRoot/results"
)

$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$OutputDirectory = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$rows = @()

for ($sample = 1; $sample -le $Runs; ++$sample) {
    $sampleDirectory = New-Item -ItemType Directory -Path "$OutputDirectory/run-$sample"
    $stdout = Join-Path $sampleDirectory.FullName 'stdout.log'
    $stderr = Join-Path $sampleDirectory.FullName 'stderr.log'
    $process = Start-Process -FilePath $Executable -WorkingDirectory $sampleDirectory.FullName `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -Wait -PassThru
    $exitCode = $process.ExitCode
    $output = (Get-Content -LiteralPath $stdout, $stderr) -join "`n"
    $outcome = 'unexpected_error'
    $round = $null
    $direction = ''
    $win32Error = $null
    $renameCalls = $null

    if ($exitCode -eq 1 -and $output -match 'RENAME_FAILURE (gcc -> stage1-gcc|stage1-gcc -> gcc) round=(\d+) error=(\d+)') {
        $direction = $Matches[1]
        $round = [int]$Matches[2]
        $win32Error = [int]$Matches[3]
        $renameCalls = 2 * $round
        if ($direction -eq 'gcc -> stage1-gcc') { $renameCalls -= 1 }
        $outcome = if ($win32Error -eq 5) { 'access_denied' } else { 'other_rename_error' }
    } elseif ($exitCode -eq 0 -and $output -match 'NOT_REPRODUCED: 100 rounds') {
        $outcome = 'not_reproduced'
        $round = 100
        $renameCalls = 200
    }

    $rows += [pscustomobject]@{
        sample = $sample
        outcome = $outcome
        exit_code = $exitCode
        round = $round
        direction = $direction
        win32_error = $win32Error
        rename_calls = $renameCalls
    }
    $rows | Export-Csv -LiteralPath "$OutputDirectory/results.csv" -NoTypeInformation
    Write-Host ("Sample {0}/{1}: {2}; exit={3}; round={4}; error={5}" -f `
        $sample, $Runs, $outcome, $exitCode, $round, $win32Error)
}

$denied = @($rows | Where-Object outcome -eq 'access_denied').Count
$passed = @($rows | Where-Object outcome -eq 'not_reproduced').Count
$otherRename = @($rows | Where-Object outcome -eq 'other_rename_error').Count
$unexpected = @($rows | Where-Object outcome -eq 'unexpected_error').Count
$valid = $denied + $passed
$frequency = if ($valid) { '{0:P1}' -f ($denied / $valid) } else { 'N/A' }
$calls = ($rows | Measure-Object -Property rename_calls -Sum).Sum
$runner = if ($env:RUNNER_LABEL) { $env:RUNNER_LABEL } else { 'local' }
$summary = @(
    "## Rename reproduction: $runner"
    ''
    '| Measurement | Result |'
    '| --- | --- |'
    "| Requested process runs | $Runs |"
    "| Access denied (Win32 5) | $denied |"
    "| No reproduction in 100 rounds | $passed |"
    "| Other rename errors | $otherRename |"
    "| Setup, crash or unrecognized results | $unexpected |"
    "| Access-denied runs / valid runs | $denied / $valid ($frequency) |"
    "| Rename calls observed | $calls |"
    ''
    'Frequency is per process run (at most 100 rounds), not per round or an OS-wide probability.'
    'All process runs share one runner VM. Each uses a new directory and stops at its first rename failure.'
    'Other rename errors and invalid results are excluded from the access-denied frequency.'
)
$summary | Set-Content -LiteralPath "$OutputDirectory/summary.md" -Encoding utf8
$summary | ForEach-Object { Write-Host $_ }
if ($env:GITHUB_STEP_SUMMARY) {
    $summary | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}
if ($otherRename -or $unexpected) {
    throw 'Some runs had non-target errors; see results.csv and per-run logs.'
}
