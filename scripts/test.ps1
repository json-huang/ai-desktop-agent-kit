# Desktop Control Toolkit — Automated Test Suite v2
# Usage:
#   .\test.ps1                     # Smoke test (fast, minimal side effects)
#   .\test.ps1 -Full               # Full test (includes UI interactions)
#   .\test.ps1 -Full -Verbose      # Full + detailed output
#   .\test.ps1 -Script "mouse"     # Test only one script

param(
    [switch]$Full,
    [switch]$Verbose,
    [string]$ScriptName = ""
)

$S = "$env:USERPROFILE\.claude\scripts"
$pass = 0; $fail = 0; $skip = 0
$results = @()

function Invoke-Script {
    param($name, $extraArgs)
    $fullPath = "$S\$name"
    # Build command string — use cmd /c to let Windows parse args (avoids PS quoting hell)
    $cmd = 'powershell -ExecutionPolicy Bypass -File "' + $fullPath + '" ' + $extraArgs
    if ($Verbose) { Write-Host "  RUN: $cmd" -ForegroundColor DarkGray }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $output = cmd /c $cmd 2>&1 | Out-String
    $sw.Stop()
    return @{
        Output     = $output.Trim()
        ExitCode   = $LASTEXITCODE
        DurationMs = $sw.ElapsedMilliseconds
    }
}

function Test {
    param($label, $scriptName, $extraArgs, $expectedPattern, $shouldFail = $false)

    if ($ScriptName -and $scriptName -notlike "*$ScriptName*") {
        $script:skip++
        if ($Verbose) { Write-Host "  SKIP: $label" -ForegroundColor DarkGray }
        return
    }

    $r = Invoke-Script -name $scriptName -extraArgs $extraArgs

    if ($shouldFail) {
        $passed = ($r.ExitCode -ne 0) -or ($r.Output -match "ERROR")
    } else {
        $passed = ($r.Output -match $expectedPattern)
    }

    if ($passed) {
        $script:pass++
        $dur = $r.DurationMs
        Write-Host "  PASS: $label (${dur}ms)" -ForegroundColor Green
        if ($Verbose) { Write-Host "    $($r.Output)" -ForegroundColor DarkGray }
    } else {
        $script:fail++
        Write-Host "  FAIL: $label" -ForegroundColor Red
        Write-Host "    Expected: $expectedPattern" -ForegroundColor Red
        Write-Host "    Got: $($r.Output)" -ForegroundColor Red
    }

    $script:results += @{
        Label    = $label
        Passed   = $passed
        Duration = $r.DurationMs
        Output   = $r.Output
    }

    return $r
}

Write-Host ""
Write-Host "=== Desktop Control Toolkit Test Suite ===" -ForegroundColor Cyan
$modeLabel = if ($Full) { "Full" } else { "Smoke" }
Write-Host "Mode: $modeLabel"
Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ""

# ============================================================
# 1. SCREENSHOT
# ============================================================
Write-Host "--- screenshot.ps1 ---" -ForegroundColor Yellow
$ssPath = "$env:TEMP\_test_ss.png"
Remove-Item $ssPath -Force -ErrorAction SilentlyContinue

Test "Full-screen capture" screenshot.ps1 "-Path $ssPath" "OK|.*png"

$found = Test-Path $ssPath
if ($found) {
    $script:pass++
    $sz = (Get-Item $ssPath).Length
    Write-Host "  PASS: File on disk ($sz bytes)" -ForegroundColor Green
} else {
    $script:fail++
    Write-Host "  FAIL: File missing" -ForegroundColor Red
}

Test "Region capture" screenshot.ps1 "-Left 100 -Top 100 -Width 200 -Height 150 -Path $env:TEMP\_test_region.png" "OK|200x150"
Remove-Item "$env:TEMP\_test_region.png" -Force -ErrorAction SilentlyContinue

Test "Window not found" screenshot.ps1 "-WindowTitle ZZ_NOEXIST_ZZ" "ERROR" $true

# ============================================================
# 2. MOUSE
# ============================================================
Write-Host "--- mouse.ps1 ---" -ForegroundColor Yellow

Test "Get position" mouse.ps1 "-Action position" "\d+,\d+"
Test "Move cursor" mouse.ps1 "-Action move -X 500 -Y 500" "OK|moved|500,500"

if ($Full) {
    Test "Click" mouse.ps1 "-Action click" "OK|clicked"
    Test "Right click" mouse.ps1 "-Action rightclick" "OK|rightclicked"
    Test "Middle click" mouse.ps1 "-Action middleclick" "OK|middleclicked"
    Test "Double click" mouse.ps1 "-Action doubleclick" "OK|doubleclicked"
    Test "Click at coords" mouse.ps1 "-Action clickat -X 600 -Y 600" "OK|clicked"
    Test "Scroll" mouse.ps1 "-Action scroll -Amount 120" "OK|scrolled"
    Test "Drag" mouse.ps1 "-Action drag -X 100 -Y 100 -ToX 200 -ToY 200" "OK|dragged"
}

# ============================================================
# 3. KEYBOARD
# ============================================================
Write-Host "--- keyboard.ps1 ---" -ForegroundColor Yellow

Test "Type ASCII" keyboard.ps1 "-Action type -Text TestABC" "OK|typed|TestABC"
Test "Press Enter" keyboard.ps1 "-Action key -Key Enter" "OK|pressed|Enter"
Test "Hotkey Ctrl+Tab" keyboard.ps1 "-Action hotkey -Mod Ctrl -Key Tab" "OK|hotkey|Ctrl\+Tab"
Test "Unknown key" keyboard.ps1 "-Action key -Key ZZ_INVALID_ZZ" "ERROR" $true

