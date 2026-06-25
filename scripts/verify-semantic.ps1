# verify-semantic.ps1 — Claude-Powered Semantic Verification
# When OCR + pixel diff return UNCERTAIN, this module sends visual evidence
# to Claude for semantic judgment: "does this screenshot match the expected outcome?"
#
# Called from executor.ps1 VERIFY state as a fallback layer.
#
# Exports:
#   Invoke-SemanticVerification  — main entry: before/after + expected → verdict
#   Format-VerificationPrompt    — builds the Claude prompt
#   Parse-Verdict                — validates Claude response
#
# Usage:
#   . "$PSScriptRoot\verify-semantic.ps1"
#   $verdict = Invoke-SemanticVerification -Before "before.png" -After "after.png" `
#               -ExpectedOutcome @{ visual_change = "menu opens"; ocr_check = "New, Open" }

param(
    [string]$Before = "",
    [string]$After = "",
    [hashtable]$ExpectedOutcome = @{},
    [string]$OcrText = "",
    [string]$OutputDir = "$env:TEMP"
)

# =============================================================================
# FUNCTION: Format-VerificationPrompt
# Builds the prompt that Claude sees for semantic verification.
# =============================================================================
function Format-VerificationPrompt {
    param(
        [string]$BeforePath,
        [string]$AfterPath,
        [hashtable]$Expected,
        [string]$ActualOcrText
    )

    $visualChange = if ($Expected.visual_change) { $Expected.visual_change } else { "unspecified" }
    $ocrCheck = if ($Expected.ocr_check) { $Expected.ocr_check } else { "none" }
    $uiState = if ($Expected.ui_state) { $Expected.ui_state } else { "none" }
    $negCheck = if ($Expected.negative_check) { $Expected.negative_check } else { "none" }

    $prompt = @"
You are a verification agent for desktop automation. Compare the BEFORE and AFTER screenshots and determine if the expected outcome occurred.

EXPECTED OUTCOME:
- Visual change: $visualChange
- OCR text that should appear: $ocrCheck
- UI state change: $uiState
- Negative check (error indicators): $negCheck

ACTUAL OCR TEXT FOUND:
$ActualOcrText

TASK: Determine if the action succeeded, failed, or is uncertain.

Respond with ONLY a JSON object (no markdown fences, no explanation):
{
  "verdict": "SUCCESS" or "FAILURE" or "UNCERTAIN",
  "confidence": 0.0 to 1.0,
  "reasoning": "one sentence explaining your judgment",
  "suggested_action": null or "specific retry suggestion"
}

RULES:
- If the expected visual change is clearly visible → SUCCESS
- If error dialogs or negative indicators appear → FAILURE
- If the expected OCR text is present → evidence for SUCCESS
- If the expected OCR text is absent after a text-entry action → evidence for FAILURE
- If the change is ambiguous or minimal → UNCERTAIN
- Be conservative: when in doubt, choose UNCERTAIN
"@

    return $prompt
}

# =============================================================================
# FUNCTION: Parse-Verdict
# Validates and parses Claude's JSON response into a structured verdict.
# Returns: PSCustomObject { verdict, confidence, reasoning, suggested_action }
#          or $null if response is invalid
# =============================================================================
function Parse-Verdict {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Response
    )

    try {
        # Strip markdown fences if present
        $cleaned = $Response.Trim()
        if ($cleaned -match '```(?:json)?\s*([\s\S]*?)```') {
            $cleaned = $Matches[1].Trim()
        }

        $parsed = $cleaned | ConvertFrom-Json

        # Validate required fields
        $validVerdicts = @("SUCCESS", "FAILURE", "UNCERTAIN")
        if ($parsed.verdict -notin $validVerdicts) {
            Write-Warning "verify-semantic: invalid verdict '$($parsed.verdict)', treating as UNCERTAIN"
            return [PSCustomObject]@{
                verdict          = "UNCERTAIN"
                confidence       = 0.0
                reasoning        = "Invalid response format: bad verdict"
                suggested_action = $null
            }
        }

        # Validate confidence range
        $conf = [double]$parsed.confidence
        if ($conf -lt 0.0 -or $conf -gt 1.0) { $conf = 0.5 }

        return [PSCustomObject]@{
            verdict          = $parsed.verdict
            confidence       = $conf
            reasoning        = if ($parsed.reasoning) { $parsed.reasoning } else { "no reasoning provided" }
            suggested_action = $parsed.suggested_action
        }
    }
    catch {
        Write-Warning "verify-semantic: failed to parse Claude response: $_"
        return [PSCustomObject]@{
            verdict          = "UNCERTAIN"
            confidence       = 0.0
            reasoning        = "Response parse error: $_"
            suggested_action = $null
        }
    }
}

