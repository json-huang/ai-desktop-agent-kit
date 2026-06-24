# Coordinate Scaling Module
# Implements Anthropic's recommended coordinate pipeline for Claude Vision integration.
# Pure-math module with no external dependencies — testable in complete isolation.
#
# Functions:
#   Compute-MaxApiFit        — computes the optimal display resolution for API image input
#   ConvertFrom-ApiCoordinates — reverse-maps a single point from display space to screen pixels
#   ConvertFrom-ApiBbox       — reverse-maps a full bounding box from display space to screen pixels
#
# Usage (dot-source):
#   . "C:\Users\DBA126\.claude\scripts\coordinate-scaling.ps1"
#   $w, $h = Compute-MaxApiFit 3840 2160
#   $point = ConvertFrom-ApiCoordinates 600 400 1280 720 3840 2160
#   $bbox  = ConvertFrom-ApiBbox 100 100 200 150 1280 720 3840 2160
#
# Constants:
#   $CLAUDE_46_MAX_LONG_EDGE = 1568 (Claude 4.6 family)
#   $CLAUDE_46_MAX_PIXELS    = 1150000 (1.15 MP)
#   $CLAUDE_47_MAX_LONG_EDGE = 2576 (Opus 4.7)
#   $CLAUDE_47_MAX_PIXELS    = 3750000 (3.75 MP)

# === Pre-defined Constants ===

$SCRIPT:CLAUDE_46_MAX_LONG_EDGE = 1568
$SCRIPT:CLAUDE_46_MAX_PIXELS = 1150000
$SCRIPT:CLAUDE_47_MAX_LONG_EDGE = 2576
$SCRIPT:CLAUDE_47_MAX_PIXELS = 3750000

# === Functions ===

<#
.SYNOPSIS
Computes the optimal display resolution for sending an image to the Claude API,
preserving aspect ratio while fitting within pixel budget and long-edge limits.

.DESCRIPTION
Uses the formula from Anthropic best practices (RESEARCH.md §Pattern 2):
  1. Compute target dimensions from pixel budget: sqrt(MaxPixels / aspect)
  2. Cap the long edge to MaxLongEdge
  3. Clamp to native dimensions (never upscale)

Returns an array: (width, height) as integers.

.PARAMETER NativeW
Native (physical pixel) width of the screenshot.

.PARAMETER NativeH
Native (physical pixel) height of the screenshot.

.PARAMETER MaxLongEdge
Maximum allowed length of the longest edge in pixels.
Default: 1568 (Claude 4.6 family limit).

.PARAMETER MaxPixels
Maximum allowed total pixel count.
Default: 1150000 (Claude 4.6 family limit, 1.15 MP).

.EXAMPLE
$w, $h = Compute-MaxApiFit 3840 2160
# Returns (1280, 720) for Claude 4.6 family default limits
#>
function Compute-MaxApiFit {
    param(
        [Parameter(Mandatory=$true)]
        [int]$NativeW,
        [Parameter(Mandatory=$true)]
        [int]$NativeH,
        [int]$MaxLongEdge = 1568,
        [int]$MaxPixels = 1150000
    )

    # aspect = NativeW / NativeH
    $aspect = [double]$NativeW / $NativeH

    # Compute target dimensions from pixel budget
    # h_from_pixels = sqrt(MaxPixels / aspect)
    # w_from_pixels = h_from_pixels * aspect
    $hFromPixels = [Math]::Sqrt($MaxPixels / $aspect)
    $wFromPixels = $hFromPixels * $aspect

    if ($NativeW -ge $NativeH) {
        # Landscape or square: cap width at MaxLongEdge
        $w = [Math]::Min($wFromPixels, $MaxLongEdge)
        $h = $w / $aspect
    }
    else {
        # Portrait: cap height at MaxLongEdge
        $h = [Math]::Min($hFromPixels, $MaxLongEdge)
        $w = $h * $aspect
    }

    # Clamp to native dimensions (never upscale)
    $w = [Math]::Min($w, $NativeW)
    $h = [Math]::Min($h, $NativeH)

    return @([int]$w, [int]$h)
}

<#
.SYNOPSIS
Reverse-maps a point from model-native display coordinates to physical screen pixels.

