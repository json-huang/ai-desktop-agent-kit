# ocr-adapter.ps1 — OCR output to unified UI element schema adapter
# Wraps ocr.ps1 output, normalizing it to UiElement objects via perception-schema.ps1.
# Handles noise filtering and within-tier deduplication.
#
# Usage (as script):
#   .\ocr-adapter.ps1 -ScreenshotPath "screen.png" -Lang "en"
#   .\ocr-adapter.ps1                                  # capture + OCR current screen
#
# Usage (as module — dot-source to get ConvertFrom-OcrResult):
#   . "$PSScriptRoot\ocr-adapter.ps1"
#   $elements = ConvertFrom-OcrResult -OcrLines $lines

param(
    [string]$ScreenshotPath = "",       # Path to screenshot PNG (empty = capture fresh)
    [string]$Lang = "",                 # OCR language tag (zh-Hans, en, ja, etc.)
    [switch]$NoDeduplicate              # Skip deduplication (debug mode)
)

# Dot-source the schema module
. "$PSScriptRoot\perception-schema.ps1"

# =============================================================================
# FUNCTION: ConvertFrom-OcrResult
# Converts an array of OcrLine objects into unified UiElement objects.
#
# Each OcrLine object must have: .Text, .Left, .Top, .Width, .Height
#
# Processing:
#   1. Noise filter: discard blocks < 8x8 pixels or tiny single chars
#   2. Create UiElement per line (type="label", confidence=0.85)
#   3. Deduplicate overlapping elements (IoU >= 0.80, same text)
# =============================================================================
function ConvertFrom-OcrResult {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyCollection()]
        [object[]]$OcrLines = @(),

        [switch]$NoDeduplicate
    )

    $elements = [System.Collections.Generic.List[object]]::new()

    # =========================================================================
    # Step 1: Noise filtering + element creation
    # =========================================================================
    foreach ($line in $OcrLines) {
        $w = $line.Width
        $h = $line.Height
        $txt = if ($line.Text) { $line.Text } else { "" }

        # NOISE FILTER: discard blocks smaller than 8x8 pixels
        if ($w -lt 8 -or $h -lt 8) {
            continue
        }

        # NOISE FILTER: single characters in tiny area (likely image noise)
        if ($txt.Length -lt 2 -and ($w * $h) -lt 100) {
            continue
        }

        $element = New-UiElement -Type 'label' `
            -X $line.Left -Y $line.Top -W $w -H $h `
            -Confidence 0.85 `
            -Text $txt `
            -State 'unknown' `
            -IsInteractive $false `
            -Source 'ocr' `
            -Alternatives @() `
            -DisplayIndex 0 `
            -DpiScale 1.0 `
            -ParentIndex -1

        $elements.Add($element)
    }

    # =========================================================================
    # Step 2: Deduplication (IoU >= 0.80, same case-insensitive trimmed text)
    # =========================================================================
    if (-not $NoDeduplicate -and $elements.Count -gt 1) {
        $deduped = [System.Collections.Generic.List[object]]::new()
        $skipIndices = [System.Collections.Generic.HashSet[int]]::new()

        for ($i = 0; $i -lt $elements.Count; $i++) {
            if ($skipIndices.Contains($i)) { continue }

            $keepIdx = $i
            $keepArea = $elements[$i].bbox.w * $elements[$i].bbox.h
            $keepText = $elements[$i].text.Trim().ToLowerInvariant()

            for ($j = $i + 1; $j -lt $elements.Count; $j++) {
                if ($skipIndices.Contains($j)) { continue }

                $otherText = $elements[$j].text.Trim().ToLowerInvariant()

                # Only deduplicate if text matches (case-insensitive, trimmed)
                if ($keepText -ne $otherText) { continue }

                # Compute IoU
                $iou = _ComputeIoU `
                    $elements[$keepIdx].bbox.x $elements[$keepIdx].bbox.y `
                    $elements[$keepIdx].bbox.w $elements[$keepIdx].bbox.h `
                    $elements[$j].bbox.x $elements[$j].bbox.y `
                    $elements[$j].bbox.w $elements[$j].bbox.h

                if ($iou -ge 0.80) {
                    # Keep the one with larger area
                    $otherArea = $elements[$j].bbox.w * $elements[$j].bbox.h
                    if ($otherArea -gt $keepArea) {
                        $skipIndices.Add($keepIdx) | Out-Null
                        $keepIdx = $j
                        $keepArea = $otherArea
                        $keepText = $otherText
                    } else {
                        $skipIndices.Add($j) | Out-Null
                    }
                }
            }

            $deduped.Add($elements[$keepIdx])
        }

        $result = $deduped.ToArray()
        $result
        return
    }

    $result = $elements.ToArray()
    $result
}

