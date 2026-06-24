# render-annotations.ps1 — Annotated Screenshot Renderer
# Draws colored bounding boxes and labels on a screenshot PNG using
# System.Drawing.Graphics. Produces the human-readable visual output
# for the perception pipeline.
#
# Exports:
#   Add-PerceptionAnnotations — main function: draws boxes and labels
#
# Per-source colors:
#   uiAutomation  → Green  (#00CC00)
#   ocr           → Blue   (#0066CC)
#   templateMatch → Orange (#CC6600)
#   visionModel   → Red    (#CC0000)
#   conflict      → Magenta (#CC00CC)
#
# Usage (as module — dot-source):
#   . "$PSScriptRoot\render-annotations.ps1"
#   $pngPath = Add-PerceptionAnnotations -ScreenshotPath "screen.png" -Elements $elements
#
# Usage (as script):
#   .\render-annotations.ps1 -ScreenshotPath "screen.png" -JsonPath "perception.json"

# NOTE: No script-level param() block — dot-sourcing creates variables in caller's
# scope that would shadow perception.ps1's $screenshotPath, breaking annotations.
# Script-level params are defined inside the driver guard below.

# =============================================================================
# FUNCTION: Add-PerceptionAnnotations
# Draws colored bounding boxes and labels for all UiElement objects on a
# screenshot PNG. Returns "OK|outputPath|annotated".
# =============================================================================
function Add-PerceptionAnnotations {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ScreenshotPath,          # Input PNG screenshot path

        [Parameter(Mandatory=$true)]
        [object[]]$Elements,               # Array of UiElement PSObjects

        [string]$OutputPath = "",          # Output annotated PNG path (auto-generated if empty)

        [int]$BoxLineWidth = 2             # Bounding box line width in pixels
    )

    # 1. LOAD the screenshot
    Add-Type -AssemblyName System.Drawing

    if (-not (Test-Path $ScreenshotPath)) {
        Write-Output "ERROR|screenshot not found: $ScreenshotPath"
        return
    }

    $bitmap = [System.Drawing.Bitmap]::FromFile($ScreenshotPath)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    # 2. For EACH element in $Elements, draw bounding box and label
    foreach ($element in $Elements) {
        if ($null -eq $element) { continue }

        # Validate bbox exists and has valid dimensions
        if ($null -eq $element.bbox) { continue }
        $bx = $element.bbox.x
        $by = $element.bbox.y
        $bw = $element.bbox.w
        $bh = $element.bbox.h

        # Skip zero-size or off-screen elements
        if ($bw -le 0 -or $bh -le 0) { continue }
        if ($bx + $bw -le 0 -or $by + $bh -le 0) { continue }

        # 2a. DETERMINE box color based on element.source
        $source = if ($element.source) { $element.source } else { "unknown" }
        $color = switch ($source) {
            "uiAutomation"  { [System.Drawing.Color]::FromArgb(255, 0, 204, 0)   }  # Green #00CC00
            "ocr"           { [System.Drawing.Color]::FromArgb(255, 0, 102, 204)  }  # Blue #0066CC
            "templateMatch" { [System.Drawing.Color]::FromArgb(255, 204, 102, 0)  }  # Orange #CC6600
            "visionModel"   { [System.Drawing.Color]::FromArgb(255, 204, 0, 0)    }  # Red #CC0000
            default         { [System.Drawing.Color]::FromArgb(255, 204, 0, 204)  }  # Magenta #CC00CC
        }

        # 2b. OVERRIDE to magenta if element.alternatives is non-empty (conflict detected)
        $alternativesCount = 0
        if ($null -ne $element.alternatives) {
            if ($element.alternatives -is [array]) {
                $alternativesCount = $element.alternatives.Count
            }
        }
        if ($alternativesCount -gt 0) {
            $color = [System.Drawing.Color]::FromArgb(255, 204, 0, 204)  # Magenta #CC00CC
        }

        # 2c. CREATE pen
        $pen = [System.Drawing.Pen]::new($color, $BoxLineWidth)

        # 2d. DRAW rectangle
        $g.DrawRectangle($pen, $bx, $by, $bw, $bh)

        # 2e. BUILD label text
        $typeText = if ($element.type) { $element.type } else { "unknown" }
        $label = "$typeText"
        if ($element.text -and $element.text.Length -gt 0) {
            $label += " '$($element.text)'"
        }
        $conf = 0.0
        if ($null -ne $element.confidence) { $conf = [double]$element.confidence }
        if ($conf -gt 0) {
            $label += " ($([math]::Round($conf, 2)))"
        }

        # 2f. MEASURE label size
        $font = [System.Drawing.Font]::new("Arial", 10)
        $labelSize = $g.MeasureString($label, $font)

        # 2g. DRAW label background (filled rectangle behind text)
        $labelX = $bx
        $labelY = $by - [int]$labelSize.Height - 2
        if ($labelY -lt 0) {
            # Place below box if not enough room above
            $labelY = $by + $bh + 2
        }
        $labelBg = [System.Drawing.RectangleF]::new($labelX, $labelY, $labelSize.Width + 4, $labelSize.Height)
        $g.FillRectangle([System.Drawing.SolidBrush]::new($color), $labelBg)

        # 2h. DRAW label text (white on colored background)
        $g.DrawString($label, $font, [System.Drawing.Brushes]::White, $labelX + 2, $labelY)

        # 2i. DISPOSE pen and font after each element
        $pen.Dispose()
        $font.Dispose()
    }

    # 3. SAVE the annotated image
    if (-not $OutputPath) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ScreenshotPath)
        $dirName = [System.IO.Path]::GetDirectoryName($ScreenshotPath)
        $OutputPath = Join-Path $dirName "${baseName}_annotated.png"
    }

    # Ensure output directory exists
    $outDir = Split-Path $OutputPath -Parent
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)

    # 4. CLEANUP
    $g.Dispose()
    $bitmap.Dispose()

    # 5. RETURN output path
    Write-Output "OK|$OutputPath|annotated"
}

