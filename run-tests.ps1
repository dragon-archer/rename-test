param(
    [ValidateRange(1, 100)][int]$Runs = 5,
    [string]$Executable = "$PSScriptRoot/build/rename-win32.exe",
    [string]$OutputDirectory = "$PSScriptRoot/results",
    [ValidateRange(0, 32)][int[]]$ScannerCounts = @(0, 1)
)

$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$OutputDirectory = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$ScannerCounts = @($ScannerCounts | Select-Object -Unique)
$methods = @('movefile', 'infoex', 'posix')
$rows = @()

function Start-TestProcess($arguments, $directory, $log) {
    $process = Start-Process -FilePath $Executable -ArgumentList $arguments -WorkingDirectory $directory `
        -RedirectStandardOutput "$log-stdout.log" -RedirectStandardError "$log-stderr.log" -NoNewWindow -PassThru
    $null = $process.Handle
    return $process
}

function Wait-TestProcess($process, $milliseconds) {
    if (-not $process.WaitForExit($milliseconds)) {
        $process.Kill()
        $process.WaitForExit()
        throw "Test process $($process.Id) timed out."
    }
    $process.WaitForExit()
}

function Read-ProbeResult($output, $exitCode, $method) {
    if ($exitCode -eq 3 -and $output -match "(?m)^UNSUPPORTED .* method=$method phase=FileRenameInfoEx\r?$") {
        return [pscustomobject]@{ outcome = 'unsupported'; attempts = 0; succeeded = 0; denied = 0; other = 0 }
    }
    if ($output -notmatch '(?m)^RENAME_RESULT attempts=(\d+) succeeded=(\d+) denied=(\d+) other=(\d+)\r?$') {
        throw 'Missing completed probe counts; inspect raw logs.'
    }
    $attempts, $succeeded, $denied, $other = 1..4 | ForEach-Object { [int]$Matches[$_] }
    if ($attempts -ne 100 -or $succeeded + $denied + $other -ne $attempts -or
        $exitCode -ne [int](($denied + $other) -gt 0)) {
        throw 'Inconsistent probe counts or exit code.'
    }
    return [pscustomobject]@{
        outcome = 'completed'; attempts = $attempts; succeeded = $succeeded; denied = $denied; other = $other
    }
}

for ($sample = 1; $sample -le $Runs; ++$sample) {
    for ($pressureOffset = 0; $pressureOffset -lt $ScannerCounts.Count; ++$pressureOffset) {
        $count = $ScannerCounts[($sample - 1 + $pressureOffset) % $ScannerCounts.Count]
        for ($offset = 0; $offset -lt $methods.Count; ++$offset) {
            $method = $methods[($sample - 1 + $offset) % $methods.Count]
            $case = "run-$sample-scanners-$count-$method"
            $directory = (New-Item -ItemType Directory -Path "$OutputDirectory/$case").FullName
            $tree = (New-Item -ItemType Directory -Path "$directory/tree").FullName
            $stop = "$directory/stop"
            $scanners = @()
            $probe = $null
            $scanEntries = [long]0
            $scanPasses = [long]0
            try {
                for ($worker = 1; $worker -le $count; ++$worker) {
                    $ready = "$directory/ready-$worker"
                    $log = "$directory/scanner-$worker"
                    $arguments = 'scan "{0}" "{1}" "{2}"' -f $tree, $ready, $stop
                    $process = Start-TestProcess $arguments $tree $log
                    $scanners += [pscustomobject]@{ process = $process; ready = $ready; log = $log }
                }
                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                foreach ($scanner in $scanners) {
                    while (-not (Test-Path -LiteralPath $scanner.ready)) {
                        if ($scanner.process.HasExited -or $timer.Elapsed.TotalSeconds -gt 20) {
                            throw "Scanner not ready: $($scanner.log)"
                        }
                        Start-Sleep -Milliseconds 10
                    }
                }
                $probe = Start-TestProcess $method $tree "$directory/probe"
                Wait-TestProcess $probe 60000
            } finally {
                [System.IO.File]::WriteAllText($stop, 'stop')
                $scannerErrors = @()
                foreach ($scanner in $scanners) {
                    try {
                        Wait-TestProcess $scanner.process 10000
                        $text = Get-Content -Raw -LiteralPath "$($scanner.log)-stdout.log"
                        if ($scanner.process.ExitCode -ne 0 -or
                            $text -notmatch 'SCAN_RESULT passes=([1-9]\d*) entries=(\d+)') {
                            throw "Invalid scanner result: $($scanner.log)"
                        }
                        $scanPasses += [long]$Matches[1]
                        $scanEntries += [long]$Matches[2]
                    } catch {
                        $scannerErrors += $_
                    } finally {
                        $scanner.process.Dispose()
                    }
                }
                if ($scannerErrors.Count) { throw ($scannerErrors -join "`n") }
            }
            $exitCode = $probe.ExitCode
            $probe.Dispose()
            $output = (Get-Content -LiteralPath "$directory/probe-stdout.log", "$directory/probe-stderr.log") -join "`n"
            $result = Read-ProbeResult $output $exitCode $method
            if ($count -gt 0 -and $scanEntries -eq 0) { throw "No scanner activity: $directory" }
            $rows += [pscustomobject]@{
                sample = $sample; scanners = $count; method = $method; outcome = $result.outcome
                exit_code = $exitCode; attempts = $result.attempts; succeeded = $result.succeeded
                denied = $result.denied; other = $result.other; scan_passes = $scanPasses; scan_entries = $scanEntries
            }
            $rows | Export-Csv -LiteralPath "$OutputDirectory/results.csv" -NoTypeInformation
            Write-Host "$case : $($result.outcome); denied=$($result.denied)/$($result.attempts); other=$($result.other)"
        }
    }
}

