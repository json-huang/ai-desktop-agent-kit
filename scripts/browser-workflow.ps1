# Browser Workflow Script v1 — Visual + Browser Hybrid Automation
# Combines desktop tools (screenshot/OCR/mouse/keyboard/window) with agent-browser CDP
# Usage:
#   .\browser-workflow.ps1 -Workflow smart-navigate -Url "https://github.com"
#   .\browser-workflow.ps1 -Workflow smart-click -Text "登录" [-Selector "#login"]
#   .\browser-workflow.ps1 -Workflow smart-fill -Fields @{name="user"; phone="139"}
#   .\browser-workflow.ps1 -Workflow verify-page -Expect "Welcome"

param(
    [ValidateSet("smart-navigate","smart-click","smart-fill","verify-page","smart-launch")]
    [string]$Workflow = "smart-navigate",

    # Common params
    [string]$Url = "",
    [string]$Text = "",           # Text to type or click (by OCR label)
    [string]$Selector = "",       # CSS selector for CDP (preferred)
    [string]$Expect = "",         # Expected text for verification
    [hashtable]$Fields = @{},     # @{fieldLabel="value"} for smart-fill
    [int]$Timeout = 30,           # Max wait time in seconds
    [string]$WindowTitle = "Chrome"
)

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$BROWSER_PS1 = Join-Path $SCRIPT_DIR "browser.ps1"
$SCREENSHOT_PS1 = Join-Path $SCRIPT_DIR "screenshot.ps1"
$OCR_PS1 = Join-Path $SCRIPT_DIR "ocr.ps1"
$MOUSE_PS1 = Join-Path $SCRIPT_DIR "mouse.ps1"
$KEYBOARD_PS1 = Join-Path $SCRIPT_DIR "keyboard.ps1"
$WINDOW_PS1 = Join-Path $SCRIPT_DIR "window.ps1"
$SYSTEM_PS1 = Join-Path $SCRIPT_DIR "system.ps1"
$FINDIMAGE_PS1 = Join-Path $SCRIPT_DIR "findimage.ps1"

# ===== Helper Functions =====

function Write-Step($msg) {
    Write-Host "  [$($msg)]" -ForegroundColor DarkGray
}

function Write-OK($msg) {
    Write-Output "OK|$msg"
}

function Write-ERR($msg) {
    Write-Output "ERROR|$msg"
}

function Run-Script {
    param([string]$Path, [string]$Arguments)
    if (-not (Test-Path $Path)) {
        Write-ERR "Script not found: $Path"
        return $null
    }
    $cmd = "& '$Path' $Arguments"
    try {
        return Invoke-Expression $cmd
    } catch {
        Write-ERR "Script error: $($_.Exception.Message)"
        return $null
    }
}

# Find text on screen via OCR and return coordinates
function Find-TextOnScreen {
    param([string]$ImagePath, [string]$SearchText, [int]$WindowLeft = 0, [int]$WindowTop = 0)

    if (-not (Test-Path $ImagePath)) { return $null }

    $ocrResult = Run-Script $OCR_PS1 "-Image '$ImagePath' -Detail"
    if (-not $ocrResult) { return $null }

    # Parse OCR detail output: "Line: 'text' at (x,y,w,h) confidence:0.9"
    $bestMatch = $null
    $bestConfidence = 0

    foreach ($line in $ocrResult) {
        if ($line -match $SearchText) {
            if ($line -match 'at \((\d+),(\d+),(\d+),(\d+)\) confidence:([\d.]+)') {
                $x = [int]$matches[1] + [int]$matches[3] / 2
                $y = [int]$matches[2] + [int]$matches[4] / 2
                $conf = [double]$matches[5]
                if ($conf -gt $bestConfidence) {
                    $bestConfidence = $conf
                    $bestMatch = @{X = $x + $WindowLeft; Y = $y + $WindowTop; Confidence = $conf}
                }
            }
        }
    }
    return $bestMatch
}

# Find Chrome window and return position/size
function Find-ChromeWindow {
    $winInfo = Run-Script $WINDOW_PS1 "-Action find -Title '$WindowTitle'"
    if ($winInfo -and $winInfo -match '(\d+),(\d+),(\d+),(\d+)') {
        return @{
            X = [int]$matches[1]; Y = [int]$matches[2]
            W = [int]$matches[3]; H = [int]$matches[4]
        }
    }
    return $null
}