# =============================================================================
# SCRIPT BODY: When invoked directly (not dot-sourced)
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    # Parse command-line arguments (no script-level param() to avoid variable shadowing when dot-sourced)
    $ArgScreenshotPath = $args[0]
    $ArgJsonPath = if ($args.Count -gt 1) { $args[1] } else { "" }
    $ArgOutputPath = if ($args.Count -gt 2) { $args[2] } else { "" }

    if (-not $ArgScreenshotPath) {
        Write-Output "ERROR|usage: render-annotations.ps1 <screenshotPath> [jsonPath] [outputPath]"
        exit 1
    }
    if (-not (Test-Path $ArgScreenshotPath)) {
        Write-Output "ERROR|screenshot not found: $ArgScreenshotPath"
        exit 1
    }

    $Elements = @()

    if ($ArgJsonPath -and (Test-Path $ArgJsonPath)) {
        # Read elements from JSON file
        $jsonContent = Get-Content $ArgJsonPath -Raw | ConvertFrom-Json
        if ($null -ne $jsonContent) {
            # If JSON is a single object with an Elements property, extract the array
            if (Get-Member -InputObject $jsonContent -Name 'elements' -MemberType NoteProperty) {
                $Elements = @($jsonContent.elements)
            }
            elseif ($jsonContent -is [array]) {
                $Elements = @($jsonContent)
            }
            else {
                $Elements = @($jsonContent)
            }
        }
    }

    if ($Elements.Count -eq 0) {
        Write-Output "WARNING|no elements to annotate"
        # Still produce the output by copying the original
        if (-not $ArgOutputPath) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ArgScreenshotPath)
            $dirName = [System.IO.Path]::GetDirectoryName($ArgScreenshotPath)
            $ArgOutputPath = Join-Path $dirName "${baseName}_annotated.png"
        }
        Copy-Item $ArgScreenshotPath $ArgOutputPath -Force
        Write-Output "OK|$ArgOutputPath|annotated (no elements)"
        exit 0
    }

    $result = Add-PerceptionAnnotations -ScreenshotPath $ArgScreenshotPath -Elements $Elements -OutputPath $ArgOutputPath
    Write-Output $result
}
