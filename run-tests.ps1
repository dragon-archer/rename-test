param(
    [ValidateRange(1, 100)]
    [int]$Runs = 20,
    [string]$Executable = "$PSScriptRoot/build/rename-win32.exe",
    [string]$OutputDirectory = "$PSScriptRoot/results",
    [ValidateRange(0, 32)]
    [int[]]$ScannerCounts = @(16, 0, 1, 4)
)

$ErrorActionPreference = 'Stop'
if (16 -notin $ScannerCounts) { throw 'The 16-scanner positive-control group must be retained.' }
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$OutputDirectory = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$ScannerCounts = @(16) + @($ScannerCounts | Where-Object { $_ -ne 16 } | Select-Object -Unique)
$methods = @('movefile', 'infoex', 'posix')
$initialHash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash
$windows = Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/Windows NT/CurrentVersion'
[pscustomobject]@{
    executable = $Executable
    executable_sha256 = $initialHash
    windows_build = "$($windows.CurrentBuildNumber).$($windows.UBR)"
    image = $env:ImageOS
    image_version = $env:ImageVersion
    scanner_counts = $ScannerCounts
    runs_per_group = $Runs
    modes = $methods
    powershell = $PSVersionTable.PSVersion.ToString()
} | ConvertTo-Json | Set-Content -LiteralPath "$OutputDirectory/environment.json"
$rows = @()

for ($sample = 1; $sample -le $Runs; ++$sample) {
  foreach ($scannerCount in $ScannerCounts) {
   for ($methodIndex = 0; $methodIndex -lt $methods.Count; ++$methodIndex) {
    $method = $methods[($methodIndex + $sample - 1) % $methods.Count]
    $case = "run-$sample-scanners-$scannerCount-$method"
    $sampleDirectory = New-Item -ItemType Directory -Path "$OutputDirectory/$case"
    $tree = (New-Item -ItemType Directory -Path "$($sampleDirectory.FullName)/tree").FullName
    $stdout = Join-Path $sampleDirectory.FullName 'stdout.log'
    $stderr = Join-Path $sampleDirectory.FullName 'stderr.log'
    $stop = Join-Path $sampleDirectory.FullName 'stop'
    $scanners = @()
    $scanPasses = [long]0
    $scanEntries = [long]0
    $scannerError = ''
    $process = $null
    try {
        for ($worker = 1; $worker -le $scannerCount; ++$worker) {
            $ready = Join-Path $sampleDirectory.FullName "ready-$worker"
            $scanOut = Join-Path $sampleDirectory.FullName "scanner-$worker-stdout.log"
            $scanErr = Join-Path $sampleDirectory.FullName "scanner-$worker-stderr.log"
            $arguments = 'scan "{0}" "{1}" "{2}"' -f $tree, $ready, $stop
            $scanner = Start-Process -FilePath $Executable -ArgumentList $arguments `
                -WorkingDirectory $tree -RedirectStandardOutput $scanOut `
                -RedirectStandardError $scanErr -NoNewWindow -PassThru
            $null = $scanner.Handle
            $scanners += [pscustomobject]@{ process = $scanner; ready = $ready; stdout = $scanOut; stderr = $scanErr }
        }
        $readiness = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($scanner in $scanners) {
            while (-not (Test-Path -LiteralPath $scanner.ready)) {
                if ($scanner.process.HasExited -or $readiness.Elapsed.TotalSeconds -gt 20) {
                    throw 'Scanner failed to become ready; inspect scanner logs.'
                }
                Start-Sleep -Milliseconds 10
            }
        }
        $process = Start-Process -FilePath $Executable -ArgumentList $method -WorkingDirectory $tree `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow -PassThru
        $null = $process.Handle
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            $process.WaitForExit()
            throw 'Probe exceeded 60 seconds; stopped only this test process.'
        }
        $process.WaitForExit()
    } finally {
        [System.IO.File]::WriteAllText($stop, 'stop')
        foreach ($scanner in $scanners) {
            if (-not $scanner.process.WaitForExit(10000)) {
                $scanner.process.Kill()
                $scanner.process.WaitForExit()
                $scannerError = 'scanner_timeout'
            } else {
                $scanner.process.WaitForExit()
            }
            $scanText = (Get-Content -LiteralPath $scanner.stdout, $scanner.stderr) -join "`n"
            if ($scanner.process.ExitCode -ne 0 -or $scanText -notmatch 'SCAN_RESULT passes=(\d+) entries=(\d+) vanished=(\d+)') {
                $scannerError = 'scanner_invalid_result'
            } else {
                $scanPasses += [long]$Matches[1]
                $scanEntries += [long]$Matches[2]
            }
            $scanner.process.Dispose()
        }
    }
    $exitCode = $process.ExitCode
    $process.Dispose()
    $output = (Get-Content -LiteralPath $stdout, $stderr) -join "`n"
    $outcome = 'unexpected_error'
    $round = $null
    $direction = ''
    $win32Error = $null
    $renameCalls = $null
    $phase = ''

    if ($exitCode -in @(1, 3) -and $output -match '(RENAME_FAILURE|UNSUPPORTED) (gcc -> stage1-gcc|stage1-gcc -> gcc) round=(\d+) error=(\d+) method=(\w+) phase=([\w-]+)') {
        $marker = $Matches[1]
        $direction = $Matches[2]
        $round = [int]$Matches[3]
        $win32Error = [int]$Matches[4]
        $reportedMethod = $Matches[5]
        $phase = $Matches[6]
        $renameCalls = 2 * $round
        if ($direction -eq 'gcc -> stage1-gcc') { $renameCalls -= 1 }
        if ($reportedMethod -eq $method) {
            if ($exitCode -eq 3 -and $marker -eq 'UNSUPPORTED') {
                $outcome = 'unsupported'
            } elseif ($exitCode -eq 1 -and $marker -eq 'RENAME_FAILURE') {
                $outcome = if ($win32Error -eq 5) { 'access_denied' } else { 'other_rename_error' }
            }
        }
    } elseif ($exitCode -eq 0 -and $output -match 'NOT_REPRODUCED: 100 rounds') {
        $outcome = 'not_reproduced'
        $round = 100
        $renameCalls = 200
    }
    if ($scannerCount -gt 0 -and $scanEntries -eq 0) { $scannerError = 'no_target_entries_observed' }
    if ($scannerError) { $outcome = 'invalid_pressure' }

    $rows += [pscustomobject]@{
        sample = $sample
        scanners = $scannerCount
        method = $method
        outcome = $outcome
        exit_code = $exitCode
        round = $round
        direction = $direction
        win32_error = $win32Error
        rename_calls = $renameCalls
        phase = $phase
        scan_passes = $scanPasses
        scan_entries = $scanEntries
        scanner_error = $scannerError
    }
    $rows | Export-Csv -LiteralPath "$OutputDirectory/results.csv" -NoTypeInformation
    Write-Host "$case : $outcome; exit=$exitCode; round=$round; error=$win32Error; phase=$phase; scans=$scanPasses"
   }
  }
}

