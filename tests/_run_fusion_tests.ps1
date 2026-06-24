$ErrorActionPreference = "Stop"
$result = Invoke-Pester -Script "$PSScriptRoot\fusion.test.ps1" -PassThru -Quiet
Write-Output "PASS: $($result.PassedCount) tests passed"
if ($result.FailedCount -gt 0) {
    Write-Output "FAIL: $($result.FailedCount) tests failed"
    foreach ($tr in $result.TestResult) {
        if (-not $tr.Passed) {
            Write-Output "  - $($tr.Describe): $($tr.Name) -- $($tr.FailureMessage)"
        }
    }
}
