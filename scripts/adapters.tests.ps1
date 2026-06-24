# adapters.tests.ps1
# TDD test suite for ocr-adapter.ps1 and template-adapter.ps1
# RED phase: these tests MUST fail initially (adapters not yet implemented)
$ErrorActionPreference = "Continue"
$scriptDir = Split-Path $PSCommandPath -Parent

$pass = 0
$fail = 0

function Assert-Equal($name, $actual, $expected) {
    if ($actual -eq $expected) {
        Write-Host "  PASS: $name" -ForegroundColor Green
        $global:pass++
    } else {
        Write-Host "  FAIL: $name — expected [$expected], got [$actual]" -ForegroundColor Red
        $global:fail++
    }
}

function Assert-True($name, $result) {
    if ($result) {
        Write-Host "  PASS: $name" -ForegroundColor Green
        $global:pass++
    } else {
        Write-Host "  FAIL: $name — expected true, got false" -ForegroundColor Red
        $global:fail++
    }
}

function Assert-False($name, $result) {
    if (-not $result) {
        Write-Host "  PASS: $name" -ForegroundColor Green
        $global:pass++
    } else {
        Write-Host "  FAIL: $name — expected false, got true" -ForegroundColor Red
        $global:fail++
    }
}

# Load both adapters (will fail if they don't exist — RED phase)
$ocrLoaded = $false
$templateLoaded = $false

try {
    . "$scriptDir\ocr-adapter.ps1"
    $ocrLoaded = $true
    Write-Host "Loaded ocr-adapter.ps1"
} catch {
    Write-Host "ERROR: Failed to load ocr-adapter.ps1: $_"
}

try {
    . "$scriptDir\template-adapter.ps1"
    $templateLoaded = $true
    Write-Host "Loaded template-adapter.ps1"
} catch {
    Write-Host "ERROR: Failed to load template-adapter.ps1: $_"
}

Write-Host ""

# ============================================================
# Build mock data helpers
# ============================================================
function New-MockOcrLine($Text, $Left, $Top, $Width, $Height) {
    return [PSCustomObject]@{ Text = $Text; Left = $Left; Top = $Top; Width = $Width; Height = $Height }
}

function New-MockMatchResult($X, $Y, $Score, $TemplateW, $TemplateH) {
    return [PSCustomObject]@{ X = $X; Y = $Y; Score = $Score; TemplateW = $TemplateW; TemplateH = $TemplateH }
}

# ============================================================
# OCR Adapter Tests
# ============================================================
Write-Host "========== OCR Adapter Tests =========="

