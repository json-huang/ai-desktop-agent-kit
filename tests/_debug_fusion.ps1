$ErrorActionPreference = "Continue"
. "$PSScriptRoot\..\scripts\perception-schema.ps1"
. "$PSScriptRoot\..\scripts\fusion.ps1"

# Test 1: Non-overlapping
Write-Output "=== Test: Non-overlapping ==="
$uia1 = @(New-UiElement -Type "button" -X 10 -Y 10 -W 80 -H 30 -Confidence 0.99 -Text "File" -Source "uiAutomation" -State "enabled" -IsInteractive $true)
$ocr1 = @(New-UiElement -Type "label" -X 200 -Y 10 -W 60 -H 20 -Confidence 0.85 -Text "Document" -Source "ocr")
$merged1 = Merge-PerceptionTiers -UiaElements $uia1 -OcrElements $ocr1
Write-Output "  Total: $($merged1.Count)"
$uiaCt = @($merged1 | Where-Object { $_.source -eq "uiAutomation" }).Count
$ocrCt = @($merged1 | Where-Object { $_.source -eq "ocr" }).Count
Write-Output "  UIA: $uiaCt | OCR: $ocrCt"

# Test 2: Deduplication
Write-Output ""
Write-Output "=== Test: Deduplication ==="
$uia2 = @(New-UiElement -Type "button" -X 10 -Y 20 -W 80 -H 30 -Confidence 0.99 -Text "File" -Source "uiAutomation")
$ocr2 = @(New-UiElement -Type "label" -X 15 -Y 22 -W 70 -H 26 -Confidence 0.85 -Text "File" -Source "ocr")
try {
    $merged2 = Merge-PerceptionTiers -UiaElements $uia2 -OcrElements $ocr2
    Write-Output "  Total: $($merged2.Count)"
    $fileEls = @($merged2 | Where-Object { $_.text -eq "File" })
    Write-Output "  File elements: $($fileEls.Count)"
    if ($fileEls.Count -gt 0) {
        $f = $fileEls[0]
        Write-Output "  Source: $($f.source)"
        Write-Output "  Alt count: $($f.alternatives.Count)"
        foreach ($a in $f.alternatives) {
            Write-Output "    alt: $($a.text) / $($a.source)"
        }
    }
} catch {
    Write-Output "  FAILED: $_"
}

# Test 3: Empty input
Write-Output ""
Write-Output "=== Test: Empty input ==="
$merged3 = Merge-PerceptionTiers
Write-Output "  Total: $($merged3.Count)"
Write-Output "  Root type: $($merged3[0].type)"
Write-Output "  Root parentIndex: $($merged3[0].parentIndex)"

# Test 4: Conflict
Write-Output ""
Write-Output "=== Test: Conflict ==="
$uia4 = @(New-UiElement -Type "button" -X 10 -Y 20 -W 80 -H 30 -Confidence 0.99 -Text "Save" -Source "uiAutomation")
$ocr4 = @(New-UiElement -Type "label" -X 15 -Y 22 -W 70 -H 26 -Confidence 0.85 -Text "Save As" -Source "ocr")
$merged4 = Merge-PerceptionTiers -UiaElements $uia4 -OcrElements $ocr4
Write-Output "  Total: $($merged4.Count)"
$saveCt = @($merged4 | Where-Object { $_.text -eq "Save" }).Count
$saveAsCt = @($merged4 | Where-Object { $_.text -eq "Save As" }).Count
Write-Output "  Save: $saveCt | Save As: $saveAsCt"
$saveEl = @($merged4 | Where-Object { $_.text -eq "Save" })[0]
Write-Output "  Save alt count: $($saveEl.alternatives.Count)"

# Test 5: ParentIndex
Write-Output ""
Write-Output "=== Test: ParentIndex ==="
$uia5 = @(New-UiElement -Type "window" -X 0 -Y 0 -W 800 -H 600 -Confidence 0.99 -Source "uiAutomation" -ParentIndex -1)
$ocr5 = @(New-UiElement -Type "label" -X 200 -Y 100 -W 100 -H 20 -Confidence 0.85 -Text "Hello" -Source "ocr")
$merged5 = Merge-PerceptionTiers -UiaElements $uia5 -OcrElements $ocr5
$ocrMerged = @($merged5 | Where-Object { $_.source -eq "ocr" })[0]
Write-Output "  OCR parentIndex: $($ocrMerged.parentIndex)"
Write-Output "  Root index: verify parentIndex maps to root"
