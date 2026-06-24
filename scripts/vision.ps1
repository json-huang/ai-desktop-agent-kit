# Claude Vision Pipeline — vision.ps1
# Pre-downscales screenshots to model-native resolution, generates structured prompts
# for UI element enumeration via Claude Vision, and provides coordinate reverse-mapping
# for all API-returned coordinates.
#
# This is Tier 4 of the perception pipeline — the final and most expensive tier.
# Only invoked when lower tiers (UIA + OCR + template matching) leave significant gaps
# (custom-rendered UI: Blender viewport, web Canvas, game interfaces).
#
# Strategy: vision.ps1 runs same-wave as perception-schema.ps1 (Plan 01-02).
# To avoid dependency on a file that may not exist yet, vision.ps1 creates UiElement
# PSObjects inline matching the unified schema shape WITHOUT dot-sourcing
# perception-schema.ps1. The fusion engine (Plan 01-03, Wave 3) normalizes all inputs.
#
# Usage:
#   .\vision.ps1                                    # Capture fresh screenshot, generate manifest
#   .\vision.ps1 -ScreenshotPath "C:\shot.png"      # Use existing screenshot
#   .\vision.ps1 -PromptTemplate "click_target"      # Alternative prompt type
#   .\vision.ps1 -MaxLongEdge 2576 -MaxPixels 3750000 # Opus 4.7 limits
#   .\vision.ps1 -SkipDownscale                     # DEBUG: skip pre-downscale (causes coordinate drift)
#   .\vision.ps1 -OutputPath "vision_manifest.json"  # Write manifest to file
#
# CRITICAL: Text instructions MUST be placed BEFORE the image in the content array.
# Anthropic official best practices confirm image-first ordering causes accuracy degradation.

param(
    [string]$ScreenshotPath = "",          # Existing screenshot (empty = capture fresh)
    [string]$PromptTemplate = "enumerate", # "enumerate" | "click_target" | custom prompt text
    [int]$MaxLongEdge = 1568,              # Use 2576 for Opus 4.7
    [int]$MaxPixels = 1150000,             # Use 3750000 for Opus 4.7
    [switch]$SkipDownscale,                # DEBUG: skip pre-downscale (CAUSES COORDINATE DRIFT)
    [string]$OutputPath = ""               # JSON output path for manifest
)

# ============================================================
# Helper: Create UiElement matching unified schema shape
# WITHOUT depending on perception-schema.ps1 (same-wave constraint)
# ============================================================
function New-VisionElement {
    param(
        [string]$Type = "other",
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [double]$Confidence = 0.0,
        [string]$Text = "",
        [string]$State = "unknown",
        [bool]$IsInteractive = $false
    )

    [PSCustomObject]@{
        type          = $Type
        bbox          = @{ x = $X; y = $Y; w = $W; h = $H }
        confidence    = $Confidence
        text          = $Text
        state         = $State
        isInteractive = $IsInteractive
        source        = "visionModel"
        alternatives  = @()
        displayIndex  = 0
        dpiScale      = 1.0
        parentIndex   = -1
    }
}

# ============================================================
# Core function: Invoke-VisionPerception
# Captures/loads screenshot, pre-downscales, generates prompt + manifest
# ============================================================
function Invoke-VisionPerception {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ImagePath,

        [string]$Prompt = "enumerate",

        [int]$MaxLongEdge = 1568,

        [int]$MaxPixels = 1150000
    )

    # 1. LOAD the screenshot image
    Add-Type -AssemblyName System.Drawing
    $bitmap = [System.Drawing.Bitmap]::FromFile($ImagePath)
    $nativeW = $bitmap.Width
    $nativeH = $bitmap.Height

    if ($SkipDownscale) {
        # DEBUG mode: skip pre-downscale
        $displayW = $nativeW
        $displayH = $nativeH
        $tempPng = $ImagePath
        $bitmap.Dispose()
        Write-Warning "SkipDownscale active: coordinates will be in native resolution. DO NOT use for production."
    }
    else {
        # 2. COMPUTE optimal display resolution
        . "$PSScriptRoot\coordinate-scaling.ps1"
        $displayW, $displayH = Compute-MaxApiFit $nativeW $nativeH $MaxLongEdge $MaxPixels

        # 3. PRE-DOWNSCALE the screenshot
        $resized = [System.Drawing.Bitmap]::new($displayW, $displayH)
        $g = [System.Drawing.Graphics]::FromImage($resized)
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.DrawImage($bitmap, 0, 0, $displayW, $displayH)
        $g.Dispose()
        $bitmap.Dispose()

        # 4. SAVE the resized image to a temp file
        $tempDir = $env:TEMP
        $tempPng = "$tempDir\vision_resized_$(Get-Date -Format 'yyyyMMdd_HHmmss').png"
        $resized.Save($tempPng, [System.Drawing.Imaging.ImageFormat]::Png)
        $resized.Dispose()
    }

    # 5. BUILD the Claude Vision prompt
    $promptText = if ($Prompt -eq "enumerate") {
        @"
You are analyzing a screenshot of a Windows desktop application. Your task is to enumerate ALL visible interactive UI elements.

For each element, provide:
- type: button, menu, textbox, icon, link, toolbar, tab, label, image, or other
- bbox: bounding box as [x, y, width, height] in the image coordinate space
- text: any visible text on the element (empty string if none)
- state: enabled, disabled, selected, focused, or unknown
- isInteractive: true if clickable/typable, false if display-only

Output a JSON array of elements. Example:
[{"type":"button","bbox":[100,200,80,30],"text":"File","state":"enabled","isInteractive":true}]

The image dimensions are ${displayW}x${displayH} pixels.
IMPORTANT: All coordinates must be within [0,0] to [${displayW},${displayH}].
"@
    }
    elseif ($Prompt -eq "click_target") {
        @"
You are looking at a Windows desktop screenshot. Identify the most likely click targets visible.

For each clickable element, provide:
- type: button, link, menu, tab, icon, or other
- bbox: bounding box as [x, y, width, height] in the image coordinate space (${displayW}x${displayH})
- description: what this element does
- confidence: 0.0 to 1.0

Output a JSON array of click targets sorted by confidence descending.
"@
    }
    else {
        $Prompt
    }

    # 6. WRITE the prompt to a text file alongside the image
    $promptFile = "$env:TEMP\vision_prompt_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $promptText | Out-File -FilePath $promptFile -Encoding UTF8

    # 7. BUILD manifest
    $scaleFactorX = [double]$nativeW / $displayW
    $scaleFactorY = [double]$nativeH / $displayH

    $manifest = [PSCustomObject]@{
        native_resolution  = "${nativeW}x${nativeH}"
        display_resolution = "${displayW}x${displayH}"
        scale_factor_x     = $scaleFactorX
        scale_factor_y     = $scaleFactorY
        resized_image_path = $tempPng
        prompt_file        = $promptFile
        prompt_text        = $promptText
        instructions       = "CRITICAL: Place the text prompt BEFORE the image in your content array. Send the prompt text first, then the image data. Anthropic best practices confirm image-first ordering causes accuracy degradation. Parse Claude's JSON response. For each element's bbox, reverse-map coordinates: screen_x = int(api_x * $nativeW / $displayW), screen_y = int(api_y * $nativeH / $displayH). Store elements with source='visionModel'."
    }

    # 8. OUTPUT manifest as JSON
    $manifestJson = $manifest | ConvertTo-Json -Depth 5

    if ($OutputPath) {
        $manifestJson | Set-Content -Path $OutputPath -Encoding UTF8
    }

    return $manifest
}

