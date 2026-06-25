# claude-bridge.ps1 — Claude API Bridge for Agent Loop
# Handles communication between executor.ps1 and Claude Code for:
#   1. Macro-planning: Goal → DAG JSON (called once at start)
#   2. Micro-planning: DAG step + perception → resolved action with coordinates (per step)
#   3. Semantic verification: before/after + expected → verdict (when UNCERTAIN)
#
# Protocol: stdin/stdout JSON (Claude Code session processes requests)
#
# Exports:
#   Invoke-ClaudePlanning      — sends goal + perception, returns DAG
#   Invoke-ClaudeMicroPlan     — sends step + perception, returns resolved action
#   Invoke-ClaudeVerification  — sends screenshots + expected, returns verdict
#   Write-ClaudeRequest        — writes request JSON for Claude to pick up
#   Read-ClaudeResponse        — reads Claude's response from file
#
# Usage:
#   . "$PSScriptRoot\claude-bridge.ps1"
#   $dag = Invoke-ClaudePlanning -Goal "open Notepad" -PerceptionJson "perception.json"

param(
    [string]$OutputDir = "$env:TEMP\claude_bridge"
)

# Ensure output directory exists
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# =============================================================================
# FUNCTION: Write-ClaudeRequest
# Writes a structured request JSON for Claude Code to process.
# Returns: path to the request file
# =============================================================================
function Write-ClaudeRequest {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Type,

        [Parameter(Mandatory=$true)]
        [hashtable]$Payload,

        [string]$OutputDir = $script:OutputDir
    )

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $requestId = [Guid]::NewGuid().ToString().Substring(0, 8)
    $requestPath = Join-Path $OutputDir "request_${Type}_${timestamp}_${requestId}.json"

    $request = [PSCustomObject]@{
        type       = $Type
        request_id = $requestId
        payload    = $Payload
        timestamp  = Get-Date -Format 'o'
    }

    $request | ConvertTo-Json -Depth 10 | Out-File -FilePath $requestPath -Encoding UTF8

    Write-Host "BRIDGE|request|$Type|$requestPath"
    return $requestPath
}

# =============================================================================
# FUNCTION: Read-ClaudeResponse
# Reads and validates Claude's JSON response from a file.
# Waits up to TimeoutSeconds for the file to appear.
# Returns: PSCustomObject parsed response, or $null on timeout/error
# =============================================================================
function Read-ClaudeResponse {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResponsePath,

        [int]$TimeoutSeconds = 120,
        [int]$PollIntervalMs = 500
    )

    $elapsed = 0
    while (-not (Test-Path $ResponsePath) -and $elapsed -lt ($TimeoutSeconds * 1000)) {
        Start-Sleep -Milliseconds $PollIntervalMs
        $elapsed += $PollIntervalMs
    }

    if (-not (Test-Path $ResponsePath)) {
        Write-Warning "claude-bridge: timeout waiting for response at $ResponsePath (${TimeoutSeconds}s)"
        return $null
    }

    try {
        $responseText = Get-Content $ResponsePath -Raw
        $response = $responseText | ConvertFrom-Json

        # Validate it has the expected type field
        if (-not $response.type) {
            Write-Warning "claude-bridge: response missing 'type' field"
        }

        return $response
    }
    catch {
        Write-Warning "claude-bridge: failed to parse response: $_"
        return $null
    }
}

# =============================================================================
# FUNCTION: Invoke-ClaudePlanning
# Sends a macro-planning request: goal + perception context → DAG JSON.
#
# Returns: PSCustomObject { dag, confidence, request_path, response_path }
#          or $null on failure
# =============================================================================
function Invoke-ClaudePlanning {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Goal,

        [string]$PerceptionJson = "",

        [string]$ApplicationHint = "",

        [string]$OutputDir = $script:OutputDir,

        [int]$TimeoutSeconds = 120
    )

    # Load perception summary if available
    $perceptionSummary = "No screen data available."
    $perceptionElements = @()

    if ($PerceptionJson -and (Test-Path $PerceptionJson)) {
        try {
            $pData = Get-Content $PerceptionJson -Raw | ConvertFrom-Json
            $perceptionElements = $pData.elements
            $elementTypes = $pData.elements | Group-Object -Property type | ForEach-Object { "$($_.Name):$($_.Count)" }
            $perceptionSummary = "Elements: $($pData.element_count) total, types: $($elementTypes -join ', ')"
        }
        catch {
            Write-Warning "claude-bridge: failed to load perception: $_"
        }
    }

    # Build the planning prompt (same as planner.ps1 but integrated)
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
5. "action.target": object describing the UI element (NOT coordinates):
   - "description": what the element looks like
   - "element_type": menu, button, textbox, tab, toolbar, listitem, etc.
   - "text_hint": expected text/label on the target
   - "position_hint": general location (e.g., "top-left of window")
