# e2e-single-app.test.ps1
# Pester v5 E2E integration tests for CORE-07: single-application task completion
# Tests DAG structure validity for common tasks + executor DryRun processing

Describe "CORE-07: End-to-End Single-Application Task Completion" {

    BeforeAll {
        . "$PSScriptRoot\..\scripts\executor.ps1"

        $testDir = Join-Path $env:TEMP "e2e_test_$(Get-Random)"
        New-Item -ItemType Directory -Path $testDir -Force | Out-Null

        # ---- Build Notepad E2E DAG ----
        $notepadDag = @(
            @{
                step_id = 1
                description = "Launch Notepad application"
                depends_on = @()
                action = @{
                    type = "launch"
                    command = "notepad.exe"
                    expected_outcome = @{
                        visual_change = "Notepad window appears"
                        ocr_check = "Untitled, Notepad"
                        ui_state = "Notepad window IsEnabled=true"
                        negative_check = "Error, Failed"
                    }
                    alternatives = @(
                        @{
                            strategy = "shell"
                            action = @{ type = "shell"; command = "start notepad.exe" }
                            description = "Launch via Start menu command"
                        }
                    )
                }
                max_retries = 3
                timeout_ms = 15000
            }
            @{
                step_id = 2
                description = "Wait for Notepad window to open and gain focus"
                depends_on = @(1)
                action = @{
                    type = "wait"
                    ms = 2000
                    expected_outcome = @{
                        visual_change = "Notepad window is foreground"
                        ocr_check = "Notepad"
                        ui_state = "Notepad window IsKeyboardFocused=true"
                        negative_check = "Error, not responding"
                    }
                    alternatives = @(
                        @{
                            strategy = "retry_reposition"
                            action = @{ type = "wait"; ms = 5000 }
                            description = "Wait longer for slow launch"
                        }
                    )
                }
                max_retries = 3
                timeout_ms = 20000
            }
            @{
                step_id = 3
                description = "Type 'Hello World' into the Notepad text area"
                depends_on = @(2)
                action = @{
                    type = "type"
                    text = "Hello World"
                    expected_outcome = @{
                        visual_change = "Text appears in editor"
                        ocr_check = "Hello World"
                        ui_state = "Edit control contains text"
                        negative_check = "Error, access denied"
                    }
                    alternatives = @(
                        @{
                            strategy = "keyboard_shortcut"
                            action = @{ type = "hotkey"; mod = "Ctrl"; key = "V" }
                            description = "Paste from clipboard (if text was copied first)"
                        }
                    )
                }
                max_retries = 3
                timeout_ms = 10000
            }
            @{
                step_id = 4
                description = "Save the file via Ctrl+S hotkey"
                depends_on = @(3)
                action = @{
                    type = "hotkey"
                    mod = "Ctrl"
                    key = "S"
                    expected_outcome = @{
                        visual_change = "Save As dialog appears"
                        ocr_check = "Save As, File name"
                        ui_state = "Save dialog IsEnabled=true"
                        negative_check = "Error, access denied, cannot save"
                    }
                    alternatives = @(
                        @{
                            strategy = "menu_navigation"
                            action = @{ type = "hotkey"; mod = "Alt"; key = "F" }
                            description = "Open File menu, then navigate to Save"
                        }
                    )
                }
                max_retries = 3
                timeout_ms = 15000
            }
            @{
                step_id = 5
                description = "Type the save filename and confirm"
                depends_on = @(4)
                action = @{
                    type = "type"
                    text = "$env:USERPROFILE\Desktop\e2e_test_output.txt"
                    expected_outcome = @{
                        visual_change = "Filename appears in save dialog"
                        ocr_check = "e2e_test_output"
                        ui_state = "Save button IsEnabled=true"
                        negative_check = "Error, file already exists"
                    }
                    alternatives = @(
                        @{
                            strategy = "keyboard_shortcut"
                            action = @{ type = "hotkey"; mod = "Alt"; key = "S" }
                            description = "Alt+S to press Save button"
                        }
                    )
                }
                max_retries = 3
                timeout_ms = 10000
            }
            @{
                step_id = 6
                description = "Confirm save via Enter key"
                depends_on = @(5)
                action = @{
                    type = "hotkey"
                    mod = ""
                    key = "Enter"
                    expected_outcome = @{
                        visual_change = "Save dialog closes, Notepad title updates"
                        ocr_check = "e2e_test_output"
                        ui_state = "Notepad window title contains filename"
                        negative_check = "Error, failed to save"
                    }
                    alternatives = @(
                        @{
                            strategy = "retry_reposition"
                            action = @{ type = "click" }
                            description = "Click the Save button directly"
                        }
                    )
                }
                max_retries = 3
                timeout_ms = 10000
            }
            @{
                step_id = 7
                description = "Close Notepad"
                depends_on = @(6)
                action = @{
                    type = "hotkey"
                    mod = "Alt"
                    key = "F4"
                    expected_outcome = @{
                        visual_change = "Notepad window closes"
                        ocr_check = ""
                        ui_state = "Notepad window IsOffscreen=true"
                        negative_check = "Error, not responding"
                    }
                    alternatives = @(
                        @{
                            strategy = "shell"
                            action = @{ type = "shell"; command = "taskkill /IM notepad.exe /F" }
                            description = "Force-close Notepad via taskkill"
                        }
                    )
                }
                max_retries = 3
                timeout_ms = 10000
            }
        )

        $notepadDagPath = Join-Path $testDir "notepad_dag.json"
        $notepadDag | ConvertTo-Json -Depth 5 | Out-File -FilePath $notepadDagPath -Encoding UTF8

        # ---- Build Paint E2E DAG ----
        $paintDag = @(
            @{
                step_id = 1
                description = "Launch Microsoft Paint"
                depends_on = @()
                action = @{
                    type = "launch"
                    command = "mspaint.exe"
                    expected_outcome = @{
                        visual_change = "Paint window appears"
                        ocr_check = "Paint, Untitled"
                        ui_state = "Paint window IsEnabled=true"
                        negative_check = "Error, Failed"
                    }
                    alternatives = @(
                        @{
                            strategy = "shell"
                            action = @{ type = "shell"; command = "start mspaint.exe" }
                            description = "Launch via shell"
                        }
                    )
                }
                max_retries = 3
                timeout_ms = 15000
            }
            @{
                step_id = 2
                description = "Wait for Paint to open"
                depends_on = @(1)
                action = @{
                    type = "wait"
                    ms = 2000
                    expected_outcome = @{
                        visual_change = "Paint is foreground"
                        ocr_check = "Paint"
                        ui_state = "Paint window IsKeyboardFocused=true"
                        negative_check = "Error"
                    }
                    alternatives = @(
                        @{ strategy = "retry_reposition"; action = @{ type = "wait"; ms = 5000 }; description = "Wait longer" }
                    )
                }
                max_retries = 3
                timeout_ms = 20000
            }
            @{
                step_id = 3
                description = "Select Rectangle tool from toolbar"
                depends_on = @(2)
                action = @{
                    type = "click"
                    target = @{
                        description = "Rectangle shape tool in Paint toolbar"
                        element_type = "button"
                        text_hint = "Rectangle"
                        position_hint = "toolbar area at top of Paint window"
                    }
                    expected_outcome = @{
                        visual_change = "Rectangle tool becomes selected"
                        ocr_check = "Rectangle"
                        ui_state = "Rectangle tool IsSelected=true"
                        negative_check = ""
                    }
                    alternatives = @(
                        @{
                            strategy = "keyboard_shortcut"
                            action = @{ type = "hotkey"; mod = "Alt"; key = "H" }
                            description = "Alt+H for Home tab, then navigate to Shapes"
                        }
                    )
                }
                max_retries = 3
                timeout_ms = 10000
            }
            @{
                step_id = 4
                description = "Draw rectangle on canvas via drag"
                depends_on = @(3)
                action = @{
                    type = "drag"
                    target = @{ description = "Canvas center area"; position_hint = "center of Paint canvas" }
                    drag_target = @{ description = "Bottom-right of canvas"; position_hint = "lower-right of canvas" }
                    expected_outcome = @{
                        visual_change = "Rectangle shape appears on canvas"
                        ocr_check = ""
                        ui_state = ""
                        negative_check = "Error"
                    }
                    alternatives = @(
                        @{
                            strategy = "keyboard_shortcut"
                            action = @{ type = "hotkey"; mod = "Ctrl"; key = "E" }
                            description = "Alternative: use keyboard to draw (if supported)"
                        }
                    )
                }
                max_retries = 3
                timeout_ms = 10000
            }
            @{
                step_id = 5
                description = "Save as PNG via Ctrl+S"
                depends_on = @(4)
                action = @{
                    type = "hotkey"
                    mod = "Ctrl"
                    key = "S"
                    expected_outcome = @{
                        visual_change = "Save As dialog appears"
                        ocr_check = "Save as, File name, PNG"
                        ui_state = "Save dialog IsEnabled=true"
                        negative_check = "Error"
                    }
                    alternatives = @(
                        @{
                            strategy = "menu_navigation"
                            action = @{ type = "hotkey"; mod = "Alt"; key = "F" }
                            description = "File menu -> Save as"
                        }
                    )
                }
                max_retries = 3
                timeout_ms = 15000
            }
            @{
                step_id = 6
                description = "Type filename and select PNG format, then save"
                depends_on = @(5)
                action = @{
                    type = "type"
                    text = "$env:USERPROFILE\Desktop\e2e_rectangle.png"
                    expected_outcome = @{
                        visual_change = "Filename entered, Save button enabled"
                        ocr_check = "e2e_rectangle"
                        ui_state = "Save button IsEnabled=true"
                        negative_check = "Error"
                    }
                    alternatives = @(
                        @{ strategy = "keyboard_shortcut"; action = @{ type = "hotkey"; mod = "Alt"; key = "S" }; description = "Alt+S for Save" }
                    )
                }
                max_retries = 3
                timeout_ms = 10000
            }
            @{
                step_id = 7
                description = "Close Paint"
                depends_on = @(6)
                action = @{
                    type = "hotkey"
                    mod = "Alt"
                    key = "F4"
                    expected_outcome = @{
                        visual_change = "Paint window closes"
                        ocr_check = ""
                        ui_state = ""
                        negative_check = "Error, not responding"
                    }
                    alternatives = @(
                        @{ strategy = "shell"; action = @{ type = "shell"; command = "taskkill /IM mspaint.exe /F" }; description = "Force close" }
                    )
                }
                max_retries = 3
                timeout_ms = 10000
            }
        )

        $paintDagPath = Join-Path $testDir "paint_dag.json"
        $paintDag | ConvertTo-Json -Depth 5 | Out-File -FilePath $paintDagPath -Encoding UTF8

        # ---- Build Impossible DAG (Graceful Failure test) ----
        $impossibleDag = @(
            @{
                step_id = 1
                description = "Click a button that does not exist"
                depends_on = @()
                action = @{
                    type = "click"
                    target = @{
                        description = "Frobnicate button (does not exist in any application)"
                        element_type = "button"
                        text_hint = "Frobnicate"
                        position_hint = "nowhere"
                    }
                    expected_outcome = @{
                        visual_change = "Nothing should happen"
                        ocr_check = "FROBNICATE_SUCCESS_IMPOSSIBLE_12345"
                        ui_state = ""
                        negative_check = ""
                    }
                    alternatives = @(
                        @{ strategy = "keyboard_shortcut"; action = @{ type = "hotkey"; mod = "Ctrl"; key = "Shift"; extra = "F" }; description = "Try keyboard (will also fail)" }
                        @{ strategy = "menu_navigation"; action = @{ type = "hotkey"; mod = "Alt"; key = "X" }; description = "Try menu (will also fail)" }
                    )
                }
                max_retries = 2
                timeout_ms = 5000
            }
        )

        $impossibleDagPath = Join-Path $testDir "impossible_dag.json"
        $impossibleDag | ConvertTo-Json -Depth 5 | Out-File -FilePath $impossibleDagPath -Encoding UTF8
    }

    AfterAll {
        Remove-Item -Recurse -Force $testDir -ErrorAction SilentlyContinue
    }

    It "CORE-07_NotepadE2E: DryRun executor processes 7-step Notepad DAG successfully" {
        $result = Invoke-ExecutorLoop -DagPath $notepadDagPath -OutputDir $testDir -DryRun

        $result.task_completed | Should -BeTrue
        $result.steps_total | Should -Be 7
        $result.steps_completed | Should -Be 7
        $result.final_state | Should -Be "DONE"
    }

    It "CORE-07_PaintE2E: DryRun executor processes 7-step Paint DAG successfully" {
        $result = Invoke-ExecutorLoop -DagPath $paintDagPath -OutputDir $testDir -DryRun

        $result.task_completed | Should -BeTrue
        $result.steps_total | Should -Be 7
        $result.steps_completed | Should -Be 7
        $result.final_state | Should -Be "DONE"
    }

    It "CORE-07_GracefulFailure: DryRun executor escalates on impossible task without looping" {
        $failDir = Join-Path $testDir "graceful_failure"
        New-Item -ItemType Directory -Path $failDir -Force | Out-Null

        $result = Invoke-ExecutorLoop -DagPath $impossibleDagPath -OutputDir $failDir `
            -MaxRetriesPerStep 2 -DryRun

        # Should NOT complete — task is designed to fail
        $result.task_completed | Should -BeFalse
        $result.final_state | Should -Be "ESCALATE"
        $result.steps_total | Should -Be 1
        $result.steps_completed | Should -Be 0

        # Should produce failure report
        $failureReportPath = Join-Path $failDir "failure_report.json"
        $failureReportPath | Should -Exist

        $failureReport = Get-Content $failureReportPath -Raw | ConvertFrom-Json
        $failureReport.failed_step | Should -Be 1
        $failureReport.strategies_tried | Should -BeGreaterThan 0
        $failureReport.suggested_action | Should -Not -BeNullOrEmpty

        # Should produce checkpoint
        $checkpointPath = Join-Path $failDir "checkpoint.json"
        $checkpointPath | Should -Exist
    }

    It "CORE-07_DagStructureValidation: Notepad DAG has correct dependency chain" {
        $dag = Get-Content $notepadDagPath -Raw | ConvertFrom-Json

        # All step_ids should be sequential 1-7
        $stepIds = $dag | ForEach-Object { $_.step_id }
        ($stepIds -join ',') | Should -Be "1,2,3,4,5,6,7"

        # Step 1 has no dependencies
        $dag[0].depends_on.Count | Should -Be 0

        # Step 2 depends on step 1
        $dag[1].depends_on | Should -Contain 1

        # Each step has action.type
        $actionTypes = $dag | ForEach-Object { $_.action.type }
        ($actionTypes -join ',') | Should -Match "launch"
        ($actionTypes -join ',') | Should -Match "type"
        ($actionTypes -join ',') | Should -Match "hotkey"

        # Each step has alternatives
        $dag | ForEach-Object { $_.action.alternatives.Count } | Should -Not -Contain 0
    }

    It "CORE-07_PaintDagStructureValidation: Paint DAG has correct action types" {
        $dag = Get-Content $paintDagPath -Raw | ConvertFrom-Json

        $actionTypes = $dag | ForEach-Object { $_.action.type }
        ($actionTypes -join ',') | Should -Match "launch"
        ($actionTypes -join ',') | Should -Match "click"
        ($actionTypes -join ',') | Should -Match "drag"
        ($actionTypes -join ',') | Should -Match "hotkey"
        ($actionTypes -join ',') | Should -Match "type"
    }
}
