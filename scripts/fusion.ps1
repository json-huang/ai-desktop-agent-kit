# fusion.ps1 — Multi-Tier Perception Fusion Engine
# Merges element outputs from all perception tiers (UIA, OCR, template matching,
# vision model) into a single unified element tree. Overlapping elements are
# handled via conflict marking (keep both with source annotation). Redundant
# detections are deduplicated (higher-priority source wins).
#
# Exports:
#   Merge-PerceptionTiers — main orchestration function
#   Add-TierElements      — merges new tier elements with existing list
#   Compute-IoU           — Intersection over Union for bounding boxes
#   Place-NonUiaInTree    — assigns parentIndex for non-UIA elements
#   Build-ElementTree     — creates root element and finalizes tree
#
# Usage (as module — dot-source):
#   . "$PSScriptRoot\fusion.ps1"
#   $merged = Merge-PerceptionTiers -UiaElements $uia -OcrElements $ocr
#   $json = ConvertTo-UiElementJson -Elements $merged
#
# Usage (as script):
#   .\fusion.ps1 -UiaPath "uia.json" -OcrPath "ocr.json"

param(
    [string]$UiaPath = "",
    [string]$OcrPath = "",
    [string]$TemplatePath = "",
    [string]$VisionPath = ""
)

# Dot-source the schema module (required for New-UiElement)
. "$PSScriptRoot\perception-schema.ps1"

# =============================================================================
# PRIORITY ORDER (lower number = higher priority, wins deduplication)
# uiAutomation > visionModel > templateMatch > ocr
# =============================================================================
$script:FusionSourcePriority = @{
    'uiAutomation' = 0
    'visionModel'  = 1
    'templateMatch'= 2
    'ocr'          = 3
}

function Get-FusionPriority {
    param([string]$Source)
    if ($FusionSourcePriority.ContainsKey($Source)) {
        return $FusionSourcePriority[$Source]
    }
    return 99  # unknown sources get lowest priority
}

# =============================================================================
# FUNCTION: Compute-IoU
# Intersection over Union for two axis-aligned bounding boxes.
# Each box must be an object or hashtable with .x, .y, .w, .h properties.
# =============================================================================
function Compute-IoU {
    param(
        [object]$Box1,
        [object]$Box2
    )

    $ax1 = $Box1.x; $ay1 = $Box1.y; $aw = $Box1.w; $ah = $Box1.h
    $bx1 = $Box2.x; $by1 = $Box2.y; $bw = $Box2.w; $bh = $Box2.h

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
# HELPER: _Set-Alternatives
# Safely adds an alternative element to .alternatives[], ensuring the
# array property exists and avoiding duplicates (same text + source).
# Uses Add-Member -Force to handle PSObjects whose NoteProperty may
# have been stripped during pipeline transfer.
# =============================================================================
function _Set-Alternatives {
    param(
        [object]$Target,
        [object]$AltElement
    )

    # Ensure alternatives property exists as an array
    if ($null -eq $Target.alternatives) {
        $Target | Add-Member -MemberType NoteProperty -Name 'alternatives' -Value @() -Force
    }

    # Check for existing duplicate (same text + source)
    $found = $false
    foreach ($existingAlt in $Target.alternatives) {
        if ($null -ne $existingAlt -and
            $existingAlt.text -eq $AltElement.text -and
            $existingAlt.source -eq $AltElement.source) {
            $found = $true
            break
        }
    }

    if (-not $found) {
        $newAlts = @($Target.alternatives) + @($AltElement)
        $Target | Add-Member -MemberType NoteProperty -Name 'alternatives' -Value $newAlts -Force
    }
}

# =============================================================================
# FUNCTION: Add-TierElements
# Merges a new tier's elements into an existing merged list.
# Handles deduplication (same text + overlap → higher priority wins) and
# conflict marking (different text + overlap → both kept with cross-references).
# =============================================================================
function Add-TierElements {
    param(
        [object[]]$Existing,           # already-merged elements
        [object[]]$New,                # new tier elements to add
        [double]$OverlapThreshold = 0.5  # IoU threshold for "same region"
    )

    # Build a mutable result list. Remove any pipeline-wrapped arrays.
    $resultList = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $Existing -and $Existing.Count -gt 0) {
        foreach ($el in $Existing) {
            # Ensure each element has a proper alternatives array
            if ($null -eq $el.alternatives) {
                $el | Add-Member -MemberType NoteProperty -Name 'alternatives' -Value @() -Force
            }
            [void]$resultList.Add($el)
        }
    }

    foreach ($newElement in $New) {
        # Ensure new element has a proper alternatives array
        if ($null -eq $newElement.alternatives) {
            $newElement | Add-Member -MemberType NoteProperty -Name 'alternatives' -Value @() -Force
        }

        $addNew = $true

        for ($i = 0; $i -lt $resultList.Count; $i++) {
            $existing = $resultList[$i]
            if ($null -eq $existing) { continue }

            $iou = Compute-IoU $existing.bbox $newElement.bbox

            if ($iou -ge $OverlapThreshold) {
                # Compare text case-insensitive trimmed
                $existingText = if ($existing.text) { $existing.text.Trim() } else { "" }
                $newText = if ($newElement.text) { $newElement.text.Trim() } else { "" }
                $textMatch = ($existingText -eq $newText)

                if ($textMatch) {
                    # DEDUPLICATE: same text, compare priorities
                    $existingPriority = Get-FusionPriority $existing.source
                    $newPriority = Get-FusionPriority $newElement.source

                    if ($existingPriority -le $newPriority) {
                        # Existing has higher or equal priority -> keep existing,
                        # add new to existing's alternatives
                        _Set-Alternatives -Target $existing -AltElement $newElement
                        $addNew = $false
                    }
                    else {
                        # New has higher priority -> CONFLICT per plan: keep both,
                        # cross-reference in alternatives
                        _Set-Alternatives -Target $existing -AltElement $newElement
                        _Set-Alternatives -Target $newElement -AltElement $existing
                    }
                    break  # Stop checking other existing elements
                }
                else {
                    # CONFLICT: different text -> keep both, cross-reference
                    _Set-Alternatives -Target $existing -AltElement $newElement
                    _Set-Alternatives -Target $newElement -AltElement $existing
                }
            }
        }

        if ($addNew) {
            [void]$resultList.Add($newElement)
        }
    }

    $resultList.ToArray()
}

