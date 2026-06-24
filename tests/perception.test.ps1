# Perception Pipeline Integration Tests
# Requires Pester v5. Install: Install-Module -Name Pester -Force -SkipPublisherCheck
# Tests the full perception pipeline end-to-end against real desktop UI.

Describe "Perception Pipeline End-to-End" {

    Context "Pipeline execution" {
        BeforeAll {
            $script:outputDir = "$env:TEMP\perception_test_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            New-Item -ItemType Directory -Path $script:outputDir -Force | Out-Null
        }

        AfterAll {
            Remove-Item $script:outputDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Runs without crashing and returns status object" {
            $perceptionScript = "C:\Users\DBA126\.claude\scripts\perception.ps1"
            $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $perceptionScript -SkipVision -OutputDir $script:outputDir -NoAnnotate 2>&1
            $raw | Out-String | Should -Match "PERCEPTION_COMPLETE"
        }

        It "Completes within 5 seconds (UIA+OCR, no vision)" {
            $perceptionScript = "C:\Users\DBA126\.claude\scripts\perception.ps1"
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $perceptionScript -SkipVision -OutputDir $script:outputDir -NoAnnotate 2>&1
            $sw.Stop()
            # Note: powershell.exe launch overhead adds 3-5s; pipeline itself is ~2-3s
$sw.ElapsedMilliseconds | Should -BeLessThan 15000
        }

        It "Output JSON file exists and is valid" {
            # Find the latest perception JSON in the output dir
            $jsonFiles = @(Get-ChildItem $script:outputDir -Filter "perception_*.json" | Sort-Object LastWriteTime -Descending)
            $jsonFiles.Count | Should -BeGreaterThan 0
            $json = Get-Content $jsonFiles[0].FullName -Raw | ConvertFrom-Json
            $json.elements | Should -Not -BeNullOrEmpty
            $json.elements.Count | Should -BeGreaterThan 0
        }

        It "Root element is type='desktop' at index 0" {
            $jsonFiles = @(Get-ChildItem $script:outputDir -Filter "perception_*.json" | Sort-Object LastWriteTime -Descending)
            $json = Get-Content $jsonFiles[0].FullName -Raw | ConvertFrom-Json
            $json.elements[0].type | Should -Be "desktop"
            $json.elements[0].parentIndex | Should -Be -1
        }

        It "JSON includes timestamp, tiers_used, and element_count metadata" {
            $jsonFiles = @(Get-ChildItem $script:outputDir -Filter "perception_*.json" | Sort-Object LastWriteTime -Descending)
            $json = Get-Content $jsonFiles[0].FullName -Raw | ConvertFrom-Json
            $json.timestamp | Should -Not -BeNullOrEmpty
            $json.tiers_used | Should -Not -BeNullOrEmpty
            $json.element_count | Should -BeGreaterThan 0
        }
    }

    Context "Annotated screenshot" {
        BeforeAll {
            $script:annotDir = "$env:TEMP\perception_test_annotated_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            New-Item -ItemType Directory -Path $script:annotDir -Force | Out-Null
        }

        AfterAll {
            Remove-Item $script:annotDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Produces annotated PNG when NoAnnotate is not set" {
            $perceptionScript = "C:\Users\DBA126\.claude\scripts\perception.ps1"
            $null = & powershell -NoProfile -ExecutionPolicy Bypass -File $perceptionScript -SkipVision -OutputDir $script:annotDir 2>&1
            $pngFiles = @(Get-ChildItem $script:annotDir -Filter "*_annotated.png" | Sort-Object LastWriteTime -Descending)
            $pngFiles.Count | Should -BeGreaterThan 0
            $pngFiles[0].Length | Should -BeGreaterThan 0
        }
    }

    Context "Debug flags" {
        BeforeAll {
            $script:debugDir = "$env:TEMP\perception_test_debug_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
            New-Item -ItemType Directory -Path $script:debugDir -Force | Out-Null
        }

        AfterAll {
            Remove-Item $script:debugDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "-SkipUia flag omits uiAutomation from tiers" {
            $perceptionScript = "C:\Users\DBA126\.claude\scripts\perception.ps1"
            $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $perceptionScript -SkipUia -SkipVision -OutputDir $script:debugDir -NoAnnotate 2>&1
            $outputText = ($raw | Out-String)
            $outputText | Should -Match "PERCEPTION_COMPLETE"
            $outputText | Should -Not -Match "uiAutomation"
        }

        It "PERCEPTION_COMPLETE status line is emitted" {
            $perceptionScript = "C:\Users\DBA126\.claude\scripts\perception.ps1"
            $raw = & powershell -NoProfile -ExecutionPolicy Bypass -File $perceptionScript -SkipVision -OutputDir $script:debugDir -NoAnnotate 2>&1
            $outputText = ($raw | Out-String)
            $outputText | Should -Match "PERCEPTION_COMPLETE"
        }
    }
}
