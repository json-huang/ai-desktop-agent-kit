# resolver.ps1 — Element Description → Coordinate Resolver
# Maps DAG element descriptions (text_hint, element_type, position_hint)
# to concrete screen coordinates using perception pipeline data.
#
# Resolution Strategy (cascading, highest confidence first):
#   1. UIA exact match   — text + type match → confidence 0.95
#   2. UIA fuzzy match   — Levenshtein ≤ 2, same type → confidence 0.80
#   3. OCR match         — text found in OCR elements → confidence 0.75
#   4. Positional match  — position_hint narrows candidates → confidence 0.50
#   5. Claude Vision     — screenshot + description → Claude resolves → 0.85
#
# Exports:
#   Resolve-Element       — main entry: target description + perception → coordinates
#   Find-UiaMatch         — UIA tier search (exact + fuzzy)
#   Find-OcrMatch         — OCR tier search
#   Find-PositionalMatch  — position heuristic
#   Get-ElementCentroid   — bbox → center (x, y)
#
# Usage:
#   . "$PSScriptRoot\resolver.ps1"
#   $result = Resolve-Element -Target $target -PerceptionJson "perception.json"
#   # $result.x, $result.y = click coordinates

param(
    [hashtable]$Target = @{},
    [string]$PerceptionJson = "",
    [object[]]$PerceptionElements = $null,
    [double]$MinConfidence = 0.40
)

# Dot-source schema for type constants
. "$PSScriptRoot\perception-schema.ps1"

# =============================================================================
# FUNCTION: Get-ElementCentroid
# Converts a bounding box (x, y, w, h) to center point (cx, cy).
# =============================================================================
function Get-ElementCentroid {
    param(
        [Parameter(Mandatory=$true)]
        [object]$Bbox
    )

    $cx = [int][Math]::Floor($Bbox.x + $Bbox.w / 2)
    $cy = [int][Math]::Floor($Bbox.y + $Bbox.h / 2)

    return [PSCustomObject]@{
        x = $cx
        y = $cy
    }
}

# =============================================================================
# FUNCTION: Get-LevenshteinDistance
# Computes edit distance between two strings (for fuzzy text matching).
# PS 5.1 compatible — no LINQ, no advanced .NET.
# =============================================================================
function Get-LevenshteinDistance {
    param(
        [string]$String1,
        [string]$String2
    )

    $len1 = $String1.Length
    $len2 = $String2.Length

    if ($len1 -eq 0) { return $len2 }
    if ($len2 -eq 0) { return $len1 }

    # Build matrix as array of arrays (PS 5.1 compat)
    $matrix = New-Object 'object[]' ($len1 + 1)
    for ($i = 0; $i -le $len1; $i++) {
        $matrix[$i] = New-Object 'int[]' ($len2 + 1)
        $matrix[$i][0] = $i
    }
    for ($j = 0; $j -le $len2; $j++) {
        $matrix[0][$j] = $j
    }

    for ($i = 1; $i -le $len1; $i++) {
        for ($j = 1; $j -le $len2; $j++) {
            $cost = if ($String1[$i-1] -eq $String2[$j-1]) { 0 } else { 1 }
            $del = $matrix[$i-1][$j] + 1
            $ins = $matrix[$i][$j-1] + 1
            $sub = $matrix[$i-1][$j-1] + $cost
            $matrix[$i][$j] = [Math]::Min($del, [Math]::Min($ins, $sub))
        }
    }

    return $matrix[$len1][$len2]
}

