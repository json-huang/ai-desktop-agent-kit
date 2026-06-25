# perception.ps1 — Perception Pipeline Orchestrator
# Master orchestration script that ties together all four perception tiers
# (UIA, OCR, template matching, vision model) with the fusion engine and
# annotated screenshot renderer. This is THE single entry point for
# Phase 2 agents and users: "tell me what's on the screen."
#
# TIER ORDER (locked):
#   1. UIA (uiAutomation)     — always runs first, confidence >= 0.95
#   2. OCR (ocr)              — always runs second, confidence >= 0.8
#   3. Template (templateMatch)— always runs third if templates available
#   4. Vision (visionModel)   — CONDITIONAL on Test-VisionFallbackNeeded
#
# OUTPUT:
#   JSON: {OutputDir}/perception_{timestamp}.json
#   PNG:  {OutputDir}/perception_{timestamp}_annotated.png
#
# Usage:
#   .\perception.ps1                                    # Full pipeline, default output
#   .\perception.ps1 -SkipVision                        # Skip vision tier
#   .\perception.ps1 -WindowTitle "Notepad"             # Target specific window
#   .\perception.ps1 -OutputDir "C:\results"            # Custom output dir
#   .\perception.ps1 -NoAnnotate                        # JSON only, no PNG

param(
    [string]$WindowTitle = "",         # Target window title (empty = full desktop)
    [switch]$SkipUia,                  # DEBUG: skip UIA tier
    [switch]$SkipOcr,                  # DEBUG: skip OCR tier
    [switch]$SkipTemplate,             # DEBUG: skip template matching tier
    [switch]$SkipVision,               # DEBUG: skip vision tier (default off = skip)
    [switch]$ForceVision,              # Force vision tier even if not needed
    [string]$PercOutputDir = "$env:USERPROFILE\Desktop",  # Output directory for JSON and PNG (renamed to avoid collision when dot-sourced)
    [string]$TemplateDir = "",         # Directory of template images for template matching
    [switch]$NoAnnotate               # Skip annotated PNG generation
)