.DESCRIPTION
Uses simple proportional scaling:
  scale_x = ScreenW / DisplayW
  scale_y = ScreenH / DisplayH
  screen_x = int(ApiX * scale_x)
  screen_y = int(ApiY * scale_y)

Returns a hashtable: @{ x = screen_x; y = screen_y }

.PARAMETER ApiX
X coordinate in the display (downscaled) space.

.PARAMETER ApiY
Y coordinate in the display (downscaled) space.

.PARAMETER DisplayW
Width of the image that was sent to the API.

.PARAMETER DisplayH
Height of the image that was sent to the API.

.PARAMETER ScreenW
Actual physical screen width.

.PARAMETER ScreenH
Actual physical screen height.

.EXAMPLE
$point = ConvertFrom-ApiCoordinates 600 400 1280 720 3840 2160
# $point.x = 1800, $point.y = 1200
#>
function ConvertFrom-ApiCoordinates {
    param(
        [Parameter(Mandatory=$true)]
        [int]$ApiX,
        [Parameter(Mandatory=$true)]
        [int]$ApiY,
        [Parameter(Mandatory=$true)]
        [int]$DisplayW,
        [Parameter(Mandatory=$true)]
        [int]$DisplayH,
        [Parameter(Mandatory=$true)]
        [int]$ScreenW,
        [Parameter(Mandatory=$true)]
        [int]$ScreenH
    )

    $scaleX = [double]$ScreenW / $DisplayW
    $scaleY = [double]$ScreenH / $DisplayH
    $screenX = [int]($ApiX * $scaleX)
    $screenY = [int]($ApiY * $scaleY)

    return @{
        x = $screenX
        y = $screenY
    }
}

<#
.SYNOPSIS
Reverse-maps a full bounding box from display coordinates to physical screen pixels.

.DESCRIPTION
Maps all four corners of the bounding box to ensure correct scaling:
  1. Map top-left corner (ApiX, ApiY)
  2. Map bottom-right corner (ApiX + ApiW, ApiY + ApiH)
  3. Compute width = bottomRight.x - topLeft.x, height = bottomRight.y - topLeft.y

Returns a hashtable: @{ x = screen_x; y = screen_y; w = screen_w; h = screen_h }

.PARAMETER ApiX
X coordinate of the bounding box top-left in display space.

.PARAMETER ApiY
Y coordinate of the bounding box top-left in display space.

.PARAMETER ApiW
Width of the bounding box in display space.

.PARAMETER ApiH
Height of the bounding box in display space.

.PARAMETER DisplayW
Width of the image sent to the API.

.PARAMETER DisplayH
Height of the image sent to the API.

.PARAMETER ScreenW
Actual physical screen width.

.PARAMETER ScreenH
Actual physical screen height.

.EXAMPLE
$bbox = ConvertFrom-ApiBbox 100 100 200 150 1280 720 3840 2160
# $bbox.x = 300, $bbox.y = 300, $bbox.w = 600, $bbox.h = 450
#>
function ConvertFrom-ApiBbox {
    param(
        [Parameter(Mandatory=$true)]
        [int]$ApiX,
        [Parameter(Mandatory=$true)]
        [int]$ApiY,
        [Parameter(Mandatory=$true)]
        [int]$ApiW,
        [Parameter(Mandatory=$true)]
        [int]$ApiH,
        [Parameter(Mandatory=$true)]
        [int]$DisplayW,
        [Parameter(Mandatory=$true)]
        [int]$DisplayH,
        [Parameter(Mandatory=$true)]
        [int]$ScreenW,
        [Parameter(Mandatory=$true)]
        [int]$ScreenH
    )

    $topLeft = ConvertFrom-ApiCoordinates $ApiX $ApiY $DisplayW $DisplayH $ScreenW $ScreenH
    $botRight = ConvertFrom-ApiCoordinates ($ApiX + $ApiW) ($ApiY + $ApiH) $DisplayW $DisplayH $ScreenW $ScreenH

    return @{
        x = $topLeft.x
        y = $topLeft.y
        w = $botRight.x - $topLeft.x
        h = $botRight.y - $topLeft.y
    }
}