# ===== Workflow 1: Smart Launch =====
function Invoke-SmartLaunch {
    Write-Step "Smart Launch: checking browser availability"

    # Method 1: Check if CDP daemon already running
    $sessionCheck = Run-Script $BROWSER_PS1 "-Action session"
    if ($sessionCheck -match "^OK") {
        Write-Step "CDP daemon responsive, checking page connectivity"
        # Quick snapshot to verify Chrome is alive
        $snapCheck = Run-Script $BROWSER_PS1 "-Action wait -Target '500'"
        if ($snapCheck -match "^OK") {
            Write-OK "Browser CDP daemon ready"
            return $true
        }
    }

    # Method 2: Check for visible Chrome window
    $win = Find-ChromeWindow
    if ($win) {
        Write-OK "Chrome window visible at $($win.X),$($win.Y)"
        Run-Script $WINDOW_PS1 "-Action focus -Title '$WindowTitle'" | Out-Null
        Start-Sleep -Milliseconds 300
        return $true
    }

    Write-Step "No browser detected, launching..."

    # Launch via browser.ps1 (starts agent-browser daemon + Chrome)
    $startResult = Run-Script $BROWSER_PS1 "-Action start -Url 'about:blank'"
    Start-Sleep -Seconds 2

    # Verify launch
    $waited = 0
    while ($waited -lt $Timeout) {
        # Check CDP first (faster)
        $snapCheck = Run-Script $BROWSER_PS1 "-Action session"
        if ($snapCheck -match "^OK") {
            Write-OK "Browser CDP daemon ready (${waited}s)"
            return $true
        }
        # Also check for window
        $win = Find-ChromeWindow
        if ($win) {
            Write-OK "Chrome window appeared (${waited}s)"
            Start-Sleep -Seconds 1
            return $true
        }
        Start-Sleep -Seconds 1
        $waited++
        if ($waited % 5 -eq 0) {
            Write-Step "Waiting for browser... ($waited s)"
        }
    }

    Write-ERR "Browser did not become available within ${Timeout}s"
    return $false
}

# ===== Workflow 2: Smart Navigate =====
function Invoke-SmartNavigate {
    if (-not $Url) {
        Write-ERR "Url parameter is required for smart-navigate"
        return
    }

    Write-Step "Smart Navigate → $Url"

    # Step 1: Ensure Chrome is running
    if (-not (Invoke-SmartLaunch)) { return }

    # Step 2: Try CDP navigation first
    Write-Step "Trying CDP navigation via agent-browser"
    $navResult = Run-Script $BROWSER_PS1 "-Action open -Url '$Url'"
    if ($navResult -match "^OK") {
        Write-OK "smart_navigate|CDP|$Url"
        return
    }

    # Step 3: CDP failed, fall back to visual navigation
    Write-Step "CDP navigation failed, falling back to visual method"

    $win = Find-ChromeWindow
    if (-not $win) {
        Write-ERR "Cannot find Chrome window"
        return
    }

    # Screenshot full screen
    $ssPath = "$env:TEMP\wf_nav_$(Get-Date -Format 'HHmmss').png"
    Run-Script $SCREENSHOT_PS1 "-Path '$ssPath'" | Out-Null

    if (-not (Test-Path $ssPath)) {
        Write-ERR "Screenshot failed"
        return
    }

    # OCR to find address bar (look for common address bar hints)
    $addrBar = $null
    $searchPatterns = @("搜索", "网址", "URL", "http", "地址", "Search", "Address")
    foreach ($pattern in $searchPatterns) {
        $addrBar = Find-TextOnScreen $ssPath $pattern $win.X $win.Y
        if ($addrBar) {
            Write-Step "Found address bar via OCR: '$pattern' at $($addrBar.X),$($addrBar.Y)"
            break
        }
    }

    if (-not $addrBar) {
        # Last resort: click near top-center of Chrome window
        $addrBar = @{
            X = $win.X + [int]($win.W * 0.4)
            Y = $win.Y + 60
            Confidence = 0
        }
        Write-Step "Using default address bar position: $($addrBar.X),$($addrBar.Y)"
    }

    # Click address bar
    Run-Script $MOUSE_PS1 "-Action clickat -X $($addrBar.X) -Y $($addrBar.Y)" | Out-Null
    Start-Sleep -Milliseconds 200

    # Select all and type URL
    Run-Script $KEYBOARD_PS1 "-Action hotkey -Mod Ctrl -Key A" | Out-Null
    Start-Sleep -Milliseconds 100
    Run-Script $KEYBOARD_PS1 "-Action type -Text '$Url'" | Out-Null
    Start-Sleep -Milliseconds 200
    Run-Script $KEYBOARD_PS1 "-Action key -Key Enter" | Out-Null

    # Clean up screenshot
    Remove-Item $ssPath -Force -ErrorAction SilentlyContinue

    Write-OK "smart_navigate|visual|$Url"
}

