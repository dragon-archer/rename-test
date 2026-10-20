param(
    [Parameter(Mandatory = $true)][string]$Executable,
    [ValidateSet('movefile', 'infoex', 'posix')][string]$Method = 'infoex',
    [string]$TestParent = "$PSScriptRoot/work",
    [string]$OutputDirectory,
    [ValidateRange(1, 100)][int]$Sample = 1,
    [ValidateSet('none', 'notifications', 'ancestor', 'directory', 'descendant', 'recursive')]
    [string[]]$Scopes = @('none', 'ancestor', 'directory', 'descendant', 'recursive')
)

$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$TestParent = (Resolve-Path -LiteralPath $TestParent).Path
$hash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash
$identifier = [guid]::NewGuid().ToString('N')
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $PSScriptRoot ('work/scan-depth-' + $identifier) }
$evidence = New-Item -ItemType Directory -Path $OutputDirectory
$testDirectory = New-Item -ItemType Directory -Path (Join-Path $TestParent (
    'rename-test-scan-' + $identifier))
[pscustomobject]@{
    executable = $Executable
    executable_sha256 = $hash
    method = $Method
    sample = $Sample
    test_directory = $testDirectory.FullName
    note = 'Artificial enumeration control; scanning starts after the probe header. Not a natural reproduction rate.'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $evidence.FullName 'environment.json')
Write-Host "Evidence: $($evidence.FullName)"
Write-Host "Test directory: $($testDirectory.FullName)"
$rows = @()
for ($offset = 0; $offset -lt $Scopes.Count; ++$offset) {
    $scope = $Scopes[($Sample - 1 + $offset) % $Scopes.Count]
    $directory = New-Item -ItemType Directory -Path (Join-Path $testDirectory.FullName $scope)
    $stdout = Join-Path $evidence.FullName "$scope-stdout.log"
    $stderr = Join-Path $evidence.FullName "$scope-stderr.log"
    $watcher = $null
    $subscriptions = @()
    $events = @()
    $watcherErrors = 0
    try {
    if ($scope -eq 'notifications') {
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $directory.FullName
        $watcher.IncludeSubdirectories = $true
        $watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, DirectoryName'
        $watcher.InternalBufferSize = 65536
        foreach ($eventName in @('Created', 'Renamed', 'Error')) {
            $source = "scan-depth-$identifier-$eventName"
            Register-ObjectEvent -InputObject $watcher -EventName $eventName -SourceIdentifier $source | Out-Null
            $subscriptions += $source
        }
        $watcher.EnableRaisingEvents = $true
    }
    $process = Start-Process -FilePath $Executable -ArgumentList $Method `
        -WorkingDirectory $directory.FullName -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr -NoNewWindow -PassThru
    $null = $process.Handle
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $root = $null
    $passes = 0
    $entries = 0
    $vanished = 0
    do {
        if ($scope -in @('none', 'notifications')) {
            $null = $process.WaitForExit(15000)
        } else {
            if (-not $root) {
                $header = Get-Content -LiteralPath $stdout -TotalCount 1
                if ($header -match '^Work directory: ([^;]+); method=') {
                    $root = Join-Path $directory.FullName $Matches[1]
                }
            }
            if ($root) {
                $paths = switch ($scope) {
                    'ancestor' { $directory.FullName }
                    'directory' { Join-Path $root 'gcc'; Join-Path $root 'stage1-gcc' }
                    'descendant' { Join-Path $root 'gcc/child'; Join-Path $root 'stage1-gcc/child' }
                    'recursive' { $root }
                }
                $option = if ($scope -eq 'recursive') {
                    [System.IO.SearchOption]::AllDirectories
                } else {
                    [System.IO.SearchOption]::TopDirectoryOnly
                }
                foreach ($path in $paths) {
                    try {
                        $entries += [System.IO.Directory]::GetFileSystemEntries($path, '*', $option).Length
                        ++$passes
                    } catch [System.IO.IOException] {
                        if (($_.Exception.HResult -band 65535) -notin @(2, 3)) { throw }
                        ++$vanished
                    }
                }
            }
        }
        $process.Refresh()
    } while (-not $process.HasExited -and $timer.Elapsed.TotalSeconds -lt 15)
    if (-not $process.HasExited) {
        throw "Diagnostic budget exceeded; process $($process.Id) has not been terminated."
    }
    $process.WaitForExit()
    if ($watcher) {
        $watcher.EnableRaisingEvents = $false
        $events = @(foreach ($source in $subscriptions) { Get-Event -SourceIdentifier $source -ErrorAction SilentlyContinue })
        $watcherErrors = @($events | Where-Object SourceIdentifier -like '*-Error').Count
        $events | Select-Object SourceIdentifier, TimeGenerated,
            @{Name='path'; Expression={$_.SourceEventArgs.FullPath}} |
            Export-Csv -NoTypeInformation -LiteralPath (Join-Path $evidence.FullName 'notifications-events.csv')
    }
    $output = (Get-Content -LiteralPath $stdout, $stderr) -join "`n"
    if ($output -notmatch '(?m)^RENAME_RESULT attempts=(\d+) succeeded=(\d+) denied=(\d+) other=(\d+)\r?$') {
        throw "Missing fixed-attempt result for $scope. Check the executable version and raw logs."
    }
    $attempts, $succeeded, $denied, $other = 1..4 | ForEach-Object { [int]$Matches[$_] }
    if ($attempts -ne 100 -or $attempts -ne $succeeded + $denied + $other -or
        $process.ExitCode -ne [int](($denied + $other) -gt 0)) { throw 'Invalid probe counts or exit code.' }
    if ($scope -notin @('none', 'notifications') -and $passes -eq 0) { throw "No completed enumeration for $scope." }
    if ($scope -eq 'notifications' -and ($events.Count -eq 0 -or $watcherErrors)) {
        throw 'Notification control had no events or reported a watcher error.'
    }
    $openDenied = @([regex]::Matches($output, '(?m)^RENAME_FAILURE .* error=5 method=\w+ phase=open-source\r?$')).Count
    $renameDenied = @([regex]::Matches($output, '(?m)^RENAME_FAILURE .* error=5 method=\w+ phase=(MoveFileEx|FileRenameInfoEx)\r?$')).Count
    if ($openDenied + $renameDenied -ne $denied) { throw 'Denied calls do not match phase counts.' }
    $rows += [pscustomobject]@{
        sample = $Sample; scope = $scope; method = $Method; attempts = $attempts
        succeeded = $succeeded; denied = $denied; other = $other
        scan_passes = $passes; scan_entries = $entries; vanished_paths = $vanished
        notification_events = $events.Count; watcher_errors = $watcherErrors
        open_denied = $openDenied; rename_denied = $renameDenied
    }
    $rows | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $evidence.FullName 'results.csv')
    Write-Host "$scope / $Method : denied=$denied/$attempts other=$other scans=$passes entries=$entries"
    $process.Dispose()
    if ($other) { throw 'Non-target rename error; inspect raw logs.' }
    } finally {
        if ($watcher) { $watcher.Dispose() }
        foreach ($source in $subscriptions) {
            Unregister-Event -SourceIdentifier $source
            Remove-Event -SourceIdentifier $source -ErrorAction SilentlyContinue
        }
    }
}
if ((Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash -ne $hash) {
    throw 'Executable hash changed.'
}
