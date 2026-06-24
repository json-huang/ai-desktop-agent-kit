# Coordinate Scaling Module Tests
# Tests Compute-MaxApiFit, ConvertFrom-ApiCoordinates, and ConvertFrom-ApiBbox
# from the coordinate-scaling.ps1 module.
#
# Usage:
#   powershell -NoProfile -File "C:\Users\DBA126\.claude\tests\coordinate-scaling.test.ps1"
#   OR: Invoke-Pester .\tests\coordinate-scaling.test.ps1

param(
    [switch]$UsePester
)

$modulePath = "C:\Users\DBA126\.claude\scripts\coordinate-scaling.ps1"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path $modulePath)) {
    Write-Error "Module not found: $modulePath"
    exit 1
}

# Dot-source the module
. $modulePath

$passCount = 0
$failCount = 0
$totalTests = 0

function Assert-Equal {
    param($Expected, $Actual, $TestName)
    $script:totalTests++
    if ($Expected -eq $Actual) {
        $script:passCount++
        Write-Host "  PASS: $TestName" -ForegroundColor Green
    } else {
        $script:failCount++
        Write-Host "  FAIL: $TestName — Expected: $Expected, Got: $Actual" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=== Test Suite: Compute-MaxApiFit ==="

# Test 1: 3840x2160 (4K landscape) with 4.6 family limits
# Formula: pixel budget sqrt(1.15M / aspect) is binding constraint (1430x804)
$w, $h = Compute-MaxApiFit 3840 2160
Assert-Equal 1430 $w "Test 1: Compute-MaxApiFit 3840x2160 -> width=1430"
Assert-Equal 804 $h "Test 1: Compute-MaxApiFit 3840x2160 -> height=804"

# Test 2: 1920x1080 (FHD landscape) with 4.6 family limits
# Same pixel budget constraint applies (clamped to native: 1430 <= 1920, 804 <= 1080)
$w, $h = Compute-MaxApiFit 1920 1080
Assert-Equal 1430 $w "Test 2: Compute-MaxApiFit 1920x1080 -> width=1430"
Assert-Equal 804 $h "Test 2: Compute-MaxApiFit 1920x1080 -> height=804"

# Test 3: 2560x1440 (QHD) with 4.6 family limits
# Pixel budget constraint (1430x804) still binding, both within native dims
$w, $h = Compute-MaxApiFit 2560 1440
Assert-Equal 1430 $w "Test 3: Compute-MaxApiFit 2560x1440 -> width=1430"
Assert-Equal 804 $h "Test 3: Compute-MaxApiFit 2560x1440 -> height=804"

# Test 4: 1080x1920 (portrait) with 4.6 family limits
# Portrait: pixel budget gives 804x1430, both within native dims
$w, $h = Compute-MaxApiFit 1080 1920
Assert-Equal 804 $w "Test 4: Compute-MaxApiFit 1080x1920 -> width=804"
Assert-Equal 1430 $h "Test 4: Compute-MaxApiFit 1080x1920 -> height=1430"

# Test 5: 1280x720 (already fits) — not upscaled
$w, $h = Compute-MaxApiFit 1280 720
Assert-Equal 1280 $w "Test 5: Compute-MaxApiFit 1280x720 -> width=1280 (no upscale)"
Assert-Equal 720 $h "Test 5: Compute-MaxApiFit 1280x720 -> height=720 (no upscale)"

Write-Host ""
Write-Host "=== Test Suite: ConvertFrom-ApiCoordinates ==="

# Test 6: (600,400) from 1280x720 display to 3840x2160 screen -> (1800, 1200)
$r = ConvertFrom-ApiCoordinates 600 400 1280 720 3840 2160
Assert-Equal 1800 $r.x "Test 6: ConvertFrom-ApiCoordinates (600,400) 1280x720->3840x2160 x=1800"
Assert-Equal 1200 $r.y "Test 6: ConvertFrom-ApiCoordinates (600,400) 1280x720->3840x2160 y=1200"

# Test 7: (640,360) from 1280x720 to 1920x1080 -> (960, 540)
$r = ConvertFrom-ApiCoordinates 640 360 1280 720 1920 1080
Assert-Equal 960 $r.x "Test 7: ConvertFrom-ApiCoordinates (640,360) 1280x720->1920x1080 x=960"
Assert-Equal 540 $r.y "Test 7: ConvertFrom-ApiCoordinates (640,360) 1280x720->1920x1080 y=540"

# Test 8: (0,0) origin -> (0,0) always
$r = ConvertFrom-ApiCoordinates 0 0 1280 720 3840 2160
Assert-Equal 0 $r.x "Test 8: ConvertFrom-ApiCoordinates (0,0) -> x=0"
Assert-Equal 0 $r.y "Test 8: ConvertFrom-ApiCoordinates (0,0) -> y=0"

# Test 9: (1280,720) max corner -> (3840,2160)
$r = ConvertFrom-ApiCoordinates 1280 720 1280 720 3840 2160
Assert-Equal 3840 $r.x "Test 9: ConvertFrom-ApiCoordinates (1280,720) max->3840x2160 x=3840"
Assert-Equal 2160 $r.y "Test 9: ConvertFrom-ApiCoordinates (1280,720) max->3840x2160 y=2160"

# Test 10: Opus 4.7 limits: 3840x2160 fits within (2576, 1449)
$w, $h = Compute-MaxApiFit 3840 2160 -MaxLongEdge 2576 -MaxPixels 3750000
Assert-Equal 2576 $w "Test 10: Compute-MaxApiFit 3840x2160 Opus4.7 -> width=2576"
Assert-Equal 1449 $h "Test 10: Compute-MaxApiFit 3840x2160 Opus4.7 -> height=1449"

Write-Host ""
Write-Host "=== Test Suite: ConvertFrom-ApiBbox ==="

# Test 11: Bbox (100,100,200,150) from 1280x720 to 3840x2160
$b = ConvertFrom-ApiBbox 100 100 200 150 1280 720 3840 2160
Assert-Equal 300 $b.x "Test 11: ConvertFrom-ApiBbox top-left x=300"
Assert-Equal 300 $b.y "Test 11: ConvertFrom-ApiBbox top-left y=300"
Assert-Equal 600 $b.w "Test 11: ConvertFrom-ApiBbox width=600"
Assert-Equal 450 $b.h "Test 11: ConvertFrom-ApiBbox height=450"

Write-Host ""
Write-Host "========================================"
Write-Host "Results: $passCount PASSED, $failCount FAILED, $totalTests TOTAL"
Write-Host "========================================"

if ($failCount -gt 0) {
    exit 1
} else {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
}
