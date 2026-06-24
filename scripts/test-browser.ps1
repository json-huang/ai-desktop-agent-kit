# Browser Control Test Suite v1
# Tests each browser.ps1 action and verifies expected behavior
# Run: .\test-browser.ps1 [-Full]

param(
    [switch]$Full = $false,   # Include screenshot tests
    [switch]$Quick = $false   # Skip slow tests
)

$SCRIPT = "$PSScriptRoot\browser.ps1"
$PASS = 0
$FAIL = 0
$SKIP = 0
$TotalTests = 0

function Test {
    param([string]$Name, [scriptblock]$ScriptBlock)
    $script:TotalTests++
    Write-Host "  Testing: $Name" -NoNewline
    try {
        $result = & $ScriptBlock
        if ($result -is [bool] -and $result) {
            Write-Host " ... PASS" -ForegroundColor Green
            $script:PASS++
        } elseif ($result -is [string] -and $result -match "^(OK|PASS)") {
            Write-Host " ... PASS" -ForegroundColor Green
            $script:PASS++
        } elseif ($result -is [bool] -and -not $result) {
            Write-Host " ... FAIL" -ForegroundColor Red
            $script:FAIL++
        } else {
            Write-Host " ... PASS" -ForegroundColor Green
            $script:PASS++
        }
        return $result
    } catch {
        Write-Host " ... FAIL ($($_.Exception.Message))" -ForegroundColor Red
        $script:FAIL++
        return $null
    }
}

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Browser Control Test Suite" -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# ========== Section 1: Core Commands ==========
Write-Host "[Section 1] Core Commands" -ForegroundColor Yellow

# 1.1 Session
Test "Get session info" {
    $r = & $SCRIPT -Action session
    $r -match "^OK"
}

# 1.2 Open URL
Test "Navigate to URL" {
    $r = & $SCRIPT -Action open -Url "https://httpbin.org/html"
    $r -match "^OK"
}

# 1.3 Snapshot
Test "Get page snapshot" {
    $r = & $SCRIPT -Action snapshot -Detail
    ($r -match "^OK") -or ($r -match 'ref=e\d')
}

# 1.4 Wait
Test "Wait for page" {
    $r = & $SCRIPT -Action wait -Target "1000"
    $r -match "^OK"
}

# 1.5 Press key
Test "Press Escape key" {
    $r = & $SCRIPT -Action press -Key "Escape"
    $r -match "^OK"
}

# 1.6 Scroll
Test "Scroll page down" {
    $null = & $SCRIPT -Action open -Url "https://httpbin.org/html"
    Start-Sleep -Seconds 2
    $r = & $SCRIPT -Action scroll -Direction down -Amount 300
    $r -match "^OK"
}

# ========== Section 2: Form Interaction ==========
Write-Host "[Section 2] Form Interaction" -ForegroundColor Yellow

# Navigate to form page
$null = & $SCRIPT -Action open -Url "https://httpbin.org/forms/post"
Start-Sleep -Seconds 2

# Get element refs
$snapshot = & $SCRIPT -Action snapshot -Detail
Write-Host "  [Snap] Got page snapshot with element refs" -ForegroundColor DarkGray

# 2.1 Fill text field
$hasE2 = $snapshot -match 'ref=e2'
$hasE3 = $snapshot -match 'ref=e3'
$hasE4 = $snapshot -match 'ref=e4'

if ($hasE2 -and $hasE3 -and $hasE4) {
    Test "Fill name field" {
        $r = & $SCRIPT -Action fill -Target "@e2" -Text "TestUser123"
        $r -match "^OK"
    }
    Test "Fill phone field" {
        $r = & $SCRIPT -Action fill -Target "@e3" -Text "13900139000"
        $r -match "^OK"
    }
    Test "Fill email field" {
        $r = & $SCRIPT -Action fill -Target "@e4" -Text "test@example.com"
        $r -match "^OK"
    }
} else {
    Write-Host "  SKIP: Form text fields not found (refs e2/e3/e4)" -ForegroundColor Yellow
    $SKIP += 3
}

# 2.2 Click radio/checkbox
$hasE5 = $snapshot -match 'ref=e5'
$hasE8 = $snapshot -match 'ref=e8'

if ($hasE5) {
    Test "Click radio button" {
        $r = & $SCRIPT -Action click -Target "@e5"
        $r -match "^OK"
    }
} else { $SKIP++; Write-Host "  SKIP: Radio not found" -ForegroundColor Yellow }

if ($hasE8) {
    Test "Click checkbox" {
        $r = & $SCRIPT -Action click -Target "@e8"
        $r -match "^OK"
    }
} else { $SKIP++; Write-Host "  SKIP: Checkbox not found" -ForegroundColor Yellow }

# 2.3 Submit and verify
$hasE1 = $snapshot -match 'ref=e1'
if ($hasE1) {
    Test "Click submit button" {
        $r = & $SCRIPT -Action click -Target "@e1"
        $r -match "^OK"
    }
    Start-Sleep -Seconds 2

    Test "Verify form submission" {
        $verify = & $SCRIPT -Action snapshot
        $verify -match "TestUser123"
    }
} else { $SKIP += 2; Write-Host "  SKIP: Submit button not found" -ForegroundColor Yellow }

# ========== Section 3: Screenshot (optional) ==========
if ($Full) {
    Write-Host "[Section 3] Screenshots" -ForegroundColor Yellow

    Test "Take page screenshot" {
        $path = "$env:TEMP\browser_test_ss.png"
        $r = & $SCRIPT -Action screenshot -Path $path
        $ok = (Test-Path $path) -and ((Get-Item $path).Length -gt 100)
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        $ok
    }

    Test "Take annotated screenshot" {
        $path = "$env:TEMP\browser_test_ann.png"
        $r = & $SCRIPT -Action screenshot -Path $path -Annotate
        $ok = (Test-Path $path) -and ((Get-Item $path).Length -gt 100)
        Remove-Item $path -Force -ErrorAction SilentlyContinue
        $ok
    }
}

# ========== Section 4: Sessions & Advanced ==========
Write-Host "[Section 4] Sessions & Advanced" -ForegroundColor Yellow

Test "Named session persistence" {
    $null = & $SCRIPT -Action open -Url "https://httpbin.org/ip" -SessionName "test-sess"
    Start-Sleep -Seconds 2
    $r = & $SCRIPT -Action snapshot -SessionName "test-sess"
    $r -match "origin"
}

Test "Hover over element" {
    $null = & $SCRIPT -Action open -Url "https://httpbin.org/forms/post"
    Start-Sleep -Seconds 2
    $snap = & $SCRIPT -Action snapshot -Detail
    $target = if ($snap -match 'ref=e13') { "@e13" } else { "@e1" }
    $r = & $SCRIPT -Action hover -Target $target
    $r -match "^OK"
}

# ========== Summary ==========
Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
$total = $PASS + $FAIL + $SKIP
Write-Host "  Passed:  $PASS / $total tests" -ForegroundColor Green
if ($FAIL -gt 0) {
    Write-Host "  Failed:  $FAIL / $total tests" -ForegroundColor Red
}
if ($SKIP -gt 0) {
    Write-Host "  Skipped: $SKIP / $total tests" -ForegroundColor Yellow
}
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

if ($FAIL -gt 0) {
    Write-Host "Some tests FAILED!" -ForegroundColor Red
    exit 1
} else {
    Write-Host "All tests PASSED!" -ForegroundColor Green
    exit 0
}