# ============================================================
# Fallback gap detection: Test-VisionFallbackNeeded
# Determines whether lower tiers provided sufficient coverage,
# or if Claude Vision should be invoked as fallback.
# ============================================================
function Test-VisionFallbackNeeded {
    param(
        [object[]]$UiaElements,
        [object[]]$OcrElements,
        [object[]]$TemplateElements,
        [int]$MinTotalElements = 5
    )

    $uiaCount = if ($UiaElements) { $UiaElements.Count } else { 0 }
    $ocrCount = if ($OcrElements) { $OcrElements.Count } else { 0 }
    $tmplCount = if ($TemplateElements) { $TemplateElements.Count } else { 0 }
    $totalCount = $uiaCount + $ocrCount + $tmplCount

    # Vision needed if total elements from lower tiers is below threshold
    if ($totalCount -lt $MinTotalElements) {
        return $true
    }

    # Vision needed if UIA returned very few elements (likely custom UI)
    if ($uiaCount -lt 3) {
        return $true
    }

    # Lower tiers provided sufficient coverage
    return $false
}

# ============================================================
# Script body: execute when run directly
# ============================================================
if ($MyInvocation.InvocationName -ne '.') {
    # Not dot-sourced — run as script

    try {
        # 1. Resolve screenshot: capture fresh if not provided
        if (-not $ScreenshotPath) {
            $result = & "$PSScriptRoot\screenshot.ps1"
            if ($result -match '^OK\|(.+?)\|') {
                $ScreenshotPath = $matches[1]
                Write-Host "Captured screenshot: $ScreenshotPath"
            }
            else {
                Write-Error "Failed to capture screenshot: $result"
                exit 1
            }
        }

        if (-not (Test-Path $ScreenshotPath)) {
            Write-Error "Screenshot not found: $ScreenshotPath"
            exit 1
        }

        # 2. Run vision perception pipeline
        $manifest = Invoke-VisionPerception -ImagePath $ScreenshotPath -Prompt $PromptTemplate `
            -MaxLongEdge $MaxLongEdge -MaxPixels $MaxPixels

        # 3. Output summary
        Write-Host ""
        Write-Host "=== Vision Pipeline Complete ==="
        Write-Host "Native:     $($manifest.native_resolution)"
        Write-Host "Display:    $($manifest.display_resolution)"
        Write-Host "Scale:      x=$($manifest.scale_factor_x), y=$($manifest.scale_factor_y)"
        Write-Host "Resized:    $($manifest.resized_image_path)"
        Write-Host "Prompt:     $($manifest.prompt_file)"
        Write-Host ""
        Write-Host "INSTRUCTIONS:"
        Write-Host "  1. Read the prompt text from: $($manifest.prompt_file)"
        Write-Host "  2. Send prompt text BEFORE the image in your content array"
        Write-Host "  3. Attach the resized image: $($manifest.resized_image_path)"
        Write-Host "  4. Parse Claude's JSON element enumeration"
        Write-Host "  5. Reverse-map ALL bbox coordinates using scale factors"
        Write-Host ""

        if ($OutputPath) {
            Write-Host "Manifest saved to: $OutputPath"
        }
    }
    catch {
        Write-Error "Vision pipeline failed: $_"
        exit 1
    }
}