# =============================================================================
# FUNCTION: Find-UiaMatch
# Search UIA-sourced elements for a text/type match.
# Returns: PSCustomObject { element, confidence, matchType } or $null
# =============================================================================
function Find-UiaMatch {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Target,

        [Parameter(Mandatory=$true)]
        [object[]]$Elements
    )

    $textHint = if ($Target.text_hint) { $Target.text_hint } else { "" }
    $typeHint = if ($Target.element_type) { $Target.element_type } else { "" }

    # Filter to UIA-sourced elements only
    $uiaElements = @($Elements | Where-Object { $_.source -eq "uiAutomation" })
    if ($uiaElements.Count -eq 0) { return $null }

    # --- Pass 1: Exact text + type match ---
    if ($textHint) {
        foreach ($el in $uiaElements) {
            $elText = if ($el.text) { $el.text } else { "" }
            $elType = if ($el.type) { $el.type } else { "" }

            $textMatch = $elText -eq $textHint
            $typeMatch = (-not $typeHint) -or ($elType -eq $typeHint)

            if ($textMatch -and $typeMatch) {
                $centroid = Get-ElementCentroid -Bbox $el.bbox
                return [PSCustomObject]@{
                    element    = $el
                    x          = $centroid.x
                    y          = $centroid.y
                    confidence = 0.95
                    matchType  = "uia_exact"
                    reasoning  = "UIA exact match: text='$elText', type='$elType'"
                }
            }
        }
    }

    # --- Pass 2: Fuzzy text match (Levenshtein ≤ 2) ---
    if ($textHint -and $textHint.Length -ge 3) {
        $bestDist = 999
        $bestEl = $null
        foreach ($el in $uiaElements) {
            $elText = if ($el.text) { $el.text } else { "" }
            if (-not $elText) { continue }

            $elType = if ($el.type) { $el.type } else { "" }
            $typeMatch = (-not $typeHint) -or ($elType -eq $typeHint)
            if (-not $typeMatch) { continue }

            $dist = Get-LevenshteinDistance -String1 $textHint.ToLower() -String2 $elText.ToLower()
            if ($dist -le 2 -and $dist -lt $bestDist) {
                $bestDist = $dist
                $bestEl = $el
            }
        }

        if ($bestEl) {
            $centroid = Get-ElementCentroid -Bbox $bestEl.bbox
            $conf = if ($bestDist -eq 0) { 0.95 } else { 0.80 }
            return [PSCustomObject]@{
                element    = $bestEl
                x          = $centroid.x
                y          = $centroid.y
                confidence = $conf
                matchType  = "uia_fuzzy"
                reasoning  = "UIA fuzzy match: Levenshtein=$bestDist, text='$($bestEl.text)'"
            }
        }
    }

    # --- Pass 3: Type-only match (no text_hint and no position_hint) ---
    # Skip if position_hint exists — positional matching should handle that case
    $posHint = if ($Target.position_hint) { $Target.position_hint } else { "" }
    if (-not $textHint -and $typeHint -and -not $posHint) {
        $typeMatches = @($uiaElements | Where-Object { $_.type -eq $typeHint })
        if ($typeMatches.Count -gt 0) {
            # Pick the first enabled, interactive element
            $best = $typeMatches | Where-Object { $_.state -eq "enabled" -and $_.isInteractive } | Select-Object -First 1
            if (-not $best) { $best = $typeMatches[0] }
            $centroid = Get-ElementCentroid -Bbox $best.bbox
            return [PSCustomObject]@{
                element    = $best
                x          = $centroid.x
                y          = $centroid.y
                confidence = 0.60
                matchType  = "uia_type_only"
                reasoning  = "UIA type-only match: type='$typeHint', $($typeMatches.Count) candidates"
            }
        }
    }

    return $null
}

# =============================================================================
# FUNCTION: Find-OcrMatch
# Search OCR-sourced elements for text match.
# Returns: PSCustomObject { element, confidence, matchType } or $null
# =============================================================================
function Find-OcrMatch {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Target,

        [Parameter(Mandatory=$true)]
        [object[]]$Elements
    )

    $textHint = if ($Target.text_hint) { $Target.text_hint } else { "" }
    if (-not $textHint) { return $null }

    # Filter to OCR-sourced elements
    $ocrElements = @($Elements | Where-Object { $_.source -eq "ocr" })
    if ($ocrElements.Count -eq 0) { return $null }

    # Exact match
    foreach ($el in $ocrElements) {
        $elText = if ($el.text) { $el.text } else { "" }
        if ($elText -eq $textHint) {
            $centroid = Get-ElementCentroid -Bbox $el.bbox
            return [PSCustomObject]@{
                element    = $el
                x          = $centroid.x
                y          = $centroid.y
                confidence = 0.75
                matchType  = "ocr_exact"
                reasoning  = "OCR exact match: text='$elText'"
            }
        }
    }

    # Contains match (textHint is substring of element text)
    foreach ($el in $ocrElements) {
        $elText = if ($el.text) { $el.text } else { "" }
        if ($elText -and $elText.IndexOf($textHint, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $centroid = Get-ElementCentroid -Bbox $el.bbox
            return [PSCustomObject]@{
                element    = $el
                x          = $centroid.x
                y          = $centroid.y
                confidence = 0.65
                matchType  = "ocr_contains"
                reasoning  = "OCR contains match: '$textHint' found in '$elText'"
            }
        }
    }

    # Fuzzy match (Levenshtein ≤ 3 for OCR — more lenient than UIA)
    $bestDist = 999
    $bestEl = $null
    foreach ($el in $ocrElements) {
        $elText = if ($el.text) { $el.text } else { "" }
        if (-not $elText -or $elText.Length -lt 2) { continue }

        $dist = Get-LevenshteinDistance -String1 $textHint.ToLower() -String2 $elText.ToLower()
        if ($dist -le 3 -and $dist -lt $bestDist) {
            $bestDist = $dist
            $bestEl = $el
        }
    }

    if ($bestEl -and $bestDist -le 3) {
        $centroid = Get-ElementCentroid -Bbox $bestEl.bbox
        $conf = [Math]::Max(0.50, 0.75 - $bestDist * 0.08)
        return [PSCustomObject]@{
            element    = $bestEl
            x          = $centroid.x
            y          = $centroid.y
            confidence = $conf
            matchType  = "ocr_fuzzy"
            reasoning  = "OCR fuzzy match: Levenshtein=$bestDist, text='$($bestEl.text)'"
        }
    }

    return $null
}

