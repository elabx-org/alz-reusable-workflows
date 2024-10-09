param (
    [Parameter(Mandatory = $true)]
    [string]$stateFilePath
)

$state = Get-Content $stateFilePath | ConvertFrom-Json
$checks = $state.check_results
$checks_failed = $false

foreach ($check in $checks) {
    if ($($check.status) -eq "pass") {
        Write-Output "$($check.config_addr) ✔"
    }
    else {
        $checks_failed = $true
        Write-Output "$($check.config_addr) ❌"
        foreach ($msg in $($check.objects[0].failure_messages)) {
            Write-Output "  - $($msg)"
        }
    }
}
if ($checks_failed) {
    exit 1
}