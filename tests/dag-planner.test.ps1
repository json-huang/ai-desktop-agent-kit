# dag-planner.test.ps1
# Pester v5 unit tests for DAG planner prompt template quality

Describe "CORE-02: DAG Task Decomposition (Prompt Quality)" {

    BeforeAll {
        # Dot-source the planner
        . "$PSScriptRoot\..\scripts\planner.ps1"

        $testGoal = "open Notepad and type Hello World"
        $result = Invoke-TaskDecomposition -Goal $testGoal -ApplicationHint "Notepad"
        $promptContent = Get-Content $result.PromptFile -Raw
    }

    It "CORE-02_DagSchemaValid: prompt contains all required DAG step schema fields" {
        # Core step identification
        $promptContent | Should -Match "step_id"
        $promptContent | Should -Match "description"
        $promptContent | Should -Match "depends_on"

        # Action type enum
        $promptContent | Should -Match "action\.type"
        $promptContent | Should -Match "click"

        # Target element fields (descriptions, not coordinates)
        $promptContent | Should -Match "element_type"
        $promptContent | Should -Match "text_hint"
        $promptContent | Should -Match "position_hint"

        # Expected outcome fields
        $promptContent | Should -Match "expected_outcome"
        $promptContent | Should -Match "visual_change"
        $promptContent | Should -Match "ocr_check"
        $promptContent | Should -Match "ui_state"
        $promptContent | Should -Match "negative_check"

        # Alternatives
        $promptContent | Should -Match "alternatives"
        $promptContent | Should -Match "strategy"

        # Retry/timeout caps
        $promptContent | Should -Match "max_retries"
        $promptContent | Should -Match "timeout_ms"
    }

    It "CORE-02_DagDependenciesValid: prompt requires topological ordering and valid dependency references" {
        # Check that the prompt explains dependency ordering
        $promptContent | Should -Match "topologically ordered"
        # Check that it requires referenced step_ids to exist (implicit in "depends_on: array of step_ids")
        $dependsOnSection = $promptContent -split "`n" | Select-String -Pattern "depends_on" | ForEach-Object { $_.Line }
        $dependsOnSection -join "`n" | Should -Match "step_id"
    }

    It "CORE-02_KnownTaskDag: prompt for Notepad task mentions application-specific operations" {
        $promptContent | Should -Match "Notepad"
        # The prompt should guide Claude to plan a task with multiple steps
        $promptContent | Should -Match "step"
    }

    It "CORE-02_AntiStaleCoordinate: prompt forbids hardcoded screen coordinates" {
        # Case-insensitive check for the anti-coordinate rule
        $promptContent -replace '\s+', ' ' | Should -Match "NEVER include hardcoded screen coordinates"
        $promptContent -replace '\s+', ' ' | Should -Match "element descriptions only"
    }

    It "CORE-02_PlannerOutput: Invoke-TaskDecomposition returns valid result object" {
        $result.PSObject.Properties.Name | Should -Contain "PromptFile"
        $result.PSObject.Properties.Name | Should -Contain "Goal"
        $result.PSObject.Properties.Name | Should -Contain "Timestamp"

        $result.Goal | Should -Be $testGoal
        $result.PromptFile | Should -Exist

        # Prompt file should contain the user goal
        $promptContent | Should -Match "USER GOAL:.*open Notepad and type Hello World"
    }
}