$runner = if ($env:RUNNER_LABEL) { $env:RUNNER_LABEL } else { 'local' }
$highPressure = @($rows | Where-Object { $_.scanners -eq 16 -and $_.method -eq 'movefile' -and $_.outcome -eq 'access_denied' }).Count
$signal = if ($highPressure) { "REPRODUCED: $highPressure/$Runs high-pressure MoveFileEx runs returned Win32 5." } else {
    'NOT REPRODUCED under high pressure: this job cannot establish or rule out a POSIX mitigation.'
}
$summary = @(
    "## Rename pressure and POSIX comparison: $runner"
    ''
    $signal
    ''
    '| Scanners | Method | Win32 5 / valid runs | Frequency | Passed 100 rounds | Unsupported | Other / invalid |'
    '| --- | --- | --- | --- | --- | --- | --- |'
)
foreach ($scannerCount in $ScannerCounts) {
    foreach ($method in $methods) {
        $group = @($rows | Where-Object { $_.scanners -eq $scannerCount -and $_.method -eq $method })
        $denied = @($group | Where-Object outcome -eq 'access_denied').Count
        $passed = @($group | Where-Object outcome -eq 'not_reproduced').Count
        $unsupported = @($group | Where-Object outcome -eq 'unsupported').Count
        $invalid = $group.Count - $denied - $passed - $unsupported
        $valid = $denied + $passed
        $frequency = if ($valid) { '{0:P1}' -f ($denied / $valid) } else { 'N/A' }
        $summary += "| $scannerCount | $method | $denied / $valid | $frequency | $passed | $unsupported | $invalid |"
    }
}
$summary += @(
    ''
    'Frequency is per independent process directory, at most 100 rounds, stopped at first failure; not per syscall or OS-wide probability.'
    'The 16-scanner group runs first. Methods rotate each sample. All groups share this runner VM.'
    'Scanners normally recurse and close enumeration handles: no intentional retained handle, sleep or rename retry.'
    'infoex and posix use the same API and REPLACE_IF_EXISTS flag; only posix adds POSIX_SEMANTICS. Targets are absent, not replacement tests.'
    'Unsupported and invalid pressure are not passes. See CSV for failure phase and other error codes.'
    'This is an artificial contention experiment, not attribution of the original GCC incident or proof of a Windows regression.'
)
$summary | Set-Content -LiteralPath "$OutputDirectory/summary.md" -Encoding utf8
$summary | ForEach-Object { Write-Host $_ }
if ($env:GITHUB_STEP_SUMMARY) {
    $summary | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8
}
if (-not $highPressure) {
    Write-Warning $signal
    if ($env:GITHUB_ACTIONS) { Write-Host "::warning title=High-pressure reproduction missing::$signal" }
}
if ((Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash -ne $initialHash) { throw 'Executable hash changed.' }
if (@($rows | Where-Object { $_.outcome -notin @('access_denied', 'not_reproduced', 'unsupported') }).Count) {
    throw 'Some runs had other rename errors or invalid pressure; inspect CSV and logs.'
}
