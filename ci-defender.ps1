param(
    [ValidateSet('as-is', 'on', 'off')][string]$State = 'as-is',
    [ValidateSet('before', 'configure', 'after')][string]$Phase = 'configure',
    [string]$OutputDirectory = "$PSScriptRoot/metadata/defender"
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'CI-only: refusing to query or change Defender outside a GitHub-hosted Windows runner.'
}
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory

function Save-State($name) {
    $snapshot = [pscustomobject]@{
        requested = $State
        phase = $name
        time = (Get-Date).ToString('o')
        status = Get-MpComputerStatus | Select-Object AMRunningMode, AMServiceEnabled, AntivirusEnabled,
            RealTimeProtectionEnabled, OnAccessProtectionEnabled, BehaviorMonitorEnabled, IoavProtectionEnabled,
            IsTamperProtected, AMProductVersion, AMEngineVersion, AntivirusSignatureVersion, AntivirusSignatureLastUpdated
        preference = Get-MpPreference | Select-Object DisableRealtimeMonitoring, DisableAutoExclusions,
            DisableBehaviorMonitoring, DisableIOAVProtection, RealTimeScanDirection, ExclusionPath, ExclusionProcess, ExclusionExtension
        service = Get-Service WinDefend | Select-Object Name, Status, StartType
    }
    $snapshot | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$OutputDirectory/$name.json"
    Write-Host "Defender requested=$State phase=$name effective_realtime=$($snapshot.status.RealTimeProtectionEnabled) mode=$($snapshot.status.AMRunningMode)"
    return $snapshot
}

function Test-State($snapshot) {
    $preference = $snapshot.preference
    $exclusions = @($preference.ExclusionPath) + @($preference.ExclusionProcess) + @($preference.ExclusionExtension)
    return ($snapshot.status.RealTimeProtectionEnabled -eq ($State -eq 'on') -and
        $snapshot.status.AMServiceEnabled -eq $true -and $snapshot.status.AntivirusEnabled -eq $true -and
        $snapshot.status.AMRunningMode -eq 'Normal' -and
        $preference.DisableRealtimeMonitoring -eq ($State -eq 'off') -and
        $preference.DisableAutoExclusions -eq $true -and
        @($exclusions | Where-Object { $_ }).Count -eq 0)
}

if ($Phase -eq 'before' -or $State -eq 'as-is') {
    $snapshot = Save-State $Phase
} elseif ($Phase -eq 'configure') {
    $snapshot = Save-State 'preconfigure'
    try {
        foreach ($name in @('ExclusionPath', 'ExclusionProcess', 'ExclusionExtension')) {
            $values = @($snapshot.preference.$name | Where-Object { $_ })
            if ($values.Count) {
                $remove = @{}
                $remove[$name] = $values
                Remove-MpPreference @remove
            }
        }
        Start-Service WinDefend
        Set-MpPreference -DisableAutoExclusions $true -DisableRealtimeMonitoring ($State -eq 'off')
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            $snapshot = [pscustomobject]@{ status = Get-MpComputerStatus; preference = Get-MpPreference }
            if (Test-State $snapshot) { break }
            Start-Sleep -Seconds 1
        } while ($timer.Elapsed.TotalSeconds -lt 30)
    } finally {
        $snapshot = Save-State $Phase
    }
    if (-not (Test-State $snapshot)) { throw 'INVALID EXPERIMENT: Defender state or exclusions did not match the request.' }
} else {
    $snapshot = Save-State $Phase
    if (-not (Test-State $snapshot)) { throw 'INVALID EXPERIMENT: Defender state changed during the workload.' }
}
if ($env:GITHUB_STEP_SUMMARY) {
    "Defender $Phase : requested=$State; effective realtime=$($snapshot.status.RealTimeProtectionEnabled); mode=$($snapshot.status.AMRunningMode)." |
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
}