6. "action.expected_outcome": what should happen if this step succeeds:
   - "visual_change": describe the expected visible change
   - "ocr_check": text strings that should appear
   - "ui_state": expected UI element state change
   - "negative_check": error indicators that would signal failure
7. "action.alternatives": array of 2-3 alternative strategies
8. "max_retries": 3
9. "timeout_ms": 5000 for clicks, 15000 for launches

CRITICAL: Steps MUST be topologically ordered. Output ONLY valid JSON array.
"@

    # Write request
    $requestPath = Write-ClaudeRequest -Type "dag_generation" -Payload @{
        goal               = $Goal
        application_hint   = $ApplicationHint
        perception_summary = $perceptionSummary
        prompt             = $prompt
    } -OutputDir $OutputDir

    # Write prompt separately for easy consumption
    $promptPath = $requestPath -replace '\.json$', '.prompt.txt'
    $prompt | Out-File -FilePath $promptPath -Encoding UTF8

    # Expected response path
    $responsePath = $requestPath -replace 'request_', 'response_'

    Write-Host "BRIDGE|planning|goal='$Goal'|request=$requestPath"
    Write-Host "BRIDGE|planning|waiting for response at $responsePath"

    # Return the request info — Claude Code processes it and writes response
    return [PSCustomObject]@{
        RequestPath  = $requestPath
        ResponsePath = $responsePath
        PromptPath   = $promptPath
        Prompt       = $prompt
        Goal         = $Goal
    }
}

# =============================================================================
# FUNCTION: Invoke-ClaudeMicroPlan
# Sends a micro-planning request: step + perception elements → resolved action.
#
# Returns: PSCustomObject { resolved_action, confidence, request_path }
#          or $null on failure
# =============================================================================
function Invoke-ClaudeMicroPlan {
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Step,

        [object[]]$PerceptionElements = @(),

        [string]$ScreenshotPath = "",

        [string]$OutputDir = $script:OutputDir,

        [int]$TimeoutSeconds = 60
    )

    # Summarize perception elements for the prompt
    $elementSummary = ""
    if ($PerceptionElements -and $PerceptionElements.Count -gt 0) {
        $interactive = @($PerceptionElements | Where-Object { $_.isInteractive })
        $elementSummary = "$($PerceptionElements.Count) elements ($($interactive.Count) interactive):`n"
        # Include top 30 interactive elements with text
        $withText = @($interactive | Where-Object { $_.text -and $_.text.Trim() -ne "" } | Select-Object -First 30)
        foreach ($el in $withText) {
            $elementSummary += "  [$($el.type)] '$($el.text)' at ($($el.bbox.x),$($el.bbox.y)) $($el.bbox.w)x$($el.bbox.h) src=$($el.source)`n"
        }
    } else {
        $elementSummary = "No perception elements available."
    }

    $stepJson = $Step | ConvertTo-Json -Depth 5 -Compress

    $prompt = @"
You are a micro-planner for desktop automation. Given a single DAG step and current screen elements,
determine the EXACT coordinates to interact with.

STEP: $stepJson

SCREEN ELEMENTS:
$elementSummary

TASK: Resolve the step's target description to concrete coordinates.

Respond with ONLY valid JSON:
{
  "resolved_action": {
    "type": "click|doubleclick|rightclick|type|hotkey|drag|scroll|launch|shell|wait",
    "target_x": <integer pixel X>,
    "target_y": <integer pixel Y>,
    "text": "<text to type, if action.type=type>",
    "mod": "<modifier key, if action.type=hotkey>",
    "key": "<key name, if action.type=hotkey>",
    "command": "<command, if action.type=launch or shell>",
    "ms": <milliseconds, if action.type=wait>
  },
  "confidence": 0.0 to 1.0,
  "reasoning": "one sentence explaining the coordinate choice"
}

RULES:
- Use the element list to find the target by text_hint and element_type
- Coordinates must be CENTER of the target element's bounding box
- If multiple candidates, prefer: enabled > disabled, higher confidence, interactive > non-interactive
- If no match found, set confidence < 0.3 and suggest ESCALATE
"@

    $requestPath = Write-ClaudeRequest -Type "micro_plan" -Payload @{
        step               = $Step
        element_count      = $PerceptionElements.Count
        screenshot_path    = $ScreenshotPath
        prompt             = $prompt
    } -OutputDir $OutputDir

    $promptPath = $requestPath -replace '\.json$', '.prompt.txt'
    $prompt | Out-File -FilePath $promptPath -Encoding UTF8

    $responsePath = $requestPath -replace 'request_', 'response_'

    Write-Host "BRIDGE|micro_plan|step=$($Step.step_id)|request=$requestPath"

    return [PSCustomObject]@{
        RequestPath  = $requestPath
        ResponsePath = $responsePath
        PromptPath   = $promptPath
        Prompt       = $prompt
        StepId       = $Step.step_id
    }
}