# =============================================================================
# FUNCTION: Find-PositionalMatch
# Use position_hint to narrow candidates when text matching fails.
# Parses natural language position: "top-left", "center", "bottom-right", etc.
# Returns: PSCustomObject { element, confidence, matchType } or $null
# =============================================================================
function Find-PositionalMatch {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Target,

        [Parameter(Mandatory=$true)]
        [object[]]$Elements,

        [int]$ScreenW = 3840,
        [int]$ScreenH = 2160
    )

    $posHint = if ($Target.position_hint) { $Target.position_hint.ToLower() } else { "" }
    $typeHint = if ($Target.element_type) { $Target.element_type } else { "" }

    if (-not $posHint -and -not $typeHint) { return $null }

    # Filter interactive elements
    $candidates = @($Elements | Where-Object {
        $_.isInteractive -eq $true -and $_.state -ne "hidden" -and $_.state -ne "offscreen"
    })

    if ($candidates.Count -eq 0) { return $null }

    # Further filter by type if specified
    if ($typeHint) {
        $typeFiltered = @($candidates | Where-Object { $_.type -eq $typeHint })
        if ($typeFiltered.Count -gt 0) { $candidates = $typeFiltered }
    }

    # Parse position hint into screen quadrants
    # Screen divided into 3x3 grid:
    #   [0,0] top-left    [1,0] top-center    [2,0] top-right
    #   [0,1] mid-left    [1,1] center        [2,1] mid-right
    #   [0,2] bot-left    [1,2] bot-center    [2,2] bot-right
    $targetQuadrant = $null
    if ($posHint -match "top.*left|upper.*left")   { $targetQuadrant = @(0, 0) }
    elseif ($posHint -match "top.*center|top.*middle|top center") { $targetQuadrant = @(1, 0) }
    elseif ($posHint -match "top.*right|upper.*right") { $targetQuadrant = @(2, 0) }
    elseif ($posHint -match "left.*center|left.*middle|mid.*left") { $targetQuadrant = @(0, 1) }
    elseif ($posHint -match "center|middle")       { $targetQuadrant = @(1, 1) }
    elseif ($posHint -match "right.*center|right.*middle|mid.*right") { $targetQuadrant = @(2, 1) }
    elseif ($posHint -match "bottom.*left|lower.*left|bot.*left") { $targetQuadrant = @(0, 2) }
    elseif ($posHint -match "bottom.*center|bot.*center|bottom middle") { $targetQuadrant = @(1, 2) }
    elseif ($posHint -match "bottom.*right|lower.*right|bot.*right") { $targetQuadrant = @(2, 2) }

    # Simple direction hints
    elseif ($posHint -match "top|upper")           { $targetQuadrant = @(1, 0) }
    elseif ($posHint -match "bottom|lower")        { $targetQuadrant = @(1, 2) }
    elseif ($posHint -match "left")                { $targetQuadrant = @(0, 1) }
    elseif ($posHint -match "right")               { $targetQuadrant = @(2, 1) }

    if (-not $targetQuadrant) { return $null }

    # Find element closest to target quadrant center
    $quadW = $ScreenW / 3
    $quadH = $ScreenH / 3
    $quadCenterX = [int](($targetQuadrant[0] + 0.5) * $quadW)
    $quadCenterY = [int](($targetQuadrant[1] + 0.5) * $quadH)

    $bestDist = [double]::MaxValue
    $bestEl = $null
    foreach ($el in $candidates) {
        $centroid = Get-ElementCentroid -Bbox $el.bbox
        $dx = $centroid.x - $quadCenterX
        $dy = $centroid.y - $quadCenterY
        $dist = [Math]::Sqrt($dx * $dx + $dy * $dy)
        if ($dist -lt $bestDist) {
            $bestDist = $dist
            $bestEl = $el
        }
    }

    if ($bestEl) {
        $centroid = Get-ElementCentroid -Bbox $bestEl.bbox
        return [PSCustomObject]@{
            element    = $bestEl
            x          = $centroid.x
            y          = $centroid.y
            confidence = 0.50
            matchType  = "positional"
            reasoning  = "Positional match: quadrant=$($targetQuadrant -join ','), dist=$([int]$bestDist)px"
        }
    }

    return $null
}

