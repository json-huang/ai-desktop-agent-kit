# perception-schema.ps1 — Unified UI Element Schema
# Defines the canonical UiElement type, validation, and serialization.
# This is the INTERFACE CONTRACT that all perception adapters (OCR, template
# match, UIA, vision) must output.  Phase 2 consumers depend on this format.
#
# Exports:
#   New-UiElement            — factory: creates a well-formed UiElement PSObject
#   Test-UiElement           — validator: checks all required properties exist
#   ConvertTo-UiElementJson  — serializer: deep JSON without truncation
#
# Usage:
#   . "$PSScriptRoot\perception-schema.ps1"
#   $el = New-UiElement -Type 'button' -X 10 -Y 20 -W 100 -H 30 -Confidence 0.95

# =============================================================================
# FUNCTION: New-UiElement
# Factory that produces a PSObject with 11 canonical properties.
# Parameter validation enforces the schema constraints at creation time.
# =============================================================================
function New-UiElement {
    param(
        [ValidateSet("button","menu","textbox","icon","link","toolbar","tab","label","image","window","desktop","other")]
        [string]$Type = "other",

        [int]$X = 0,
        [int]$Y = 0,
        [int]$W = 0,
        [int]$H = 0,

        [ValidateRange(0.0, 1.0)]
        [double]$Confidence = 0.0,

        [string]$Text = "",

        [ValidateSet("enabled","disabled","selected","focused","hidden","unknown")]
        [string]$State = "unknown",

        [bool]$IsInteractive = $false,

        [ValidateSet("uiAutomation","ocr","templateMatch","visionModel","synthesized","unknown")]
        [string]$Source = "unknown",

        [object[]]$Alternatives = @(),

        [int]$DisplayIndex = 0,

        [double]$DpiScale = 1.0,

        [int]$ParentIndex = -1
    )

    # Bounding box as a nested object — physical pixels, virtual screen origin
    $bbox = [PSCustomObject]@{
        x = $X
        y = $Y
        w = $W
        h = $H
    }

    # Build the canonical UiElement PSObject
    $element = [PSCustomObject]@{
        type          = $Type
        bbox          = $bbox
        confidence    = $Confidence
        text          = $Text
        state         = $State
        isInteractive = $IsInteractive
        source        = $Source
        alternatives  = $Alternatives
        displayIndex  = $DisplayIndex
        dpiScale      = $DpiScale
        parentIndex   = $ParentIndex
    }

    return $element
}

# =============================================================================
# FUNCTION: Test-UiElement
# Validates that an object conforms to the unified UiElement schema.
# Checks presence, type, and value ranges of all 11 required properties.
# =============================================================================
function Test-UiElement {
    param(
        [object]$Element
    )

    # Must be a non-null object
    if ($null -eq $Element) { return $false }

    # Check all 11 required properties exist
    $requiredProps = @('type', 'bbox', 'confidence', 'text', 'state',
                       'isInteractive', 'source', 'alternatives',
                       'displayIndex', 'dpiScale', 'parentIndex')

    foreach ($prop in $requiredProps) {
        if (-not (Get-Member -InputObject $Element -Name $prop -MemberType NoteProperty)) {
            return $false
        }
    }

    # Validate type enum
    \$validTypes = @('button','menu','textbox','icon','link','toolbar','tab','label','image','window','desktop','other')
    if ($Element.type -notin $validTypes) { return $false }

    # Validate bbox is a nested object with x, y, w, h
    $bboxProps = @('x','y','w','h')
    foreach ($bp in $bboxProps) {
        if (-not (Get-Member -InputObject $Element.bbox -Name $bp -MemberType NoteProperty)) {
            return $false
        }
    }

    # Validate bbox values are integers
    if ($Element.bbox.x -isnot [int] -and $Element.bbox.x -isnot [double]) { return $false }
    if ($Element.bbox.y -isnot [int] -and $Element.bbox.y -isnot [double]) { return $false }
    if ($Element.bbox.w -isnot [int] -and $Element.bbox.w -isnot [double]) { return $false }
    if ($Element.bbox.h -isnot [int] -and $Element.bbox.h -isnot [double]) { return $false }

    # Validate confidence is numeric and in range
    if ($Element.confidence -isnot [double] -and $Element.confidence -isnot [int]) { return $false }
    if ($Element.confidence -lt 0.0 -or $Element.confidence -gt 1.0) { return $false }

    # Validate text is a string
    if ($Element.text -isnot [string]) { return $false }

    # Validate state enum
    $validStates = @('enabled','disabled','selected','focused','hidden','unknown')
    if ($Element.state -notin $validStates) { return $false }

    # Validate isInteractive is boolean
    if ($Element.isInteractive -isnot [bool]) { return $false }

    # Validate source enum
    \$validSources = @('uiAutomation','ocr','templateMatch','visionModel','synthesized','unknown')
    if ($Element.source -notin $validSources) { return $false }

    # Validate alternatives is an array
    if ($Element.alternatives -isnot [array] -and $Element.alternatives -isnot [object[]]) { return $false }

    # Validate displayIndex is numeric
    if ($Element.displayIndex -isnot [int] -and $Element.displayIndex -isnot [double]) { return $false }

    # Validate dpiScale is numeric and positive
    if ($Element.dpiScale -isnot [double] -and $Element.dpiScale -isnot [int]) { return $false }
    if ($Element.dpiScale -le 0.0) { return $false }

    # Validate parentIndex is numeric
    if ($Element.parentIndex -isnot [int] -and $Element.parentIndex -isnot [double]) { return $false }

    return $true
}

# =============================================================================
# FUNCTION: ConvertTo-UiElementJson
# Serializes UiElement objects to JSON with sufficient depth to avoid
# truncation of nested bbox, alternatives, and other sub-objects.
# PowerShell's default ConvertTo-Json -Depth is 2, which is insufficient.
# =============================================================================
function ConvertTo-UiElementJson {
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [object[]]$Elements,

        [int]$Depth = 10
    )

    begin {
        $allElements = @()
    }

    process {
        $allElements += $Elements
    }

    end {
        return $allElements | ConvertTo-Json -Depth $Depth
    }
}

# All functions are automatically available when this script is dot-sourced.
# No explicit export needed — dot-sourcing runs the script in the caller's scope.
