# template-adapter.ps1 — Template match output to unified UI element schema adapter
# Wraps findimage.ps1 output, normalizing it to UiElement objects via perception-schema.ps1.
# NCC score maps directly to confidence; matched regions are treated as interactive icons.
#
# Usage (as script):
#   .\template-adapter.ps1 -Template "button.png"
#   .\template-adapter.ps1 -Template "icon.png" -Threshold 0.8 -TopN 5
#   .\template-adapter.ps1 -Template "x.png" -Screen "screenshot.png"
#
# Usage (as module — dot-source to get ConvertFrom-TemplateMatch):
#   . "$PSScriptRoot\template-adapter.ps1"
#   $elements = ConvertFrom-TemplateMatch -Matches $matches -Threshold 0.7

param(
    [string]$Template = "",             # Template image path (required in driver mode)

    [string]$Screen = "",               # Screenshot path (empty = capture fresh)
    [float]$Threshold = 0.7,            # Minimum NCC score (locked decision)
    [int]$TopN = 10                     # Maximum matches to return
)

# Dot-source the schema module
. "$PSScriptRoot\perception-schema.ps1"

# =============================================================================
# FUNCTION: ConvertFrom-TemplateMatch
# Converts an array of MatchResult objects into unified UiElement objects.
#
# Each MatchResult object must have: .X, .Y, .Score, .TemplateW, .TemplateH
#
# Processing:
#   1. Filter by confidence >= threshold
#   2. Create UiElement per match (type="icon", source="templateMatch", isInteractive=$true)
#   3. Sort by confidence descending, take TopN
# =============================================================================
function ConvertFrom-TemplateMatch {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyCollection()]
        [object[]]$Matches = @(),

        [float]$Threshold = 0.7,

        [int]$TopN = 10
    )

    $elements = [System.Collections.Generic.List[object]]::new()

    foreach ($match in $Matches) {
        # Filter by confidence threshold
        if ($match.Score -lt $Threshold) {
            continue
        }

        $element = New-UiElement -Type 'icon' `
            -X $match.X -Y $match.Y `
            -W $match.TemplateW -H $match.TemplateH `
            -Confidence $match.Score `
            -Text '' `
            -State 'unknown' `
            -IsInteractive $true `
            -Source 'templateMatch' `
            -Alternatives @() `
            -DisplayIndex 0 `
            -DpiScale 1.0 `
            -ParentIndex -1

        $elements.Add($element)
    }

    # Sort by confidence descending, take TopN
    $arr = $elements.ToArray()
    if ($arr.Count -eq 0) {
        @()
        return
    }
    $sorted = $arr | Sort-Object -Property confidence -Descending | Select-Object -First $TopN
    $result = @($sorted)
    $result
}

# =============================================================================
# DRIVER: If invoked as a script, run template matching and convert output
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    # Template is mandatory when run as a script
    if (-not $Template) {
        Write-Output "ERROR|Template parameter is required. Usage: template-adapter.ps1 -Template 'icon.png'"
        exit 1
    }

    $findImageScript = "$PSScriptRoot\findimage.ps1"

    if (-not (Test-Path $findImageScript)) {
        Write-Output "ERROR|findimage.ps1 not found at $findImageScript"
        exit 1
    }

    if (-not (Test-Path $Template)) {
        Write-Output "ERROR|template image not found: $Template"
        exit 1
    }

    # Build findimage.ps1 arguments
    $args = @(
        "-Template", $Template,
        "-Threshold", $Threshold,
        "-TopN", $TopN
    )

    if ($Screen) {
        $args += @("-Screen", $Screen)
    }

    # Run findimage.ps1
    $findOutput = & powershell -NoProfile -ExecutionPolicy Bypass `
        -File $findImageScript @args 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Output "ERROR|findimage.ps1 failed with exit code $LASTEXITCODE"
        exit 1
    }

    # Parse findimage.ps1 output: OK|centerX,centerY|score=0.XXXX|rect=X,Y,W,H
    $matches = @()
    foreach ($outLine in $findOutput) {
        if ($outLine -match '^OK\|\d+,\d+\|score=([\d.]+)\|rect=(\d+),(\d+),(\d+),(\d+)$') {
            $matches += [PSCustomObject]@{
                Score     = [float]$Matches[1]
                X         = [int]$Matches[2]
                Y         = [int]$Matches[3]
                TemplateW = [int]$Matches[4]
                TemplateH = [int]$Matches[5]
            }
        }
    }

    # Convert to unified schema
    $elements = ConvertFrom-TemplateMatch -Matches $matches -Threshold $Threshold -TopN $TopN

    # Output as JSON
    if ($elements.Count -gt 0) {
        $json = ConvertTo-UiElementJson -Elements $elements -Depth 10
        Write-Output $json
    } else {
        Write-Output '[]'
    }
}
