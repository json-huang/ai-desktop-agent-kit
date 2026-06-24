# Requires Pester v5. Install: Install-Module -Name Pester -Force -SkipPublisherCheck
# Fusion Engine Unit Tests

# Dot-source dependencies (explicit paths for Pester v5 compatibility)
$fusionScriptPath = "C:\Users\DBA126\.claude\scripts"
. "$fusionScriptPath\perception-schema.ps1"
. "$fusionScriptPath\fusion.ps1"

Describe "Fusion Engine" {

    Context "Compute-IoU" {
        It "Returns 1.0 for identical bounding boxes" {
            $box1 = @{ x = 10; y = 20; w = 100; h = 50 }
            $box2 = @{ x = 10; y = 20; w = 100; h = 50 }
            $result = Compute-IoU $box1 $box2
            $result | Should -Be 1.0
        }

        It "Returns 0.0 for non-overlapping boxes" {
            $box1 = @{ x = 0; y = 0; w = 50; h = 50 }
            $box2 = @{ x = 100; y = 100; w = 50; h = 50 }
            $result = Compute-IoU $box1 $box2
            $result | Should -Be 0.0
        }

        It "Returns ~0.333 for partially overlapping boxes" {
            $box1 = @{ x = 0; y = 0; w = 100; h = 50 }
            $box2 = @{ x = 50; y = 0; w = 100; h = 50 }
            $result = Compute-IoU $box1 $box2
            $result | Should -BeGreaterThan 0.3
            $result | Should -BeLessThan 0.4
        }
    }

    Context "Merge-PerceptionTiers" {
        It "Preserves non-overlapping elements from different sources" {
            $uia = @(New-UiElement -Type "button" -X 10 -Y 10 -W 80 -H 30 -Confidence 0.99 -Text "File" -Source "uiAutomation" -State "enabled" -IsInteractive $true)
            $ocr = @(New-UiElement -Type "label" -X 200 -Y 10 -W 60 -H 20 -Confidence 0.85 -Text "Document" -Source "ocr")
            $merged = @(Merge-PerceptionTiers -UiaElements $uia -OcrElements $ocr)
            $merged.Count | Should -BeGreaterThan 2
            @($merged | Where-Object { $_.source -eq "uiAutomation" }).Count | Should -Be 1
            @($merged | Where-Object { $_.source -eq "ocr" }).Count | Should -Be 1
        }

        It "Deduplicates overlapping elements with matching text" {
            $uia = @(New-UiElement -Type "button" -X 10 -Y 20 -W 80 -H 30 -Confidence 0.99 -Text "File" -Source "uiAutomation")
            $ocr = @(New-UiElement -Type "label" -X 15 -Y 22 -W 70 -H 26 -Confidence 0.85 -Text "File" -Source "ocr")
            $merged = @(Merge-PerceptionTiers -UiaElements $uia -OcrElements $ocr)
            $fileElements = @($merged | Where-Object { $_.text -eq "File" })
            $fileElements.Count | Should -Be 1
            $fileElements[0].source | Should -Be "uiAutomation"
            $fileElements[0].alternatives.Count | Should -BeGreaterThan 0
        }

        It "Marks conflict for overlapping elements with different text" {
            $uia = @(New-UiElement -Type "button" -X 10 -Y 20 -W 80 -H 30 -Confidence 0.99 -Text "Save" -Source "uiAutomation")
            $ocr = @(New-UiElement -Type "label" -X 15 -Y 22 -W 70 -H 26 -Confidence 0.85 -Text "Save As" -Source "ocr")
            $merged = @(Merge-PerceptionTiers -UiaElements $uia -OcrElements $ocr)
            @($merged | Where-Object { $_.text -eq "Save" }).Count | Should -Be 1
            @($merged | Where-Object { $_.text -eq "Save As" }).Count | Should -Be 1
            $saveEl = $merged | Where-Object { $_.text -eq "Save" } | Select-Object -First 1
            $saveEl.alternatives.Count | Should -BeGreaterThan 0
        }

        It "Assigns parentIndex to non-UIA elements contained within UIA ancestors" {
            $uia = @(New-UiElement -Type "window" -X 0 -Y 0 -W 800 -H 600 -Confidence 0.99 -Source "uiAutomation" -ParentIndex -1)
            $ocr = @(New-UiElement -Type "label" -X 200 -Y 100 -W 100 -H 20 -Confidence 0.85 -Text "Hello" -Source "ocr")
            $merged = @(Merge-PerceptionTiers -UiaElements $uia -OcrElements $ocr)
            $ocrMerged = $merged | Where-Object { $_.source -eq "ocr" } | Select-Object -First 1
            $ocrMerged.parentIndex | Should -Not -Be -1
        }

        It "Handles empty input gracefully" {
            $merged = @(Merge-PerceptionTiers)
            $merged.Count | Should -Be 1
            $merged[0].type | Should -Be "desktop"
        }

        It "Output root element has type='desktop' and parentIndex=-1" {
            $merged = @(Merge-PerceptionTiers)
            $merged[0].type | Should -Be "desktop"
            $merged[0].parentIndex | Should -Be -1
        }

        It "Handles three tiers with mixed overlap and non-overlap" {
            $uia = @(New-UiElement -Type "button" -X 10 -Y 10 -W 80 -H 30 -Confidence 0.99 -Text "File" -Source "uiAutomation" -State "enabled" -IsInteractive $true)
            $ocr = @(New-UiElement -Type "label" -X 15 -Y 12 -W 70 -H 26 -Confidence 0.85 -Text "File" -Source "ocr")
            $tmpl = @(New-UiElement -Type "icon" -X 300 -Y 50 -W 40 -H 40 -Confidence 0.75 -Text "" -Source "templateMatch")
            $merged = @(Merge-PerceptionTiers -UiaElements $uia -OcrElements $ocr -TemplateElements $tmpl)
            $merged.Count | Should -Be 3
            $fileEl = @($merged | Where-Object { $_.text -eq "File" })
            $fileEl.Count | Should -Be 1
            $fileEl[0].alternatives.Count | Should -BeGreaterThan 0
            @($merged | Where-Object { $_.source -eq "templateMatch" }).Count | Should -Be 1
        }
    }
}