if ($ocrLoaded) {

    # --- Test 1: Single OcrLine produces one UiElement ---
    Write-Host "`n--- Test 1: Single OcrLine -> UiElement ---"
    $line1 = New-MockOcrLine -Text "File" -Left 10 -Top 20 -Width 80 -Height 30
    $result1 = ConvertFrom-OcrResult -OcrLines @($line1)
    Assert-Equal "1a: array count = 1" $result1.Count 1
    if ($result1.Count -ge 1) {
        Assert-Equal "1b: type = label" $result1[0].type "label"
        Assert-Equal "1c: bbox.x = 10" $result1[0].bbox.x 10
        Assert-Equal "1d: bbox.y = 20" $result1[0].bbox.y 20
        Assert-Equal "1e: bbox.w = 80" $result1[0].bbox.w 80
        Assert-Equal "1f: bbox.h = 30" $result1[0].bbox.h 30
        Assert-Equal "1g: text = File" $result1[0].text "File"
        Assert-Equal "1h: confidence = 0.85" $result1[0].confidence 0.85
        Assert-Equal "1i: source = ocr" $result1[0].source "ocr"
        Assert-Equal "1j: state = unknown" $result1[0].state "unknown"
        Assert-False "1k: isInteractive = false" $result1[0].isInteractive
    }

    # --- Test 2: Noise filter — discard < 8x8 pixels ---
    Write-Host "`n--- Test 2: Noise filter (< 8x8 pixels) ---"
    $lineSmall = New-MockOcrLine -Text "." -Left 5 -Top 5 -Width 5 -Height 5
    $lineSmall2 = New-MockOcrLine -Text "a" -Left 10 -Top 10 -Width 10 -Height 4
    $lineBig = New-MockOcrLine -Text "OK" -Left 20 -Top 20 -Width 8 -Height 8
    $result2 = ConvertFrom-OcrResult -OcrLines @($lineSmall, $lineSmall2, $lineBig)
    Assert-Equal "2a: small (5x5) discarded, big kept, count = 1" $result2.Count 1
    if ($result2.Count -ge 1) {
        Assert-Equal "2b: kept text = OK" $result2[0].text "OK"
    }

    # --- Test 3: Deduplication — overlap >= 80% ---
    Write-Host "`n--- Test 3: Deduplication (IoU >= 80%) ---"
    # Two lines with 85% overlap, same text
    $lineA = New-MockOcrLine -Text "Save" -Left 100 -Top 50 -Width 60 -Height 20
    $lineB = New-MockOcrLine -Text "Save" -Left 105 -Top 52 -Width 55 -Height 18  # ~85% overlap
    $result3 = ConvertFrom-OcrResult -OcrLines @($lineA, $lineB)
    Assert-Equal "3a: duplicates merged, count = 1" $result3.Count 1
    if ($result3.Count -ge 1) {
        Assert-Equal "3b: kept text = Save" $result3[0].text "Save"
        # Should keep the larger area (lineA: 60*20=1200 > lineB: 55*18=990)
        Assert-Equal "3c: bbox.w = 60 (larger kept)" $result3[0].bbox.w 60
    }

    # --- Test 6: Empty OcrResult returns @() ---
    Write-Host "`n--- Test 6: Empty OcrResult -> @() ---"
    $result6 = ConvertFrom-OcrResult -OcrLines @()
    Assert-Equal "6a: empty input returns empty array" $result6.Count 0

} else {
    Write-Host "SKIP: ocr-adapter.ps1 not loaded — marking 7 tests as failed"
    $fail += 17  # approximate number of OCR test assertions
}

# ============================================================
# Template Match Adapter Tests
# ============================================================
Write-Host "`n========== Template Match Adapter Tests =========="

if ($templateLoaded) {

    # --- Test 4: MatchResult -> UiElement type=icon ---
    Write-Host "`n--- Test 4: MatchResult -> UiElement ---"
    $match1 = New-MockMatchResult -X 100 -Y 200 -Score 0.85 -TemplateW 32 -TemplateH 32
    $result4 = ConvertFrom-TemplateMatch -Matches @($match1) -Threshold 0.7
    Assert-Equal "4a: array count = 1" $result4.Count 1
    if ($result4.Count -ge 1) {
        Assert-Equal "4b: type = icon" $result4[0].type "icon"
        Assert-Equal "4c: bbox.x = 100" $result4[0].bbox.x 100
        Assert-Equal "4d: bbox.y = 200" $result4[0].bbox.y 200
        Assert-Equal "4e: bbox.w = 32" $result4[0].bbox.w 32
        Assert-Equal "4f: bbox.h = 32" $result4[0].bbox.h 32
        Assert-Equal "4g: confidence = 0.85" $result4[0].confidence 0.85
        Assert-Equal "4h: source = templateMatch" $result4[0].source "templateMatch"
        Assert-Equal "4i: text = ''" $result4[0].text ""
        Assert-True  "4j: isInteractive = true" $result4[0].isInteractive
    }

    # --- Test 5: Score below threshold -> empty array ---
    Write-Host "`n--- Test 5: Below threshold filtered ---"
    $matchLow = New-MockMatchResult -X 50 -Y 50 -Score 0.65 -TemplateW 20 -TemplateH 20
    $result5 = ConvertFrom-TemplateMatch -Matches @($matchLow) -Threshold 0.7
    Assert-Equal "5a: below threshold returns empty" $result5.Count 0

    # --- Test 7: Empty matches -> @() ---
    Write-Host "`n--- Test 7: Empty matches -> @() ---"
    $result7 = ConvertFrom-TemplateMatch -Matches @() -Threshold 0.7
    Assert-Equal "7a: empty input returns empty array" $result7.Count 0

} else {
    Write-Host "SKIP: template-adapter.ps1 not loaded — marking 7 tests as failed"
    $fail += 13  # approximate number of template test assertions
}

# ============================================================
# Summary
# ============================================================
Write-Host "`n========================================"
Write-Host "RESULTS: $pass passed, $fail failed"
Write-Host "========================================"
exit $fail