# =============================================================================
# FUNCTION: Resolve-Element
# Main entry point. Takes a target description (from DAG step) and perception
# data, returns the best coordinate match with confidence score.
#
# Target hashtable keys:
#   text_hint      — expected text/label (e.g., "File", "OK", "Address bar")
#   element_type   — UI element type (e.g., "button", "menu", "textbox")
#   position_hint  — natural language position (e.g., "top-left", "center")
#   description    — free-form description (for logging, not matching)
#
# Returns: PSCustomObject { x, y, confidence, matchType, reasoning, element }
#          or $null if no match above MinConfidence
# =============================================================================
function Resolve-Element {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Target,

        [object[]]$Elements = $null,

        [string]$PerceptionJson = "",

        [double]$MinConfidence = 0.40
    )

    # Load elements from JSON if not provided inline
    if (-not $Elements -and $PerceptionJson -and (Test-Path $PerceptionJson)) {
        try {
            $perceptionData = Get-Content $PerceptionJson -Raw | ConvertFrom-Json
            $Elements = $perceptionData.elements
        }
        catch {
            Write-Warning "resolver: failed to parse perception JSON: $_"
            return $null
        }
    }

    if (-not $Elements -or $Elements.Count -eq 0) {
        Write-Warning "resolver: no perception elements available"
        return $null
    }

    $description = if ($Target.description) { $Target.description } else { "unknown" }
    Write-Host "RESOLVE|start|target='$description'|elements=$($Elements.Count)"

    # --- Strategy 1: UIA match (exact + fuzzy + type-only) ---
    $uiaResult = Find-UiaMatch -Target $Target -Elements $Elements
    if ($uiaResult -and $uiaResult.confidence -ge $MinConfidence) {
        Write-Host "RESOLVE|hit|$($uiaResult.matchType)|confidence=$($uiaResult.confidence)|($($uiaResult.x),$($uiaResult.y))"
        return $uiaResult
    }

    # --- Strategy 2: OCR match (exact + contains + fuzzy) ---
    $ocrResult = Find-OcrMatch -Target $Target -Elements $Elements
    if ($ocrResult -and $ocrResult.confidence -ge $MinConfidence) {
        Write-Host "RESOLVE|hit|$($ocrResult.matchType)|confidence=$($ocrResult.confidence)|($($ocrResult.x),$($ocrResult.y))"
        return $ocrResult
    }

    # --- Strategy 3: Positional heuristic ---
    $posResult = Find-PositionalMatch -Target $Target -Elements $Elements
    if ($posResult -and $posResult.confidence -ge $MinConfidence) {
        Write-Host "RESOLVE|hit|$($posResult.matchType)|confidence=$($posResult.confidence)|($($posResult.x),$($posResult.y))"
        return $posResult
    }

    # --- No match found ---
    $bestAttempt = @($uiaResult, $ocrResult, $posResult) |
        Where-Object { $null -ne $_ } |
        Sort-Object -Property confidence -Descending |
        Select-Object -First 1

    if ($bestAttempt) {
        Write-Host "RESOLVE|miss|best=$($bestAttempt.matchType)|confidence=$($bestAttempt.confidence)|below threshold $MinConfidence"
    } else {
        Write-Host "RESOLVE|miss|no candidates found for target='$description'"
    }

    return $null
}

# =============================================================================
# SCRIPT BODY: When invoked directly (not dot-sourced)
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Target -or $Target.Count -eq 0) {
        Write-Error "Target parameter is required. Usage: .\resolver.ps1 -Target @{text_hint='File'; element_type='menu'}"
        exit 1
    }

    $result = Resolve-Element -Target $Target -Elements $PerceptionElements -PerceptionJson $PerceptionJson -MinConfidence $MinConfidence

    if ($result) {
        Write-Output "RESOLVED|$($result.x),$($result.y)|confidence=$($result.confidence)|$($result.matchType)"
        exit 0
    } else {
        Write-Output "RESOLVE_FAILED|no match above threshold $MinConfidence"
        exit 1
    }
}
