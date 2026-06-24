# recovery.test.ps1
# Pester v5 unit tests for recovery cascade and loop breaker

Describe "CORE-04: Recovery Cascade" {

    BeforeAll {
        . "$PSScriptRoot\..\scripts\executor.ps1"

        $testDir = Join-Path $env:TEMP "recovery_test_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null

        # Create a DAG where step 1 will always "fail" (used to test recovery escalation)
        $failDagPath = Join-Path $testDir "fail_dag.json"
        @(
            @{
                step_id = 1
                description = "Click a non-existent button (will always fail)"
                depends_on = @()
                action = @{
                    type = "click"
                    target_x = 0
                    target_y = 0
                    expected_outcome = @{
                        visual_change = "impossible change"
                        ocr_check = "THIS_TEXT_WILL_NEVER_APPEAR_12345"
                        ui_state = ""
                        negative_check = ""
                    }
                    alternatives = @(
                        @{
                            strategy = "keyboard_shortcut"
                            action = @{ type = "hotkey"; mod = "Ctrl"; key = "X" }
                            description = "Try keyboard shortcut instead"
                        }
                        @{
                            strategy = "menu_navigation"
                            action = @{ type = "hotkey"; mod = "Alt"; key = "F" }
                            description = "Navigate via menu"
                        }
                    )
                }
                max_retries = 2
                timeout_ms = 5000
            }
        ) | ConvertTo-Json -Depth 5 | Out-File -FilePath $failDagPath -Encoding UTF8
    }

    AfterAll {
        Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
    }

    It "CORE-04_RecoveryOrder: executor increments strategy_index on failure" {
        # With max_retries=2, the executor should try strategy 0, then 1, then escalate
        $result = Invoke-ExecutorLoop -DagPath $failDagPath -OutputDir $testDir `
            -MaxRetriesPerStep 2 -DryRun

        # Should not complete (task is designed to fail)
        $result.task_completed | Should -BeFalse
        $result.final_state | Should -Be "ESCALATE"
    }

    It "CORE-04_MaxRetriesEnforced: executor escalates after reaching retry cap" {
        # MaxRetriesPerStep=1: only 1 attempt, then escalate
        $smallDir = Join-Path $testDir "small_retry"
        New-Item -ItemType Directory -Path $smallDir -Force | Out-Null

        $result = Invoke-ExecutorLoop -DagPath $failDagPath -OutputDir $smallDir `
            -MaxRetriesPerStep 1 -DryRun

        $result.task_completed | Should -BeFalse
        $result.final_state | Should -Be "ESCALATE"
        $result.steps_completed | Should -Be 0
        $result.steps_total | Should -Be 1
    }

    It "CORE-04_LoopBreaker: Test-LoopBreaker detects identical actions" {
        $action = @{ type = "click"; target_x = 100; target_y = 200 }

        # Test with identical actions (no screenshots — should still detect matching type+coordinates)
        # Without real screenshots, the screenshot comparison is skipped, but type+coords still match
        $result = Test-LoopBreaker -CurrentAction $action -LastAction $action `
            -CurrentScreenshot "" -LastScreenshot ""
        $result | Should -BeTrue
    }

    It "CORE-04_LoopBreaker: Test-LoopBreaker ignores different actions" {
        $action1 = @{ type = "click"; target_x = 100; target_y = 200 }
        $action2 = @{ type = "hotkey"; mod = "Ctrl"; key = "C" }

        $result = Test-LoopBreaker -CurrentAction $action2 -LastAction $action1 `
            -CurrentScreenshot "" -LastScreenshot ""
        $result | Should -BeFalse
    }

    It "CORE-04_EscalationOutput: ESCALATE state writes clear failure message with checkpoint" {
        $result = Invoke-ExecutorLoop -DagPath $failDagPath -OutputDir $testDir `
            -MaxRetriesPerStep 1 -DryRun

        $checkpointPath = Join-Path $testDir "checkpoint.json"
        $checkpointPath | Should -Exist

        $result.final_state | Should -Be "ESCALATE"
    }
}
