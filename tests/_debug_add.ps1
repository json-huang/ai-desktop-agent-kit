$ErrorActionPreference = "Stop"
. "$PSScriptRoot\..\scripts\perception-schema.ps1"
. "$PSScriptRoot\..\scripts\fusion.ps1"

$uia = @(New-UiElement -Type "button" -X 10 -Y 20 -W 80 -H 30 -Confidence 0.99 -Text "File" -Source "uiAutomation")
$ocr = @(New-UiElement -Type "label" -X 15 -Y 22 -W 70 -H 26 -Confidence 0.85 -Text "File" -Source "ocr")

Write-Output "Pre-merge:"
Write-Output "  UIA type: $($uia[0].GetType().FullName)"
Write-Output "  UIA props: $((Get-Member -InputObject $uia[0] -MemberType NoteProperty | ForEach-Object { $_.Name }) -join ', ')"
Write-Output "  UIA.alternatives: $($uia[0].alternatives)"
Write-Output "  UIA.alternatives.Count: $($uia[0].alternatives.Count)"

# Compute IoU
$iou = Compute-IoU $uia[0].bbox $ocr[0].bbox
Write-Output "  IoU: $iou"

# Direct test of alternatives modification on the raw object
$test = New-UiElement -Type "button" -X 10 -Y 20 -W 80 -H 30 -Confidence 0.99 -Text "File" -Source "uiAutomation"
Write-Output ""
Write-Output "Direct test on fresh object:"
Write-Output "  Type: $($test.GetType().FullName)"
Write-Output "  Alt count before: $($test.alternatives.Count)"

try {
    $test.alternatives = @($test.alternatives) + @($ocr[0])
    Write-Output "  Alt count after: $($test.alternatives.Count)"
    Write-Output "  Alt[0] text: $($test.alternatives[0].text)"
    Write-Output "  Alt[0] source: $($test.alternatives[0].source)"
} catch {
    Write-Output "  REASSIGN FAILED: $_"
}

# Test if we can use Add-Member to modify
Write-Output ""
Write-Output "Add-Member approach:"
$test2 = New-UiElement -Type "button" -X 10 -Y 20 -W 80 -H 30 -Confidence 0.99 -Text "File" -Source "uiAutomation"
try {
    $test2 | Add-Member -MemberType NoteProperty -Name "alternatives" -Value @($test2.alternatives) + @($ocr[0]) -Force
    Write-Output "  Add-Member SUCCEEDED"
    Write-Output "  Alt count: $($test2.alternatives.Count)"
} catch {
    Write-Output "  Add-Member FAILED: $_"
}

# Now try Add-TierElements directly
Write-Output ""
Write-Output "Add-TierElements test:"
try {
    $result = Add-TierElements -Existing $uia -New $ocr
    Write-Output "  Result count: $($result.Count)"
} catch {
    Write-Output "  Add-TierElements FAILED: $_"
    Write-Output "  Stack: $($_.ScriptStackTrace)"
}
