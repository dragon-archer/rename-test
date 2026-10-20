param(
    [ValidateRange(1, 100)][int]$Runs = 3,
    [string]$Executable = "$PSScriptRoot/build/rename-win32.exe",
    [string]$WorkspaceParent = "$PSScriptRoot/work",
    [string]$TemporaryParent = [System.IO.Path]::GetTempPath(),
    [string]$OutputDirectory = "$PSScriptRoot/results-depth"
)

$ErrorActionPreference = 'Stop'
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$null = New-Item -ItemType Directory -Force -Path $WorkspaceParent
$WorkspaceParent = (Resolve-Path -LiteralPath $WorkspaceParent).Path
$TemporaryParent = (Resolve-Path -LiteralPath $TemporaryParent).Path
$OutputDirectory = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$initialHash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash
$locations = @(
    [pscustomobject]@{ name = 'workspace'; path = $WorkspaceParent }
    [pscustomobject]@{ name = 'temporary'; path = $TemporaryParent }
)
$scopes = @('none', 'notifications', 'ancestor', 'directory', 'descendant')
[pscustomobject]@{
    executable = $Executable
    executable_sha256 = $initialHash
    runs = $Runs
    method = 'infoex'
    locations = $locations
    scopes = $scopes
    note = 'Scope and location order rotate. One VM per job; calls within a run are correlated.'
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$OutputDirectory/environment.json"
$rows = @()
for ($sample = 1; $sample -le $Runs; ++$sample) {
    for ($offset = 0; $offset -lt $locations.Count; ++$offset) {
        $location = $locations[($sample - 1 + $offset) % $locations.Count]
        $caseDirectory = Join-Path $OutputDirectory "run-$sample-$($location.name)"
        & "$PSScriptRoot/test-scan-depth.ps1" -Executable $Executable -Method infoex `
            -TestParent $location.path -OutputDirectory $caseDirectory -Sample $sample -Scopes $scopes
        $caseRows = @(Import-Csv -LiteralPath "$caseDirectory/results.csv")
        if ($caseRows.Count -ne $scopes.Count) { throw "Incomplete depth comparison: $caseDirectory" }
        foreach ($row in $caseRows) {
            $rows += [pscustomobject]@{
                sample = $sample; location = $location.name; scope = $row.scope; method = $row.method
                attempts = [int]$row.attempts; succeeded = [int]$row.succeeded
                denied = [int]$row.denied; other = [int]$row.other
                open_denied = [int]$row.open_denied; rename_denied = [int]$row.rename_denied
                scan_passes = [long]$row.scan_passes; scan_entries = [long]$row.scan_entries
                vanished_paths = [long]$row.vanished_paths
                notification_events = [long]$row.notification_events; watcher_errors = [int]$row.watcher_errors
            }
        }
        $rows | Export-Csv -NoTypeInformation -LiteralPath "$OutputDirectory/results.csv"
    }
}
$summary = @(
    "## Directory access depth: $env:RUNNER_LABEL"
    ''
    "Workspace parent: $WorkspaceParent"
    "Temporary parent: $TemporaryParent"
    ''
    '| Location | Scope | Completed runs | Win32 5 / attempts | Observed fraction | Open-source denials | Rename denials | Notification events |'
    '| --- | --- | --- | --- | --- | --- | --- | --- |'
)
foreach ($location in $locations) {
    foreach ($scope in $scopes) {
        $group = @($rows | Where-Object { $_.location -eq $location.name -and $_.scope -eq $scope })
        $attempts = [long]($group | Measure-Object attempts -Sum).Sum
        $denied = [long]($group | Measure-Object denied -Sum).Sum
        $opened = [long]($group | Measure-Object open_denied -Sum).Sum
        $renamed = [long]($group | Measure-Object rename_denied -Sum).Sum
        $events = [long]($group | Measure-Object notification_events -Sum).Sum
        $rate = '{0:P1}' -f ($denied / $attempts)
        $summary += "| $($location.name) | $scope | $($group.Count) | $denied / $attempts | $rate | $opened | $renamed | $events |"
    }
}
$summary += @(
    ''
    'notifications only receives recursive events on an ancestor; it does not enumerate descendants in a callback.'
    'ancestor and directory enumerate shallowly; descendant enters gcc/child or stage1-gcc/child.'
    'Tests use FileRenameInfoEx to distinguish source-open from rename failure; other APIs have a separate 0/1-scanner control.'
    'Artificial scanning is not identification of the actual holder. Baseline denials indicate an uncontrolled background condition.'
    'Fractions describe correlated calls, not independent probabilities or a demonstrated Windows regression.'
)
$summary | Set-Content -LiteralPath "$OutputDirectory/summary.md" -Encoding utf8
$summary | ForEach-Object { Write-Host $_ }
if ($env:GITHUB_STEP_SUMMARY) { $summary | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding utf8 }
if ((Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash -ne $initialHash) {
    throw 'Executable hash changed during the comparison.'
}
