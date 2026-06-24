# planner.ps1 — Task DAG Decomposition Orchestrator
# Converts natural language goals into JSON execution DAGs.
# Delegates intelligence to Claude via MCP; owns prompt template and output formatting.
#
# Usage (dot-sourced):
#   . .\planner.ps1
#   $result = Invoke-TaskDecomposition -Goal "open Notepad and type Hello World"
#   # $result.PromptFile contains the planning prompt for Claude
#
# Usage (standalone):
#   .\planner.ps1 -Goal "open Notepad and type Hello World"

param(
    [string]$Goal = "",

    [string]$ScreenshotPath = "",

    [string]$ApplicationHint = ""
)

function Invoke-TaskDecomposition {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Goal,

        [string]$ScreenshotPath = "",

        [string]$ApplicationHint = ""
    )

    # 1. Get current screen perception context (if screenshot available)
    $perceptionSummary = "No screen data available."
    $perceptionJsonPath = ""

    if ($ScreenshotPath -and (Test-Path $ScreenshotPath)) {
        try {
            # Attempt to run perception pipeline for current screen state
            $perceptionResult = & "$PSScriptRoot\perception.ps1" -OutputDir "$env:TEMP" -NoAnnotate -SkipVision 2>&1
            # perception.ps1 outputs: JSON status string, then PSCustomObject status
            # Parse the JSON status string to get JsonPath
            if ($perceptionResult -is [array]) {
                $statusLine = $perceptionResult | Where-Object { $_ -match '^\s*\{.*\}\s*$' } | Select-Object -First 1
            } else {
                $statusLine = $perceptionResult
            }
            if ($statusLine) {
                $statusObj = $statusLine | ConvertFrom-Json
                $perceptionJsonPath = $statusObj.JsonPath
                if ($perceptionJsonPath -and (Test-Path $perceptionJsonPath)) {
                    $perceptionData = Get-Content $perceptionJsonPath -Raw | ConvertFrom-Json
                    # Create a summary: list element types with counts, top-level text elements
                    $elementTypes = $perceptionData.elements | Group-Object -Property type | ForEach-Object { "$($_.Name):$($_.Count)" }
                    $textElements = $perceptionData.elements | Where-Object { $_.text -and $_.text.Trim() -ne "" } | Select-Object -First 20 | ForEach-Object { "$($_.type) '$($_.text)' at ($($_.bbox.x),$($_.bbox.y))" }
                    $perceptionSummary = @"
Elements detected: $($perceptionData.element_count) total
Tiers used: $($perceptionData.tiers_used -join ', ')
Element types: $($elementTypes -join ', ')
Key text elements (first 20):
$($textElements -join "`n")
"@
                }
            }
        }
        catch {
            Write-Warning "planner: perception pipeline failed, planning without screen context. Error: $_"
        }
    }

    # 2. Build the DAG planning prompt (the authoritative prompt template from RESEARCH.md Pattern 1)
    $prompt = @"
You are a task planner for a desktop automation agent on Windows.
Given the user's natural language goal, produce a JSON array of execution steps (DAG).

USER GOAL: $Goal
APPLICATION: $(if ($ApplicationHint) { $ApplicationHint } else { "auto-detect from goal" })

CURRENT SCREEN STATE:
$perceptionSummary

RULES for each step:
1. "step_id": integer, unique, sequential starting from 1
2. "description": human-readable description of what this step does
3. "depends_on": array of step_ids that must complete before this step (empty array [] for step 1)
4. "action.type": one of [click, doubleclick, rightclick, type, hotkey, drag, scroll, wait, launch, shell]
5. "action.target": object describing the UI element to interact with (NOT coordinates):
   - "description": what the element looks like (for visual recognition)
   - "element_type": menu, button, textbox, tab, toolbar, listitem, etc.
   - "text_hint": expected text/label on the target (for OCR matching at execution time)
   - "position_hint": general location (e.g., "top-left of application window", "center of dialog")
6. "action.expected_outcome": what should happen if this step succeeds:
   - "visual_change": describe the expected visible change
   - "ocr_check": comma-separated text strings that should appear (for OCR confirmation)
   - "ui_state": expected UI element state change (e.g., "button becomes selected")
   - "negative_check": error indicators that would signal failure
7. "action.alternatives": array of 2-3 alternative strategies, each with:
   - "strategy": "keyboard_shortcut" | "menu_navigation" | "retry_reposition" | "alternate_path"
   - "action": the alternative action to try (same schema as primary action)
   - "description": why this alternative might work
8. "max_retries": 3 (hard cap per step)
9. "timeout_ms": suggested timeout in milliseconds (5000 for clicks, 15000 for launches)

CRITICAL RULES:
- Steps MUST be topologically ordered: if step B depends on step A, step A must appear before step B in the array
- Each step MUST have at least 2 alternatives with different strategies (not 3 variations of "retry click")
- Expected outcomes MUST include ocr_check OR ui_state (at least one specific verifiable check)
- NEVER include hardcoded screen coordinates — use element descriptions only
- For standard Windows operations, prefer keyboard shortcuts (Alt+F, Ctrl+S) over mouse clicks
- Maximum 20 steps for single-application tasks

Output ONLY valid JSON array. No explanation text, no markdown fences.
"@

    # 3. Write prompt to temp file for Claude MCP consumption
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $promptFile = "$env:TEMP\dag_prompt_${timestamp}.txt"
    $prompt | Out-File -FilePath $promptFile -Encoding UTF8

    # 4. Return result object
    $result = [PSCustomObject]@{
        PromptFile         = $promptFile
        Goal               = $Goal
        ApplicationHint    = $ApplicationHint
        PerceptionJsonPath = $perceptionJsonPath
        Timestamp          = Get-Date -Format 'o'
    }

    return $result
}

# =============================================================================
# SCRIPT BODY: When invoked directly (not dot-sourced)
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Goal) {
        Write-Error "Goal parameter is required when running planner.ps1 directly. Usage: .\planner.ps1 -Goal 'your task goal'"
        exit 1
    }
    $result = Invoke-TaskDecomposition -Goal $Goal -ScreenshotPath $ScreenshotPath -ApplicationHint $ApplicationHint
    Write-Output "PLANNER_COMPLETE|$($result.PromptFile)|goal: $Goal"
}