if ($Full) {
    Test "Type with quotes" keyboard.ps1 "-Action type -Text `"hello world`"" "OK|typed|hello world"
}

# ============================================================
# 4. WINDOW
# ============================================================
Write-Host "--- window.ps1 ---" -ForegroundColor Yellow

Test "List windows" window.ps1 "-Action list" "\d+\|.+"
Test "Foreground info" window.ps1 "-Action info" "OK|.+"
Test "Find Program Manager" window.ps1 '-Action find -Title "Program Manager"' "OK|Program Manager"
Test "Find nonexistent" window.ps1 '-Action find -Title "ZZ_NOEXIST_ZZ"' "NOTFOUND" $true

if ($Full) {
    Invoke-Script system.ps1 "-Action launch -Target notepad" | Out-Null
    Start-Sleep -Seconds 1
    Test "Focus Notepad" window.ps1 '-Action focus -Title "记事本"' "OK|focused"
    Test "Move window" window.ps1 '-Action move -Title "记事本" -X 100 -Y 100' "OK|moved"
    Test "Resize window" window.ps1 '-Action resize -Title "记事本" -W 600 -H 400' "OK|resized"
}

# ============================================================
# 5. SYSTEM
# ============================================================
Write-Host "--- system.ps1 ---" -ForegroundColor Yellow

Test "System info" system.ps1 "-Action info" "OS=.+"
Test "Top processes" system.ps1 "-Action processes" "\d+\|.+\|CPU="
Test "Set clipboard" system.ps1 "-Action setclip -Text test123" "OK|clipboard set"
Test "Read clipboard" system.ps1 "-Action clipboard" "test123"

if ($Full) {
    Test "Launch notepad" system.ps1 "-Action launch -Target notepad" "OK|launched|notepad"
}

# ============================================================
# 6. OCR
# ============================================================
Write-Host "--- ocr.ps1 ---" -ForegroundColor Yellow

# Use the full-screen screenshot already captured for OCR
if (Test-Path $ssPath) {
    Test "OCR screenshot" ocr.ps1 "-Image $ssPath" "OK|lang=auto"
} else {
    Write-Host "  SKIP: No screenshot for OCR" -ForegroundColor DarkGray
    $script:skip++
}

# ============================================================
# 7. FINDIMAGE
# ============================================================
Write-Host "--- findimage.ps1 ---" -ForegroundColor Yellow

$fiScr = "$env:TEMP\_fi_scr.png"
Invoke-Script screenshot.ps1 "-Path $fiScr" | Out-Null
if (Test-Path $fiScr) {
    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::FromFile($fiScr)
    $tpl = "$env:TEMP\_fi_tpl.png"
    # Crop from bottom-right area (taskbar, high variance)
    $rx = [Math]::Max(0, $bmp.Width - 300)
    $ry = [Math]::Max(0, $bmp.Height - 80)
    $crop = $bmp.Clone((New-Object System.Drawing.Rectangle($rx, $ry, 100, 40)), [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $crop.Save($tpl, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose(); $crop.Dispose()

    $rx2 = [Math]::Max(0, $rx - 50)
    $ry2 = [Math]::Max(0, $ry - 30)
    Test "Find template (exact)" findimage.ps1 "-Template $tpl -Screen $fiScr -Threshold 0.99 -Region $rx2,$ry2,300,150" "OK"
    Test "Find nonexistent" findimage.ps1 "-Template $tpl -Screen $fiScr -Threshold 0.99999 -Region 0,0,500,500" "NOTFOUND"

    Remove-Item $tpl, $fiScr -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "  SKIP: Could not capture findimage screen" -ForegroundColor DarkGray
    $script:skip++
}

# ============================================================
# 8. VERIFY
# ============================================================
Write-Host "--- verify.ps1 ---" -ForegroundColor Yellow

$v1 = "$env:TEMP\_v1.png"; $v2 = "$env:TEMP\_v2.png"
Invoke-Script screenshot.ps1 "-Path $v1" | Out-Null
Start-Sleep -Milliseconds 300
Invoke-Script screenshot.ps1 "-Path $v2" | Out-Null

if ((Test-Path $v1) -and (Test-Path $v2)) {
    Test "Compare screenshots" verify.ps1 "-Before $v1 -After $v2 -Threshold 20" "OK|changed=\d+"
    Remove-Item $v1, $v2 -Force -ErrorAction SilentlyContinue
}

# ============================================================
# 9. LOG
# ============================================================
Write-Host "--- log.ps1 ---" -ForegroundColor Yellow

Test "Log entry" log.ps1 "-Action log -Script test -Op smoke -Result `"OK|pass`" -DurationMs 42" "OK|logged"
Test "Query log" log.ps1 "-Action query -Last 5" ""
Test "Summary" log.ps1 "-Action summary" "Total:"

# ============================================================
# CLEANUP
# ============================================================
Remove-Item $ssPath -Force -ErrorAction SilentlyContinue

# ============================================================
# REPORT
# ============================================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
$resultColor = if ($fail -eq 0) { "Green" } else { "Red" }
Write-Host "  RESULTS: $pass passed, $fail failed, $skip skipped" -ForegroundColor $resultColor
Write-Host "========================================" -ForegroundColor Cyan

if ($fail -gt 0) { exit 1 }
exit 0