# =============================================================================
# FUNCTION: Place-NonUiaInTree
# Assigns parentIndex to non-UIA elements based on containment within UIA ancestors.
# For each element where source != "uiAutomation" AND parentIndex == -1:
#   - Find the UIA element whose bbox fully contains this element's bbox
#   - If multiple UIA elements contain it, pick the deepest (smallest area)
#   - If no containing UIA element found: parentIndex stays -1
# =============================================================================
function Place-NonUiaInTree {
    param(
        [object[]]$Elements
    )

    # Ensure array type (prevent pipeline unwrapping on single element)
    $Elements = @($Elements)

    $count = $Elements.Count
    if ($count -eq 0) { return $Elements }

    # Build list of UIA elements with their indices
    $uiaElements = @()
    for ($i = 0; $i -lt $count; $i++) {
        if ($Elements[$i].source -eq "uiAutomation") {
            $uiaElements += [PSCustomObject]@{ Index = $i; Element = $Elements[$i] }
        }
    }

    # For each non-UIA element with parentIndex == -1, find containing UIA ancestor
    for ($i = 0; $i -lt $count; $i++) {
        $el = $Elements[$i]
        if ($el.source -eq "uiAutomation") { continue }
        if ($el.parentIndex -ne -1) { continue }

        $bestMatch = $null
        $bestArea = [double]::MaxValue

        foreach ($uiaEntry in $uiaElements) {
            $uia = $uiaEntry.Element
            $uiaBbox = $uia.bbox

            # Check full containment: element completely inside UIA element
            if ($el.bbox.x -ge $uiaBbox.x -and
                $el.bbox.y -ge $uiaBbox.y -and
                ($el.bbox.x + $el.bbox.w) -le ($uiaBbox.x + $uiaBbox.w) -and
                ($el.bbox.y + $el.bbox.h) -le ($uiaBbox.y + $uiaBbox.h)) {

                $area = $uiaBbox.w * $uiaBbox.h
                if ($area -lt $bestArea) {
                    $bestArea = $area
                    $bestMatch = $uiaEntry.Index
                }
            }
        }

        if ($null -ne $bestMatch) {
            $el.parentIndex = $bestMatch
        }
    }

    $Elements
}