# =============================================================================
# FUNCTION: Invoke-ClaudeVerification
# Sends a semantic verification request: before/after + expected → verdict.
#
# Returns: PSCustomObject { verdict, confidence, request_path }
#          or $null on failure
# =============================================================================
function Invoke-ClaudeVerification {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BeforeScreenshot,

        [Parameter(Mandatory=$true)]
        [string]$AfterScreenshot,

        [Parameter(Mandatory=$true)]
        [hashtable]$ExpectedOutcome,

        [string]$OcrText = "",

        [string]$OutputDir = $script:OutputDir,

        [int]$TimeoutSeconds = 60
    )

    # Delegate to verify-semantic.ps1
    . "$PSScriptRoot\verify-semantic.ps1"

    $result = Invoke-SemanticVerification -BeforeScreenshot $BeforeScreenshot `
        -AfterScreenshot $AfterScreenshot -ExpectedOutcome $ExpectedOutcome `
        -OcrText $OcrText -OutputDir $OutputDir

    if ($result -is [string]) {
        # Direct verdict (DryRun or error)
        return [PSCustomObject]@{
            Verdict    = $result
            Confidence = 0.0
            Reasoning  = "Direct return (DryRun or error)"
        }
    }

    # Request object — needs Claude processing
    $responsePath = $result.RequestPath -replace 'request_', 'response_'

    Write-Host "BRIDGE|verification|request=$($result.RequestPath)"

    return [PSCustomObject]@{
        RequestPath  = $result.RequestPath
        ResponsePath = $responsePath
        PromptPath   = $result.PromptPath
        Prompt       = $result.Prompt
    }
}

# =============================================================================
# FUNCTION: Read-DagFromResponse
# Parses a DAG generation response and validates the DAG structure.
# Returns: array of step objects, or $null on invalid
# =============================================================================
function Read-DagFromResponse {
    param(
        [Parameter(Mandatory=$true)]
        [object]$Response
    )

    if (-not $Response.dag) {
        Write-Warning "claude-bridge: response missing 'dag' field"
        return $null
    }

    $dag = $Response.dag
    if ($dag -isnot [array]) {
        $dag = @($dag)
    }

    # Validate each step has required fields
    foreach ($step in $dag) {
        $required = @('step_id', 'description', 'depends_on', 'action')
        foreach ($field in $required) {
            $hasField = $false
            if ($step -is [hashtable] -or $step -is [System.Collections.IDictionary]) {
                $hasField = $step.ContainsKey($field)
            } else {
                $hasField = [bool](Get-Member -InputObject $step -Name $field -MemberType NoteProperty -ErrorAction SilentlyContinue)
            }
            if (-not $hasField) {
                Write-Warning "claude-bridge: DAG step missing '$field'"
                return $null
            }
        }
    }

    return $dag
}

# =============================================================================
# FUNCTION: Read-ResolvedAction
# Parses a micro-plan response and returns the resolved action.
# Returns: PSCustomObject { type, target_x, target_y, ... }, or $null
# =============================================================================
function Read-ResolvedAction {
    param(
        [Parameter(Mandatory=$true)]
        [object]$Response
    )

    if (-not $Response.resolved_action) {
        Write-Warning "claude-bridge: response missing 'resolved_action' field"
        return $null
    }

    $action = $Response.resolved_action

    # Validate required fields
    $actionType = if ($action -is [hashtable]) { $action['type'] } else { $action.type }
    if (-not $actionType) {
        Write-Warning "claude-bridge: resolved_action missing 'type'"
        return $null
    }

    # Ensure coordinates exist for click-type actions
    $clickTypes = @('click', 'doubleclick', 'rightclick', 'drag')
    if ($actionType -in $clickTypes) {
        $hasX = $false
        if ($action -is [hashtable] -or $action -is [System.Collections.IDictionary]) {
            $hasX = $action.ContainsKey('target_x')
        } else {
            $hasX = [bool](Get-Member -InputObject $action -Name 'target_x' -MemberType NoteProperty -ErrorAction SilentlyContinue)
        }
        if (-not $hasX) {
            Write-Warning "claude-bridge: click action missing 'target_x'"
            return $null
        }
    }

    return $action
}

# =============================================================================
# SCRIPT BODY: When invoked directly (not dot-sourced)
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    Write-Host "claude-bridge.ps1 — dot-source this script, don't run directly."
    Write-Host "Usage: . .\claude-bridge.ps1"
    Write-Host "Then call: Invoke-ClaudePlanning, Invoke-ClaudeMicroPlan, Invoke-ClaudeVerification"
}