# =============================================================================
# HELPER: ConvertFrom-UiaResult
# Converts UiaTool.UiaElement C# structs to unified UiElement PSObjects.
# Handles type mapping from "ControlType.Button" → "button", etc.
# =============================================================================
function ConvertFrom-UiaResult {
    param(
        [object[]]$UiaElements
    )

    if ($null -eq $UiaElements -or $UiaElements.Count -eq 0) {
        return @()
    }

    # Dot-source the schema
    . "$PSScriptRoot\perception-schema.ps1"

    $result = [System.Collections.Generic.List[object]]::new()

    foreach ($raw in $UiaElements) {
        if ($null -eq $raw) { continue }

        # Map C# ControlType.ProgrammaticName to unified type
        $rawType = if ($raw.Type) { $raw.Type } else { "ControlType.Unknown" }
        $unifiedType = switch -Wildcard ($rawType) {
            "ControlType.Button*"     { "button"; break }
            "ControlType.MenuItem*"   { "menu"; break }
            "ControlType.Menu*"       { "menu"; break }
            "ControlType.Edit*"       { "textbox"; break }
            "ControlType.Text*"       { "label"; break }
            "ControlType.Window*"     { "window"; break }
            "ControlType.Tab*"        { "tab"; break }
            "ControlType.ToolBar*"    { "toolbar"; break }
            "ControlType.Link*"       { "link"; break }
            "ControlType.Image*"      { "image"; break }
            "ControlType.Icon*"       { "icon"; break }
            "ControlType.Label*"      { "label"; break }
            "ControlType.Tree*"       { "other"; break }
            "ControlType.List*"       { "other"; break }
            "ControlType.ComboBox*"   { "other"; break }
            "ControlType.CheckBox*"   { "button"; break }
            "ControlType.RadioButton*" { "button"; break }
            "ControlType.ScrollBar*"  { "other"; break }
            "ControlType.Slider*"     { "other"; break }
            "ControlType.ProgressBar*" { "other"; break }
            "ControlType.Spinner*"    { "other"; break }
            "ControlType.SplitButton*" { "button"; break }
            "ControlType.Pane*"       { "other"; break }
            "ControlType.Group*"      { "other"; break }
            "ControlType.Thumb*"      { "other"; break }
            "ControlType.HeaderItem*" { "other"; break }
            "ControlType.Header*"     { "other"; break }
            "ControlType.DataGrid*"   { "other"; break }
            "ControlType.DataItem*"   { "other"; break }
            "ControlType.Document*"   { "other"; break }
            "ControlType.Calendar*"   { "other"; break }
            "ControlType.Custom*"     { "other"; break }
            default                   { "other" }
        }

        # Map state
        $state = "unknown"
        if ($raw.IsEnabled -eq $true) { $state = "enabled" }
        if ($raw.HasKeyboardFocus -eq $true) { $state = "focused" }
        if ($raw.IsOffscreen -eq $true) { $state = "hidden" }

        $confidence = if ($raw.Confidence) { [double]$raw.Confidence } else { 0.99 }
        $text = if ($raw.Name) { $raw.Name } else { "" }

        $element = New-UiElement -Type $unifiedType `
            -X ([int]$raw.Left) -Y ([int]$raw.Top) `
            -W ([int]$raw.Width) -H ([int]$raw.Height) `
            -Confidence $confidence `
            -Text $text `
            -State $state `
            -IsInteractive ([bool]$raw.IsEnabled) `
            -Source "uiAutomation" `
            -Alternatives @() `
            -DisplayIndex 0 `
            -DpiScale 1.0 `
            -ParentIndex ([int]$raw.ParentIndex)

        $result.Add($element)
    }

    return $result.ToArray()
}

# =============================================================================
# HELPER: Invoke-OcrTier
# Runs ocr.ps1 and converts output via ConvertFrom-OcrResult.
# Returns unified UiElement array.
# =============================================================================
function Invoke-OcrTier {
    param(
        [string]$ScreenshotPath,
        [string]$Lang = ""
    )

    $ocrScript = "$PSScriptRoot\ocr.ps1"

    if (-not (Test-Path $ocrScript)) {
        Write-Warning "OCR tier: ocr.ps1 not found at $ocrScript"
        return @()
    }

    # Build ocr.ps1 arguments
    $ocrArgs = @("-Detail")
    if ($ScreenshotPath) {
        $ocrArgs += @("-Image", $ScreenshotPath)
    }
    if ($Lang) {
        $ocrArgs += @("-Lang", $Lang)
    }

    # Run ocr.ps1
    $ocrOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $ocrScript @ocrArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "OCR tier: ocr.ps1 exited with code $LASTEXITCODE"
        return @()
    }

    # Parse ocr.ps1 output: LINE|text|left,top|widthxheight
    . "$PSScriptRoot\ocr-adapter.ps1"
    $lines = @()
    foreach ($outLine in $ocrOutput) {
        if ($outLine -match '^LINE\|(.+?)\|(\d+),(\d+)\|(\d+)x(\d+)$') {
            $lines += [PSCustomObject]@{
                Text   = $Matches[1]
                Left   = [int]$Matches[2]
                Top    = [int]$Matches[3]
                Width  = [int]$Matches[4]
                Height = [int]$Matches[5]
            }
        }
    }

    if ($lines.Count -eq 0) {
        return @()
    }

    $ocrElements = @(ConvertFrom-OcrResult -OcrLines $lines)
    return $ocrElements
}

# =============================================================================
# HELPER: Invoke-TemplateTier
# Runs findimage.ps1 for each template PNG in the template directory.
# Returns unified UiElement array.
# =============================================================================
function Invoke-TemplateTier {
    param(
        [string]$ScreenshotPath,
        [string]$TemplateDir
    )

    if (-not $TemplateDir -or -not (Test-Path $TemplateDir)) {
        return @()
    }

    $templateFiles = @(Get-ChildItem "$TemplateDir\*.png" -ErrorAction SilentlyContinue)
    if ($templateFiles.Count -eq 0) {
        Write-Warning "Template tier: no .png files found in $TemplateDir"
        return @()
    }

    $findImageScript = "$PSScriptRoot\findimage.ps1"
    if (-not (Test-Path $findImageScript)) {
        Write-Warning "Template tier: findimage.ps1 not found at $findImageScript"
        return @()
    }

    . "$PSScriptRoot\template-adapter.ps1"

    $allMatches = @()
    foreach ($template in $templateFiles) {
        $findArgs = @(
            "-Template", $template.FullName,
            "-Screen", $ScreenshotPath,
            "-Threshold", "0.7"
        )
        $findOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $findImageScript @findArgs 2>&1

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Template tier: findimage.ps1 failed for $($template.Name)"
            continue
        }

        # Parse findimage.ps1 output: OK|centerX,centerY|score=X.XXXX|rect=X,Y,W,H
        foreach ($outLine in $findOutput) {
            if ($outLine -match '^OK\|\d+,\d+\|score=([\d.]+)\|rect=(\d+),(\d+),(\d+),(\d+)$') {
                $allMatches += [PSCustomObject]@{
                    Score     = [float]$Matches[1]
                    X         = [int]$Matches[2]
                    Y         = [int]$Matches[3]
                    TemplateW = [int]$Matches[4]
                    TemplateH = [int]$Matches[5]
                }
            }
        }
    }

    if ($allMatches.Count -eq 0) {
        return @()
    }

    $templateElements = @(ConvertFrom-TemplateMatch -Matches $allMatches -Threshold 0.7)
    return $templateElements
}

# =============================================================================
# MAIN FUNCTION: Invoke-PerceptionPipeline
# Orchestrates the full perception pipeline: screenshot → tiers → fusion → output.
# Each tier failure is isolated — one tier crash does not abort the pipeline.
# Returns a PSCustomObject status with JsonPath, PngPath, ElementCount, etc.
# =============================================================================
function Invoke-PerceptionPipeline {
    param(
        [string]$WindowTitle = "",
        [bool]$SkipUia = $false,
        [bool]$SkipOcr = $false,
        [bool]$SkipTemplate = $false,
        [bool]$SkipVision = $false,
        [bool]$ForceVision = $false,
        [string]$OutputDir = "$env:USERPROFILE\Desktop",
        [string]$TemplateDir = "",
        [bool]$NoAnnotate = $false
    )

    # 1. START timer
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tiersUsed = @()
    $visionManifest = $null

    # Ensure output directory exists
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # 2. CAPTURE screenshot
    try {
        $screenshotArgs = @{}
        if ($WindowTitle) { $screenshotArgs['WindowTitle'] = $WindowTitle }
        $screenshotScript = "$PSScriptRoot\screenshot.ps1"

        # Generate a timestamped path in the output directory
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $screenshotPath = Join-Path $OutputDir "screenshot_$timestamp.png"
        $screenshotArgs['Path'] = $screenshotPath

        $result = & powershell -NoProfile -ExecutionPolicy Bypass -File $screenshotScript @screenshotArgs 2>&1

        # Parse "OK|fullPath|WxH|sizeKB"
        if ($result -is [array]) { $result = $result -join "`n" }
        if ($result -match 'OK\|(.+?)\|(\d+)x(\d+)\|') {
            $screenshotPath = $matches[1]
            $screenW = [int]$matches[2]
            $screenH = [int]$matches[3]
        }
        else {
            throw "Screenshot failed: $result"
        }
    }
    catch {
        Write-Output "ERROR|screenshot capture failed: $_"
        $sw.Stop()
        $status = [PSCustomObject]@{
            JsonPath = ""
            PngPath = ""
            ScreenshotPath = ""
            ElementCount = 0
            TiersUsed = ""
            DurationMs = $sw.ElapsedMilliseconds
            VisionManifest = $null
            Error = "screenshot capture failed: $_"
        }
        Write-Output ($status | ConvertTo-Json)
        return $status
    }

    # 3. TIER 1 — UIA (unless skipped)
    $uiaElements = @()
    if (-not $SkipUia) {
        try {
            $uiaScript = "$PSScriptRoot\uia.ps1"
            if (-not (Test-Path $uiaScript)) {
                Write-Warning "UIA tier: uia.ps1 not found"
            }
            else {
                . "$uiaScript"
                $rawUiaElements = @(Get-UiaElements -WindowTitle $WindowTitle)
                if ($rawUiaElements -and $rawUiaElements.Count -gt 0) {
                    $uiaElements = @(ConvertFrom-UiaResult -UiaElements $rawUiaElements)
                    $tiersUsed += "uiAutomation"
                }
            }
        }
        catch {
            Write-Warning "UIA tier failed: $_"
        }
    }

    # 4. TIER 2 — OCR (unless skipped)
    $ocrElements = @()
    if (-not $SkipOcr) {
        try {
            $ocrElements = @(Invoke-OcrTier -ScreenshotPath $screenshotPath)
            if ($ocrElements.Count -gt 0) {
                $tiersUsed += "ocr"
            }
        }
        catch {
            Write-Warning "OCR tier failed: $_"
        }
    }

    # 5. TIER 3 — Template Matching (unless skipped, if templates available)
    $templateElements = @()
    if (-not $SkipTemplate -and $TemplateDir) {
        try {
            $templateElements = @(Invoke-TemplateTier -ScreenshotPath $screenshotPath -TemplateDir $TemplateDir)
            if ($templateElements.Count -gt 0) {
                $tiersUsed += "templateMatch"
            }
        }
        catch {
            Write-Warning "Template matching tier failed: $_"
        }
    }

    # 6. TIER 4 — Vision Model (conditional)
    $visionElements = @()
    if (-not $SkipVision) {
        try {
            $visionScript = "$PSScriptRoot\vision.ps1"
            if (-not (Test-Path $visionScript)) {
                Write-Warning "Vision tier: vision.ps1 not found"
            }
            else {
                . "$visionScript"
                $needVision = $ForceVision -or (Test-VisionFallbackNeeded -UiaElements $uiaElements -OcrElements $ocrElements -TemplateElements $templateElements)

                if ($needVision) {
                    $visionManifestObj = Invoke-VisionPerception -ImagePath $screenshotPath
                    $visionManifest = $visionManifestObj
                    $tiersUsed += "visionModel"

                    Write-Warning "Vision tier invoked: manifest produced. Human-in-the-loop processing required via Claude chat."
                    Write-Warning "Resized image: $($visionManifest.resized_image_path)"
                    Write-Warning "Prompt file: $($visionManifest.prompt_file)"
                }
            }
        }
        catch {
            Write-Warning "Vision tier failed: $_"
        }
    }

    # 7. FUSION
    $merged = @()
    try {
        . "$PSScriptRoot\fusion.ps1"
        . "$PSScriptRoot\perception-schema.ps1"
        $merged = @(Merge-PerceptionTiers -UiaElements $uiaElements -OcrElements $ocrElements -TemplateElements $templateElements -VisionElements $visionElements)
    }
    catch {
        Write-Warning "Fusion failed: $_"
        # If fusion fails, at least return the UIA elements raw, wrapped in a root
        . "$PSScriptRoot\perception-schema.ps1"
        if ($uiaElements.Count -gt 0) {
            $merged = @(Merge-PerceptionTiers -UiaElements $uiaElements)
        }
        else {
            $merged = @(Merge-PerceptionTiers)
        }
    }

    # 8. OUTPUT JSON
    $jsonPath = Join-Path $OutputDir "perception_$timestamp.json"
    try {
        $jsonOutput = [PSCustomObject]@{
            timestamp     = (Get-Date -Format 'o')
            source        = "perception.ps1 v1.0"
            tiers_used    = $tiersUsed
            element_count = $merged.Count
            elements      = $merged
        }
        $jsonOutput | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
    }
    catch {
        Write-Warning "JSON output failed: $_"
    }

    # 9. ANNOTATED PNG (unless skipped)
    $pngPath = ""
    if (-not $NoAnnotate -and $screenshotPath -and (Test-Path $screenshotPath)) {
        try {
            . "$PSScriptRoot\render-annotations.ps1"
            $pngResult = Add-PerceptionAnnotations -ScreenshotPath $screenshotPath -Elements $merged -OutputPath (Join-Path $OutputDir "perception_${timestamp}_annotated.png")
            # Parse "OK|path|annotated"
            if ($pngResult -match '^OK\|(.+?)\|') {
                $pngPath = $matches[1]
            }
        }
        catch {
            Write-Warning "Annotated PNG generation failed: $_"
        }
    }

    # 10. STOP timer and build status (do NOT Write-Output — caller handles output)
    $sw.Stop()
    $status = [PSCustomObject]@{
        JsonPath       = $jsonPath
        PngPath        = $pngPath
        ScreenshotPath = $screenshotPath
        ElementCount   = $merged.Count
        TiersUsed      = $tiersUsed -join ","
        DurationMs     = $sw.ElapsedMilliseconds
        VisionManifest = $visionManifest
    }

    # Output JSON status line for consumers
    Write-Output ($status | ConvertTo-Json -Depth 3)
    return $status
}

