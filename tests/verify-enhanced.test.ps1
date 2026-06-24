# verify-enhanced.test.ps1
# Pester v5 unit tests for Invoke-StepVerification multi-modal verification
# Tests: SUCCESS, FAILURE (negative check), UNCERTAIN, and diagnostic output

Describe "CORE-03: Multi-Modal Step Verification" {

    BeforeAll {
        # Dot-source the enhanced verify.ps1 to load Invoke-StepVerification
        . "$PSScriptRoot\..\scripts\verify.ps1"

        # Temp directory for test fixtures
        $script:testDir = Join-Path $env:TEMP "verify_test_$(Get-Random)"
        New-Item -ItemType Directory -Path $script:testDir -Force | Out-Null

        # Create dummy screenshot files (10x10 pixel PNGs suffice for mocked tests)
        $bmp = New-Object System.Drawing.Bitmap(10, 10)
        $script:beforePath = Join-Path $script:testDir "before.png"
        $script:afterPath = Join-Path $script:testDir "after.png"
        $bmp.Save($script:beforePath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Save($script:afterPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }

    AfterAll {
        Remove-Item -Recurse -Force $script:testDir -ErrorAction SilentlyContinue
    }

    It "CORE-03_SuccessDetection: returns SUCCESS when OCR finds expected text and pixel diff > 2%" {
        # Mock screenshot capture to return our dummy afterPath
        Mock -CommandName "_InvokeScreenshot" -MockWith { return "OK|$script:afterPath|10x10|1" } -Verifiable

        # Mock OCR to return expected text
        Mock -CommandName "_InvokeOcr" -MockWith {
            return "LINE|New|0,0|10x10`nLINE|Open|10,10|10x10`nLINE|Save|20,20|10x10"
        }

        # Mock pixel diff to show 15% change (clearly > 2%)
        Mock -CommandName "_InvokePixelDiff" -MockWith {
            $result = New-Object PSObject
            $result | Add-Member -NotePropertyName "ChangePercent" -NotePropertyValue 15.0
            return $result
        }

        # Mock UIA to find expected state
        Mock -CommandName "_InvokeUia" -MockWith { return "ELEMENT|ControlType.Button|File|0,0,100,30|Enabled=True|Confidence=0.99`nIsEnabled=true IsSelected=true" }

        # Mock window list (no error dialogs)
        Mock -CommandName "_InvokeWindow" -MockWith { return "" }

        $expected = @{
            visual_change = "dropdown menu appears"
            ocr_check = "New, Open, Save"
            ui_state = "menu item IsSelected=true"
            negative_check = "no error dialog"
        }

        $result = Invoke-StepVerification -BeforeScreenshot $script:beforePath -ExpectedOutcome $expected -OutputDir $script:testDir
        $result | Should -Be "SUCCESS"
    }

    It "CORE-03_ErrorDetection: returns FAILURE when error text found via OCR (negative check)" {
        Mock -CommandName "_InvokeScreenshot" -MockWith { return "OK|$script:afterPath|10x10|1" }
        Mock -CommandName "_InvokeOcr" -MockWith {
            return "LINE|Error|0,0|10x10`nLINE|Failed|10,10|10x10"
        }
        Mock -CommandName "_InvokePixelDiff" -MockWith {
            $result = New-Object PSObject
            $result | Add-Member -NotePropertyName "ChangePercent" -NotePropertyValue 30.0
            return $result
        }
        Mock -CommandName "_InvokeUia" -MockWith { return "" }
        Mock -CommandName "_InvokeWindow" -MockWith { return "" }

        $expected = @{
            visual_change = "some change"
            ocr_check = ""
            ui_state = ""
            negative_check = "check for errors"
        }

        $result = Invoke-StepVerification -BeforeScreenshot $script:beforePath -ExpectedOutcome $expected -OutputDir $script:testDir
        $result | Should -Be "FAILURE"
    }

    It "CORE-03_UncertainDetection: returns UNCERTAIN when OCR partial match and pixel diff ambiguous" {
        Mock -CommandName "_InvokeScreenshot" -MockWith { return "OK|$script:afterPath|10x10|1" }
        # Only 1 of 3 expected texts found
        Mock -CommandName "_InvokeOcr" -MockWith {
            return "LINE|New|0,0|10x10"
        }
        # Low pixel diff (3% -- ambiguous)
        Mock -CommandName "_InvokePixelDiff" -MockWith {
            $result = New-Object PSObject
            $result | Add-Member -NotePropertyName "ChangePercent" -NotePropertyValue 3.0
            return $result
        }
        Mock -CommandName "_InvokeUia" -MockWith { return "" }
        Mock -CommandName "_InvokeWindow" -MockWith { return "" }

        $expected = @{
            visual_change = "subtle change"
            ocr_check = "New, Open, Save"
            ui_state = ""
            negative_check = ""
        }

        $result = Invoke-StepVerification -BeforeScreenshot $script:beforePath -ExpectedOutcome $expected -OutputDir $script:testDir
        $result | Should -Be "UNCERTAIN"
    }

    It "CORE-03_diagnostic: outputs VERIFY|scores| line with component scores" {
        Mock -CommandName "_InvokeScreenshot" -MockWith { return "OK|$script:afterPath|10x10|1" }
        Mock -CommandName "_InvokeOcr" -MockWith {
            return "LINE|New|0,0|10x10`nLINE|Open|10,10|10x10"
        }
        Mock -CommandName "_InvokePixelDiff" -MockWith {
            $result = New-Object PSObject
            $result | Add-Member -NotePropertyName "ChangePercent" -NotePropertyValue 8.0
            return $result
        }
        Mock -CommandName "_InvokeUia" -MockWith { return "" }
        Mock -CommandName "_InvokeWindow" -MockWith { return "" }

        $expected = @{
            visual_change = "change"
            ocr_check = "New, Open"
            ui_state = ""
            negative_check = ""
        }

        $output = & { Invoke-StepVerification -BeforeScreenshot $script:beforePath -ExpectedOutcome $expected -OutputDir $script:testDir } 6>&1
        $outputString = ($output | Out-String).Trim()
        $outputString | Should -Match "VERIFY\|scores\|diff=[\d.]+\|ocr=[\d.]+\|uia=[\d.]+\|neg=(true|false)\|total=[\d.]+"
    }
}