$signal = @($rows | Where-Object { $_.scanners -eq 1 -and $_.method -eq 'movefile' -and $_.denied -gt 0 }).Count
$summary = @(
    "## Rename comparison: $env:RUNNER_LABEL"
    "Single-scanner MoveFileEx reproduction: $signal / $Runs (if selected)"
    ''
    '| Scanners | Method | Runs with Win32 5 / completed | Win32 5 / attempts | Call failure rate | Other errors | Unsupported runs |'
    '| --- | --- | --- | --- | --- | --- | --- |'
)
foreach ($count in $ScannerCounts) {
    foreach ($method in $methods) {
        $group = @($rows | Where-Object { $_.scanners -eq $count -and $_.method -eq $method })
        $valid = @($group | Where-Object outcome -eq 'completed')
        $failed = @($valid | Where-Object denied -gt 0).Count
        $unsupported = @($group | Where-Object outcome -eq 'unsupported').Count
        $attempts = [long]($valid | Measure-Object attempts -Sum).Sum
        $denied = [long]($valid | Measure-Object denied -Sum).Sum
        $other = [long]($valid | Measure-Object other -Sum).Sum
        $rate = if ($attempts) { '{0:P1}' -f ($denied / $attempts) } else { 'N/A' }
        $summary += "| $count | $method | $failed / $($valid.Count) | $denied / $attempts | $rate | $other | $unsupported |"
    }
}
$summary += @(
    ''
    'Each run attempts exactly 100 renames, creating 32 files before each. Success toggles the source name; failure leaves it unchanged.'
    'After failure the next scheduled attempt follows its file workload; there is no immediate retry or recovery loop.'
    'Call rates are observed fractions, not independent probabilities: consecutive failures share a directory and scanner state.'
    'Scanner-count and API order rotate each sample. All groups share one VM; 4/16-scanner pressure is not enabled by default.'
    'infoex/posix differ only by POSIX_SEMANTICS, with absent destination paths. There is no deliberate handle retention.'
    'Artificial scan contention is not proof of the original GCC root cause or a Windows regression. Unsupported is not a pass.'
)
$summary | Set-Content -LiteralPath "$OutputDirectory/summary.md" -Encoding utf8
$summary | ForEach-Object { Write-Host $_ }
if ($env:GITHUB_STEP_SUMMARY) { $summary | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
if (1 -in $ScannerCounts -and -not $signal) { Write-Warning 'Single-scanner control did not reproduce; do not infer a POSIX mitigation.' }
if (@($rows | Where-Object other -gt 0).Count) { throw 'Non-target rename errors occurred; inspect results.csv and raw logs.' }