# =============================================================================
# SCRIPT BODY: When invoked directly (not dot-sourced)
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {
    $output = Invoke-PerceptionPipeline -WindowTitle $WindowTitle `
        -SkipUia:$SkipUia -SkipOcr:$SkipOcr -SkipTemplate:$SkipTemplate `
        -SkipVision:$SkipVision -ForceVision:$ForceVision `
        -OutputDir $PercOutputDir -TemplateDir $TemplateDir -NoAnnotate:$NoAnnotate

    # Invoke-PerceptionPipeline outputs: JSON status string, then PSCustomObject status
    if ($output -is [array] -and $output.Count -ge 2) {
        $statusJson = $output[0].ToString()
        $statusObj = $output[1]
    } elseif ($output -is [array]) {
        $statusJson = $output[0].ToString()
        $statusObj = $output[0]
    } else {
        $statusJson = "$output"
        $statusObj = $output
    }

    # Emit JSON status line (for machine consumers)
    Write-Output $statusJson

    # Emit human-readable status line to stdout
    $tiersInfo = if ($statusObj.TiersUsed) { $statusObj.TiersUsed } else { "none" }
    $elementInfo = if ($statusObj.ElementCount) { "$($statusObj.ElementCount) elements" } else { "0 elements" }
    $durationInfo = if ($statusObj.DurationMs) { "$($statusObj.DurationMs)ms" } else { "0ms" }

    Write-Output "PERCEPTION_COMPLETE|$($statusObj.JsonPath)|$elementInfo|$durationInfo|tiers: $tiersInfo"
}