# =============================================================================
# FUNCTION: Build-ElementTree
# Creates a root "desktop" element at index 0, prepends it to the element list,
# increments all parentIndex values by 1, and maps parentIndex=-1 to 0 (root).
# =============================================================================
function Build-ElementTree {
    param(
        [object[]]$Elements
    )

    # Ensure array type (prevent pipeline unwrapping on single element)
    $Elements = @($Elements)

    # Create root element
    $root = New-UiElement -Type "desktop" -X 0 -Y 0 -W 99999 -H 99999 `
        -Confidence 1.0 -Text "" -State "enabled" -IsInteractive $false `
        -Source "synthesized" -ParentIndex -1 -DisplayIndex 0 -DpiScale 1.0

    # Build new list with root at index 0
    $finalList = [System.Collections.Generic.List[object]]::new()
    $finalList.Add($root) 

    foreach ($el in $Elements) {
        $finalList.Add($el) 
    }

    $finalArr = $finalList.ToArray()

    # Increment all parentIndex values by 1 (to account for root at index 0)
    for ($i = 0; $i -lt $finalArr.Count; $i++) {
        $finalArr[$i].parentIndex = $finalArr[$i].parentIndex + 1
    }

    # All elements with parentIndex=0 (was -1 before increment) → point to root (index 0)
    for ($i = 0; $i -lt $finalArr.Count; $i++) {
        if ($finalArr[$i].parentIndex -eq 0) {
            $finalArr[$i].parentIndex = 0
        }
    }

    # Root element stays at parentIndex=-1
    $finalArr[0].parentIndex = -1

    $finalArr
}

# =============================================================================
# FUNCTION: Merge-PerceptionTiers (MAIN ORCHESTRATION)
# Accepts element arrays from all four tiers and produces a single merged
# element tree. Processing order (highest priority tier first):
#   1. UIA (base, already has tree structure via parentIndex)
#   2. OCR
#   3. Template matching
#   4. Vision model
#   5. Place-NonUiaInTree (assign parentIndex to non-UIA elements)
#   6. Build-ElementTree (add root, finalize parentIndex)
# =============================================================================
function Merge-PerceptionTiers {
    param(
        [object[]]$UiaElements = @(),
        [object[]]$OcrElements = @(),
        [object[]]$TemplateElements = @(),
        [object[]]$VisionElements = @()
    )

    # Step 1: Start with UIA elements as the base
    $merged = @()
    if ($UiaElements.Count -gt 0) {
        $merged = @($UiaElements)
    }

    # Step 2-4: Add each tier in priority order
    if ($OcrElements.Count -gt 0) {
        $merged = @(Add-TierElements -Existing $merged -New $OcrElements)
    }
    if ($TemplateElements.Count -gt 0) {
        $merged = @(Add-TierElements -Existing $merged -New $TemplateElements)
    }
    if ($VisionElements.Count -gt 0) {
        $merged = @(Add-TierElements -Existing $merged -New $VisionElements)
    }

    # Step 5: Assign parentIndex to non-UIA elements
    $merged = @(Place-NonUiaInTree -Elements $merged)

    # Step 6: Add root element and finalize parentIndex assignments
    $merged = @(Build-ElementTree -Elements $merged)

    $merged
}

# =============================================================================
# DRIVER: If invoked as a script (not dot-sourced), accept JSON input and
# produce merged JSON output to stdout.
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    function _ReadElements {
        param([string]$Path)
        if ($Path -and (Test-Path $Path)) {
            $json = Get-Content $Path -Raw
            if ($json.Trim().Length -gt 0) {
                return @($json | ConvertFrom-Json)
            }
        }
        return @()
    }

    $uiaEls = _ReadElements $UiaPath
    $ocrEls = _ReadElements $OcrPath
    $tmplEls = _ReadElements $TemplatePath
    $visEls = _ReadElements $VisionPath

    $merged = Merge-PerceptionTiers -UiaElements $uiaEls -OcrElements $ocrEls `
        -TemplateElements $tmplEls -VisionElements $visEls

    $json = ConvertTo-UiElementJson -Elements $merged -Depth 10
    Write-Output $json
}