# ===== Workflow 3: Smart Click =====
function Invoke-SmartClick {
    if (-not $Text -and -not $Selector) {
        Write-ERR "Text or Selector parameter is required for smart-click"
        return
    }

    Write-Step "Smart Click → '$Text' (selector: $Selector)"

    # Step 1: Try CDP click if selector provided
    if ($Selector) {
        Write-Step "Trying CDP selector click: $Selector"
        $clickResult = Run-Script $BROWSER_PS1 "-Action click -Target '$Selector'"
        if ($clickResult -match "^OK") {
            Write-OK "smart_click|CDP|$Selector"
            return
        }
        Write-Step "CDP selector not found, trying snapshot..."
    }

    # Step 2: Get page snapshot and try to find element by text
    $snap = Run-Script $BROWSER_PS1 "-Action snapshot -Detail"
    if ($snap -and $Text) {
        foreach ($line in $snap) {
            if ($line -match $Text -and $line -match '\[ref=(\w+)\]') {
                $ref = $matches[1]
                Write-Step "Found element by text: ref=$ref"
                $clickResult = Run-Script $BROWSER_PS1 "-Action click -Target '@$ref'"
                if ($clickResult -match "^OK") {
                    Write-OK "smart_click|snapshot|@$ref"
                    return
                }
            }
        }
    }

    # Step 3: Fall back to visual click (screenshot + OCR + mouse)
    Write-Step "Falling back to visual click method"

    # Take browser viewport screenshot
    $ssPath = "$env:TEMP\wf_click_$(Get-Date -Format 'HHmmss').png"
    $ssResult = Run-Script $BROWSER_PS1 "-Action screenshot -Path '$ssPath'"
    if ($ssResult -match "ERROR") {
        # Fall back to full desktop screenshot
        Run-Script $SCREENSHOT_PS1 "-Path '$ssPath'" | Out-Null
    }

    if (-not (Test-Path $ssPath)) {
        Write-ERR "Cannot capture screen for visual click"
        return
    }

    # Get Chrome window position for coordinate offset
    $win = Find-ChromeWindow
    $offsetX = if ($win) { $win.X } else { 0 }
    $offsetY = if ($win) { $win.Y } else { 0 }

    # Find text with OCR
    $target = Find-TextOnScreen $ssPath $Text $offsetX $offsetY

    if ($target) {
        Write-Step "OCR found '$Text' at $($target.X),$($target.Y) (conf: $($target.Confidence))"
        Run-Script $MOUSE_PS1 "-Action clickat -X $($target.X) -Y $($target.Y)" | Out-Null
        Remove-Item $ssPath -Force -ErrorAction SilentlyContinue
        Write-OK "smart_click|OCR|$($target.X),$($target.Y)"
        return
    }

    Remove-Item $ssPath -Force -ErrorAction SilentlyContinue
    Write-ERR "smart_click|failed|cannot find '$Text' on screen"
}

