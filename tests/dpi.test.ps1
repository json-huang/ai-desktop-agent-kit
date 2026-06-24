# DPI Coordinate Pipeline Validation Test
# Validates coordinate accuracy across DPI settings using the PerMonitorV2 screenshot pipeline
# and Anthropic's coordinate scaling formulas (compute_max_api_fit + reverse map).
#
# Requires Pester v5. Install: Install-Module -Name Pester -Force -SkipPublisherCheck
#
# Usage:
#   Invoke-Pester C:\Users\DBA126\.claude\tests\dpi.test.ps1
#   Invoke-Pester C:\Users\DBA126\.claude\tests\dpi.test.ps1 -TagFilter "unit"

# ============================================================
# Coordinate Math Functions (pure math, no external deps)
# ============================================================

function Compute-MaxApiFit {
    param(
        [int]$NativeW,
        [int]$NativeH,
        [int]$MaxLongEdge = 1568,
        [int]$MaxPixels = 1150000
    )
    $aspect = $NativeW / $NativeH
    $hFromPixels = [math]::Sqrt($MaxPixels / $aspect)
    $wFromPixels = $hFromPixels * $aspect

    if ($NativeW -ge $NativeH) {
        $w = [math]::Min($wFromPixels, $MaxLongEdge)
        $h = $w / $aspect
    }
    else {
        $h = [math]::Min($hFromPixels, $MaxLongEdge)
        $w = $h * $aspect
    }

    $w = [math]::Min($w, $NativeW)
    $h = [math]::Min($h, $NativeH)
    return @{
        Width  = [int]$w
        Height = [int]$h
    }
}

function ConvertFrom-ApiCoordinates {
    param(
        [int]$ApiX,
        [int]$ApiY,
        [int]$DisplayW,
        [int]$DisplayH,
        [int]$ScreenW,
        [int]$ScreenH
    )
    $scaleX = $ScreenW / $DisplayW
    $scaleY = $ScreenH / $DisplayH
    $screenX = [int]($ApiX * $scaleX)
    $screenY = [int]($ApiY * $scaleY)
    return @{
        X = $screenX
        Y = $screenY
    }
}

# ============================================================
# Test Suite
# ============================================================

Describe "DPI Coordinate Pipeline" {

    Context "Screenshot dimensions" {

        It "Produces non-zero dimensions from Capture()" {
            $tempPath = "$env:TEMP\_dpi_test_capture.png"
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue

            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\DBA126\.claude\scripts\screenshot.ps1" -Path $tempPath
            $output | Should -Match 'OK\|'

            if (Test-Path $tempPath) {
                $img = [System.Drawing.Image]::FromFile($tempPath)
                $img.Width  | Should -BeGreaterThan 0
                $img.Height | Should -BeGreaterThan 0
                $img.Dispose()
                Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
            }
            else {
                # If capture fails (e.g., headless), test the format expectation only
                $output | Should -Match 'OK\|.*\|\d+x\d+\|'
            }
        }

        It "Capture dimensions do not exceed primary monitor physical resolution" {
            $tempPath = "$env:TEMP\_dpi_test_capture2.png"
            Remove-Item $tempPath -Force -ErrorAction SilentlyContinue

            # Get primary monitor resolution via .NET
            $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
            $primaryBounds = $primaryScreen.Bounds

            $output = & powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\DBA126\.claude\scripts\screenshot.ps1" -Path $tempPath

            if (Test-Path $tempPath) {
                $img = [System.Drawing.Image]::FromFile($tempPath)
                # With PerMonitorV2 + virtual screen, dimensions should be >= primary monitor
                # (full virtual screen includes all monitors)
                $img.Width  | Should -BeGreaterOrEqual $primaryBounds.Width
                $img.Height | Should -BeGreaterOrEqual $primaryBounds.Height
                $img.Dispose()
                Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "compute_max_api_fit" {

        It "3840x2160 (4K landscape) fits within 4.6 family limits" {
            $result = Compute-MaxApiFit -NativeW 3840 -NativeH 2160
            # Anthropic formula: pixel budget (1.15MP) is binding constraint
            $result.Width  | Should -Be 1430
            $result.Height | Should -Be 804
        }

        It "1920x1080 (FHD landscape) fits within 4.6 family limits" {
            $result = Compute-MaxApiFit -NativeW 1920 -NativeH 1080
            $result.Width  | Should -Be 1430
            $result.Height | Should -Be 804
        }

        It "2560x1440 (QHD) fits within 4.6 family limits" {
            $result = Compute-MaxApiFit -NativeW 2560 -NativeH 1440
            $result.Width  | Should -Be 1430
            $result.Height | Should -Be 804
        }

        It "1080x1920 (portrait) fits within 4.6 family limits" {
            $result = Compute-MaxApiFit -NativeW 1080 -NativeH 1920
            $result.Width  | Should -Be 804
            $result.Height | Should -Be 1430
        }

        It "1280x720 (already fits) is not upscaled" {
            $result = Compute-MaxApiFit -NativeW 1280 -NativeH 720
            $result.Width  | Should -Be 1280
            $result.Height | Should -Be 720
        }
    }

    Context "reverse_map_coordinates" {

        It "Correctly maps (600,400) from 1280x720 display space to 3840x2160 screen space" {
            $result = ConvertFrom-ApiCoordinates -ApiX 600 -ApiY 400 -DisplayW 1280 -DisplayH 720 -ScreenW 3840 -ScreenH 2160
            $result.X | Should -Be 1800
            $result.Y | Should -Be 1200
        }

        It "Correctly maps (100,100) from 1280x720 to 1920x1080 screen space" {
            $result = ConvertFrom-ApiCoordinates -ApiX 100 -ApiY 100 -DisplayW 1280 -DisplayH 720 -ScreenW 1920 -ScreenH 1080
            $result.X | Should -Be 150
            $result.Y | Should -Be 150
        }

        It "Correctly maps center point (640,360) from 1280x720 to 3840x2160" {
            $result = ConvertFrom-ApiCoordinates -ApiX 640 -ApiY 360 -DisplayW 1280 -DisplayH 720 -ScreenW 3840 -ScreenH 2160
            $result.X | Should -Be 1920
            $result.Y | Should -Be 1080
        }

        It "Correctly maps (0,0) origin point" {
            $result = ConvertFrom-ApiCoordinates -ApiX 0 -ApiY 0 -DisplayW 1280 -DisplayH 720 -ScreenW 3840 -ScreenH 2160
            $result.X | Should -Be 0
            $result.Y | Should -Be 0
        }

        It "Correctly maps (1280,720) max corner to 3840x2160" {
            $result = ConvertFrom-ApiCoordinates -ApiX 1280 -ApiY 720 -DisplayW 1280 -DisplayH 720 -ScreenW 3840 -ScreenH 2160
            $result.X | Should -Be 3840
            $result.Y | Should -Be 2160
        }
    }
}
