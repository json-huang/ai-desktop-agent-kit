$ErrorActionPreference = "Continue"
. "$PSScriptRoot\..\scripts\perception-schema.ps1"
. "$PSScriptRoot\..\scripts\fusion.ps1"

$uia = @(New-UiElement -Type "button" -X 10 -Y 20 -W 80 -H 30 -Confidence 0.99 -Text "File" -Source "uiAutomation")
$ocr = @(New-UiElement -Type "label" -X 15 -Y 22 -W 70 -H 26 -Confidence 0.85 -Text "File" -Source "ocr")

Write-Output "--- Before merge ---"
Write-Output "UIA[0] type: $($uia[0].GetType().FullName)"
Write-Output "UIA[0] alternatives type: $($uia[0].alternatives.GetType().FullName)"
Write-Output "UIA[0] alternatives value: $($uia[0].alternatives)"
Write-Output "UIA[0] alternatives count: $($uia[0].alternatives.Count)"

# Try adding to alternatives directly (pre-merge)
try {
    $uia[0].alternatives = @($uia[0].alternatives) + @($ocr[0])
    Write-Output "Direct reassign SUCCEEDED. Count: $($uia[0].alternatives.Count)"
} catch {
    Write-Output "Direct reassign FAILED: $_"
}

# Now try the merge
Write-Output ""
Write-Output "--- Merge ---"
try {
    $merged = Merge-PerceptionTiers -UiaElements $uia -OcrElements $ocr
    Write-Output "Merge SUCCEEDED. Count: $($merged.Count)"
    $fileEls = $merged | Where-Object { $_.text -eq "File" }
    Write-Output "File elements: $($fileEls.Count)"
    if ($fileEls.Count -gt 0) {
        Write-Output "Source: $($fileEls[0].source)"
        Write-Output "Alt count: $($fileEls[0].alternatives.Count)"
    }
} catch {
    Write-Output "Merge FAILED: $_"
    Write-Output "Stack: $($_.ScriptStackTrace)"
}