# ===== Workflow 4: Smart Fill =====
function Invoke-SmartFill {
    if ($Fields.Count -eq 0) {
        Write-ERR "Fields parameter is required for smart-fill (e.g. -Fields @{'姓名'='张三'; '电话'='139'})"
        return
    }

    Write-Step "Smart Fill → $($Fields.Count) fields"

    # Take browser screenshot
    $ssPath = "$env:TEMP\wf_fill_$(Get-Date -Format 'HHmmss').png"
    $ssResult = Run-Script $BROWSER_PS1 "-Action screenshot -Path '$ssPath'"
    if ($ssResult -match "ERROR") {
        Run-Script $SCREENSHOT_PS1 "-Path '$ssPath'" | Out-Null
    }

    if (-not (Test-Path $ssPath)) {
        Write-ERR "Cannot capture screen for smart-fill"
        return
    }

    # Get window offset
    $win = Find-ChromeWindow
    $offsetX = if ($win) { $win.X } else { 0 }
    $offsetY = if ($win) { $win.Y } else { 0 }

    $filled = 0
    foreach ($label in $Fields.Keys) {
        $value = $Fields[$label]
        Write-Step "Looking for field: '$label'"

        # Try CDP snapshot first
        $snap = Run-Script $BROWSER_PS1 "-Action snapshot -Detail"
        $cdpRef = $null
        if ($snap) {
            foreach ($line in $snap) {
                if ($line -match $label -and $line -match 'textbox.*\[ref=(\w+)\]') {
                    $cdpRef = $matches[1]
                    break
                }
            }
        }

        if ($cdpRef) {
            Write-Step "CDP fill: @$cdpRef = '$value'"
            $fillResult = Run-Script $BROWSER_PS1 "-Action fill -Target '@$cdpRef' -Text '$value'"
            if ($fillResult -match "^OK") {
                $filled++
                continue
            }
        }

        # Fall back to visual: find label via OCR, click nearby field, type
        $labelPos = Find-TextOnScreen $ssPath $label $offsetX $offsetY
        if ($labelPos) {
            # Click to the right of the label (estimated field position)
            $fieldX = $labelPos.X + 150
            $fieldY = $labelPos.Y
            Write-Step "Visual fill: click ($fieldX,$fieldY) and type '$value'"
            Run-Script $MOUSE_PS1 "-Action clickat -X $fieldX -Y $fieldY" | Out-Null
            Start-Sleep -Milliseconds 200
            Run-Script $KEYBOARD_PS1 "-Action hotkey -Mod Ctrl -Key A" | Out-Null
            Start-Sleep -Milliseconds 100
            Run-Script $KEYBOARD_PS1 "-Action type -Text '$value'" | Out-Null
            $filled++
        } else {
            Write-Step "Field '$label' not found on screen"
        }
    }

    Remove-Item $ssPath -Force -ErrorAction SilentlyContinue
    Write-OK "smart_fill|$filled/$($Fields.Count)"
}

# ===== Workflow 5: Verify Page =====
function Invoke-VerifyPage {
    if (-not $Expect) {
        Write-ERR "Expect parameter is required for verify-page"
        return
    }

    Write-Step "Verify Page → expecting '$Expect'"

    # Take browser screenshot
    $ssPath = "$env:TEMP\wf_verify_$(Get-Date -Format 'HHmmss').png"
    $ssResult = Run-Script $BROWSER_PS1 "-Action screenshot -Path '$ssPath'"
    if ($ssResult -match "ERROR") {
        Run-Script $SCREENSHOT_PS1 "-Path '$ssPath'" | Out-Null
    }

    if (-not (Test-Path $ssPath)) {
        Write-ERR "Cannot capture screenshot for verification"
        return
    }

    # OCR the screenshot
    $ocrResult = Run-Script $OCR_PS1 "-Image '$ssPath'"
    Remove-Item $ssPath -Force -ErrorAction SilentlyContinue

    if ($ocrResult -match $Expect) {
        Write-OK "verify_page|found|$Expect"
    } else {
        Write-ERR "verify_page|not_found|$Expect"
    }
}

# ===== Main Dispatch =====
switch ($Workflow) {
    "smart-launch"   { Invoke-SmartLaunch }
    "smart-navigate" { Invoke-SmartNavigate }
    "smart-click"    { Invoke-SmartClick }
    "smart-fill"     { Invoke-SmartFill }
    "verify-page"    { Invoke-VerifyPage }
}