# =============================================================================
# HELPER: _ComputeIoU
# Intersection over Union for two axis-aligned bounding boxes.
# =============================================================================
function _ComputeIoU {
    param(
        [double]$ax1, [double]$ay1, [double]$aw, [double]$ah,
        [double]$bx1, [double]$by1, [double]$bw, [double]$bh
    )

    $ax2 = $ax1 + $aw; $ay2 = $ay1 + $ah
    $bx2 = $bx1 + $bw; $by2 = $by1 + $bh

    # Intersection
    $ix1 = [Math]::Max($ax1, $bx1)
    $iy1 = [Math]::Max($ay1, $by1)
    $ix2 = [Math]::Min($ax2, $bx2)
    $iy2 = [Math]::Min($ay2, $by2)

    $iw = [Math]::Max(0.0, $ix2 - $ix1)
    $ih = [Math]::Max(0.0, $iy2 - $iy1)
    $intersection = $iw * $ih

    if ($intersection -le 0) { return 0.0 }

    $areaA = $aw * $ah
    $areaB = $bw * $bh
    $union = $areaA + $areaB - $intersection

    if ($union -le 0) { return 0.0 }

    return $intersection / $union
}

# =============================================================================
# DRIVER: If invoked as a script, run OCR and convert output
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    $ocrScript = "$PSScriptRoot\ocr.ps1"

    if (-not (Test-Path $ocrScript)) {
        Write-Output "ERROR|ocr.ps1 not found at $ocrScript"
        exit 1
    }

    # Capture screenshot if none provided
    $imgParam = ""
    if ($ScreenshotPath) {
        $imgParam = "-Image `"$ScreenshotPath`""
    }

    $langParam = ""
    if ($Lang) {
        $langParam = "-Lang `"$Lang`""
    }

    # Run ocr.ps1 with -Detail to get per-line bounding boxes
    $ocrOutput = & powershell -NoProfile -ExecutionPolicy Bypass `
        -File $ocrScript -Detail $imgParam $langParam 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Output "ERROR|ocr.ps1 failed with exit code $LASTEXITCODE"
        exit 1
    }

    # Parse ocr.ps1 output: LINE|text|left,top|widthxheight
    $lines = @()
    foreach ($outLine in $ocrOutput) {
        if ($outLine -match '^LINE\|(.+?)\|(\d+),(\d+)\|(\d+)x(\d+)$') {
            $lines += [PSCustomObject]@{
                Text   = $Matches[1]
                Left   = [int]$Matches[2]
                Top    = [int]$Matches[3]
                Width  = [int]$Matches[4]
                Height = [int]$Matches[5]
            }
        }
    }

    # Convert to unified schema
    if ($NoDeduplicate) {
        $elements = ConvertFrom-OcrResult -OcrLines $lines -NoDeduplicate
    } else {
        $elements = ConvertFrom-OcrResult -OcrLines $lines
    }

    # Output as JSON
    $json = ConvertTo-UiElementJson -Elements $elements -Depth 10
    Write-Output $json
}
