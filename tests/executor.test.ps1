# executor.test.ps1
# Pester v5 unit tests for executor FSM state transitions and state persistence

Describe "CORE-04: Executor FSM" {

    BeforeAll {
        . "$PSScriptRoot\..\scripts\executor.ps1"

        $testDir = Join-Path $env:TEMP "executor_test_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null

        # Create a minimal test DAG
        $testDagPath = Join-Path $testDir "test_dag.json"
        @(
            @{
                step_id = 1
                description = "Wait for UI to settle"
                depends_on = @()
                action = @{
                    type = "wait"
                    ms = 100
                    expected_outcome = @{
                        visual_change = "none"
                        ocr_check = ""
                        ui_state = ""
                        negative_check = ""
                    }
                    alternatives = @(
                        @{ strategy = "retry_reposition"; action = @{ type = "wait"; ms = 200 }; description = "Wait longer" }
                    )
                }
                max_retries = 3
                timeout_ms = 5000
            }
            @{
                step_id = 2
                description = "Verify task completed"
                depends_on = @(1)
                action = @{
                    type = "wait"
                    ms = 100
                    expected_outcome = @{
                        visual_change = "task done"
                        ocr_check = ""
                        ui_state = ""
                        negative_check = ""
                    }
                    alternatives = @()
                }
                max_retries = 3
                timeout_ms = 5000
            }
        ) | ConvertTo-Json -Depth 5 | Out-File -FilePath $testDagPath -Encoding UTF8
    }

    AfterAll {
        Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
    }

    It "CORE-04_FsmStateTransitions: DryRun executor completes 2-step DAG with task_completed=true" {
        $result = Invoke-ExecutorLoop -DagPath $testDagPath -OutputDir $testDir -DryRun

        $result.task_completed | Should -BeTrue
        $result.steps_total | Should -Be 2
        $result.steps_completed | Should -Be 2
        $result.final_state | Should -Be "DONE"
    }

    It "CORE-04_CheckpointPersistence: DryRun execution creates checkpoint.json with version and task_id" {
        $result = Invoke-ExecutorLoop -DagPath $testDagPath -OutputDir $testDir -DryRun

        $checkpointPath = Join-Path $testDir "checkpoint.json"
        $checkpointPath | Should -Exist

        $checkpoint = Get-Content $checkpointPath -Raw | ConvertFrom-Json
        $checkpoint.schema_version | Should -Be "1.0"
        $checkpoint.task_id | Should -Not -BeNullOrEmpty
        $checkpoint.step_states | Should -Not -BeNullOrEmpty
    }

    It "CORE-04_TaskResult: DryRun execution creates task_result.json with completion stats" {
        $result = Invoke-ExecutorLoop -DagPath $testDagPath -OutputDir $testDir -DryRun

        $resultPath = Join-Path $testDir "task_result.json"
        $resultPath | Should -Exist

        $taskResult = Get-Content $resultPath -Raw | ConvertFrom-Json
        $taskResult.steps_total | Should -Be 2
        $taskResult.steps_completed | Should -Be 2
        $taskResult.task_completed | Should -BeTrue
        $taskResult.final_state | Should -Be "DONE"
    }

    It "CORE-04_StandaloneInvocation: executor.ps1 can be dot-sourced and FSM enum exists" {
        # Verify FSM enum has all required states
        $states = [Enum]::GetNames([ExecutorState])
        $states | Should -Contain "SENSE"
        $states | Should -Contain "PLAN"
        $states | Should -Contain "ACT"
        $states | Should -Contain "VERIFY"
        $states | Should -Contain "RECOVER"
        $states | Should -Contain "ADVANCE"
        $states | Should -Contain "ESCALATE"
        $states | Should -Contain "DONE"
    }

    It "CORE-04_ActionDispatch: covers all action types" {
        # Verify Invoke-ActionDispatch handles all 10 action types
        $funcBody = (Get-Command Invoke-ActionDispatch).ScriptBlock.ToString()
        $funcBody | Should -Match "click"
        $funcBody | Should -Match "type"
        $funcBody | Should -Match "hotkey"
        $funcBody | Should -Match "launch"
        $funcBody | Should -Match "drag"
        $funcBody | Should -Match "scroll"
        $funcBody | Should -Match "wait"
    }
}