# =============================================================================
# FUNCTION: Invoke-SemanticVerification
# Main entry point. Sends before/after screenshots + expected outcome to Claude
# for semantic judgment.
#
# In DryRun or test mode, returns a mock verdict.
# In production, writes a request JSON for Claude Code to process.
#
# Returns: "SUCCESS" | "FAILURE" | "UNCERTAIN"
# =============================================================================
function Invoke-SemanticVerification {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BeforeScreenshot,

        [Parameter(Mandatory=$true)]
        [string]$AfterScreenshot,

        [Parameter(Mandatory=$true)]
        [hashtable]$ExpectedOutcome,

        [string]$OcrText = "",

        [string]$OutputDir = "$env:TEMP",

        [switch]$DryRun
    )

    # Validate screenshots exist
    if (-not (Test-Path $BeforeScreenshot)) {
        Write-Warning "verify-semantic: before screenshot not found: $BeforeScreenshot"
        return "UNCERTAIN"
    }
    if (-not (Test-Path $AfterScreenshot)) {
        Write-Warning "verify-semantic: after screenshot not found: $AfterScreenshot"
        return "UNCERTAIN"
    }

    # Build the verification prompt
    $prompt = Format-VerificationPrompt -BeforePath $BeforeScreenshot `
        -AfterPath $AfterScreenshot -Expected $ExpectedOutcome -ActualOcrText $OcrText

    if ($DryRun) {
        Write-Host "SEMVER|DRYRUN|prompt built, length=$($prompt.Length)"
        Write-Host "SEMVER|DRYRUN|returning mock UNCERTAIN"
        return "UNCERTAIN"
    }

    # Write request for Claude Code to pick up
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $requestPath = Join-Path $OutputDir "semver_request_$timestamp.json"

    $request = [PSCustomObject]@{
        type              = "semantic_verification"
        before_screenshot = $BeforeScreenshot
        after_screenshot  = $AfterScreenshot
        prompt            = $prompt
        expected_outcome  = $ExpectedOutcome
        ocr_text          = $OcrText
        timestamp         = Get-Date -Format 'o'
    }

    $request | ConvertTo-Json -Depth 5 | Out-File -FilePath $requestPath -Encoding UTF8

    Write-Host "SEMVER|request|$requestPath"

    # Write the prompt to a separate file for easy Claude consumption
    $promptPath = Join-Path $OutputDir "semver_prompt_$timestamp.txt"
    $prompt | Out-File -FilePath $promptPath -Encoding UTF8

    Write-Host "SEMVER|prompt|$promptPath"

    # Return the prompt path — caller (Claude Code session) processes it
    # and writes response to semver_response_$timestamp.json
    return [PSCustomObject]@{
        RequestPath = $requestPath
        PromptPath  = $promptPath
        Prompt      = $prompt
    }
}

# =============================================================================
# FUNCTION: Read-SemanticResponse
# Reads Claude's response after it has been written to the response file.
# =============================================================================
function Read-SemanticResponse {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ResponsePath
    )

    if (-not (Test-Path $ResponsePath)) {
        Write-Warning "verify-semantic: response file not found: $ResponsePath"
        return "UNCERTAIN"
    }

    try {
        $responseText = Get-Content $ResponsePath -Raw
        $verdict = Parse-Verdict -Response $responseText

        Write-Host "SEMVER|verdict=$($verdict.verdict)|confidence=$($verdict.confidence)|$($verdict.reasoning)"

        return $verdict.verdict
    }
    catch {
        Write-Warning "verify-semantic: error reading response: $_"
        return "UNCERTAIN"
    }
}

# =============================================================================
# SCRIPT BODY: When invoked directly (not dot-sourced)
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Before -or -not $After) {
        Write-Error "Before and After parameters are required. Usage: .\verify-semantic.ps1 -Before 'before.png' -After 'after.png'"
        exit 1
    }

    $result = Invoke-SemanticVerification -BeforeScreenshot $Before -AfterScreenshot $After `
        -ExpectedOutcome $ExpectedOutcome -OcrText $OcrText -OutputDir $OutputDir

    if ($result -is [string]) {
        # Direct verdict (DryRun or error)
        Write-Output "SEMVER_RESULT|$result"
    } else {
        # Request object — Claude Code needs to process it
        Write-Output "SEMVER_REQUEST|$($result.RequestPath)"
    }
}
