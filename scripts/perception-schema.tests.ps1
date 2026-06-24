# perception-schema.tests.ps1
# TDD test suite for perception-schema.ps1 — unified UI element schema
# RED phase: these tests MUST fail initially (module not yet implemented)
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

# Load module
try {
    . "$scriptDir\perception-schema.ps1"
    Write-Host "Loaded perception-schema.ps1`n"
} catch {
    Write-Host "ERROR: Failed to load perception-schema.ps1: $_`n"
    $global:fail += 8  # All 8 tests will fail
    Write-Host "RESULTS: $pass passed, $fail failed"
    exit $fail
}

# ============================================================
# Test 1: New-UiElement with all required fields produces a PSObject
# with 11 properties matching the schema
# ============================================================
Write-Host "=== Test 1: New-UiElement full construction ==="
$el = New-UiElement -Type 'button' -X 10 -Y 20 -W 100 -H 30 -Confidence 0.99 -Text 'Submit' -State 'enabled' -IsInteractive $true -Source 'uiAutomation' -Alternatives @() -DisplayIndex 0 -DpiScale 1.5 -ParentIndex -1

Assert-Equal "1a: type = button"      $el.type          "button"
Assert-Equal "1b: bbox.x = 10"        $el.bbox.x        10
Assert-Equal "1c: bbox.y = 20"        $el.bbox.y        20
Assert-Equal "1d: bbox.w = 100"       $el.bbox.w        100
Assert-Equal "1e: bbox.h = 30"        $el.bbox.h        30
Assert-Equal "1f: confidence = 0.99"  $el.confidence    0.99
Assert-Equal "1g: text = Submit"      $el.text          "Submit"
Assert-Equal "1h: state = enabled"    $el.state         "enabled"
Assert-True  "1i: isInteractive"      $el.isInteractive
Assert-Equal "1j: source = uiAutomation" $el.source     "uiAutomation"
Assert-Equal "1k: alternatives count=0"  $el.alternatives.Count  0
Assert-Equal "1l: displayIndex = 0"    $el.displayIndex  0
Assert-Equal "1m: dpiScale = 1.5"      $el.dpiScale      1.5
Assert-Equal "1n: parentIndex = -1"    $el.parentIndex   -1
# Verify exactly 11 NoteProperty members (type, bbox, confidence, text, state, isInteractive, source, alternatives, displayIndex, dpiScale, parentIndex)
$propCount = ($el | Get-Member -MemberType NoteProperty).Count
Assert-Equal "1o: exactly 11 properties" $propCount 11

# ============================================================
# Test 2: New-UiElement rejects type values outside the allowed enum
# ============================================================
Write-Host "`n=== Test 2: Invalid type rejection ==="
try {
    New-UiElement -Type "widget" -ErrorAction Stop 2>$null
    Assert-False "2: rejected invalid type 'widget'" $true  # should NOT reach here
} catch {
    Assert-True "2: rejected invalid type 'widget'" ($_.Exception.Message -match "widget|validate|enum|set|type" -or $_.FullyQualifiedErrorId -match "ParameterArgumentValidationError|ValidateSetFailure")
}

# ============================================================
# Test 3: New-UiElement rejects confidence outside [0.0, 1.0]
# ============================================================
Write-Host "`n=== Test 3: Invalid confidence rejection ==="
try {
    New-UiElement -Confidence 1.5 -ErrorAction Stop 2>$null
    Assert-False "3a: rejected confidence 1.5" $true
} catch {
    Assert-True "3a: rejected confidence 1.5" $true
}
try {
    New-UiElement -Confidence -0.5 -ErrorAction Stop 2>$null
    Assert-False "3b: rejected confidence -0.5" $true
} catch {
    Assert-True "3b: rejected confidence -0.5" $true
}

# ============================================================
# Test 4: New-UiElement with no parameters returns a valid element with defaults
# ============================================================
Write-Host "`n=== Test 4: Default element ==="
$def = New-UiElement
Assert-Equal "4a: default type = other"          $def.type          "other"
Assert-Equal "4b: default text = ''"             $def.text          ""
Assert-Equal "4c: default state = unknown"       $def.state         "unknown"
Assert-Equal "4d: default confidence = 0.0"      $def.confidence    0.0
Assert-False "4e: default isInteractive = false" $def.isInteractive
Assert-Equal "4f: default source = unknown"      $def.source        "unknown"
Assert-Equal "4g: default alternatives = @()"    $def.alternatives.Count  0
Assert-Equal "4h: default displayIndex = 0"      $def.displayIndex  0
Assert-Equal "4i: default dpiScale = 1.0"        $def.dpiScale      1.0
Assert-Equal "4j: default parentIndex = -1"      $def.parentIndex   -1
Assert-Equal "4k: default bbox.x = 0"            $def.bbox.x        0
Assert-Equal "4l: default bbox.y = 0"            $def.bbox.y        0

# ============================================================
# Test 5: Test-UiElement identifies a valid element as $true
# ============================================================
Write-Host "`n=== Test 5: Test-UiElement valid element ==="
$valid = New-UiElement -Type 'button' -Confidence 0.95 -Text 'OK'
Assert-True "5: Test-UiElement returns true" (Test-UiElement $valid)

# ============================================================
# Test 6: Test-UiElement identifies element missing 'bbox' field as $false
# ============================================================
Write-Host "`n=== Test 6: Test-UiElement invalid element (missing bbox) ==="
$invalid = @{ type = "button"; confidence = 0.5 }
Assert-False "6: Test-UiElement returns false for missing bbox" (Test-UiElement $invalid)

# ============================================================
# Test 7: ConvertTo-UiElementJson serializes with depth >= 5 without truncation
# ============================================================
Write-Host "`n=== Test 7: ConvertTo-UiElementJson depth ==="
$el7 = New-UiElement -Type 'textbox' -X 50 -Y 100 -W 200 -H 24 -Text 'Search...' -Source 'ocr'
$json = ConvertTo-UiElementJson @($el7) -Depth 10
# Check that bbox details are not truncated (i.e., the json contains nested properties)
Assert-True "7a: JSON contains 'Search...'" ($json -match 'Search\.\.\.')
Assert-True "7b: JSON contains nested x value" ($json -match '"x"\s*:\s*50')
Assert-True "7c: JSON contains nested y value" ($json -match '"y"\s*:\s*100')
Assert-True "7d: JSON contains nested w value" ($json -match '"w"\s*:\s*200')
Assert-True "7e: JSON contains confidence" ($json -match 'confidence.*0')

# ============================================================
# Test 8: ConvertTo-UiElementJson produces valid JSON
# ============================================================
Write-Host "`n=== Test 8: Valid JSON round-trip ==="
$el8 = New-UiElement -Type 'icon' -X 10 -Y 10 -W 32 -H 32 -Confidence 0.85 -Source 'templateMatch'
$json8 = ConvertTo-UiElementJson @($el8) -Depth 10
try {
    $parsed = $json8 | ConvertFrom-Json
    Assert-Equal "8a: parsed type = icon" $parsed.type "icon"
    Assert-Equal "8b: parsed bbox.x = 10" $parsed.bbox.x 10
    Assert-Equal "8c: parsed confidence = 0.85" $parsed.confidence 0.85
} catch {
    Assert-True "8: valid JSON round-trip" $false
}

# ============================================================
# Summary
# ============================================================
Write-Host "`n========================================"
Write-Host "RESULTS: $pass passed, $fail failed"
Write-Host "========================================"
exit $fail
