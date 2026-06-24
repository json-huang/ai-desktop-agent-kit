# Browser Control Script v1 — agent-browser CLI wrapper (CDP, Chrome/Chromium)
# Usage:
#   .\browser.ps1 -Action start [-Url "https://..."]       # Start browser session and navigate
#   .\browser.ps1 -Action stop                             # Close browser session
#   .\browser.ps1 -Action open -Url "https://..."          # Navigate to URL
#   .\browser.ps1 -Action snapshot                         # Get page accessibility tree
#   .\browser.ps1 -Action snapshot -Detail                 # Show element IDs
#   .\browser.ps1 -Action click -Target "@e1"              # Click element by ref
#   .\browser.ps1 -Action click -Target "#mybtn"           # Click by CSS selector
#   .\browser.ps1 -Action fill -Target "@e2" -Text "hello" # Fill input field
#   .\browser.ps1 -Action type -Target "@e3" -Text "中文"  # Type into element
#   .\browser.ps1 -Action screenshot [-Path "page.png"]    # Screenshot browser viewport
#   .\browser.ps1 -Action extract -Target "table"          # Extract page data
#   .\browser.ps1 -Action electron -App "Slack"            # Connect to Electron app
#   .\browser.ps1 -Action session                          # Get current session info
#   .\browser.ps1 -Action wait -Target "3000"              # Wait (ms or selector)
#   .\browser.ps1 -Action press -Key "Enter"               # Press a key

param(
    [ValidateSet("start","stop","open","snapshot","click","fill","type","screenshot","extract","electron","session","wait","press","scroll","hover","dblclick","select")]
    [string]$Action = "session",
    [string]$Url = "",
    [string]$Target = "",
    [string]$Text = "",
    [string]$Path = "",
    [string]$App = "",
    [string]$Key = "",
    [string]$SessionName = "default",
    [string]$Profile = "",
    [int]$Amount = 100,
    [switch]$Detail = $false,
    [switch]$Annotate = $false,
    [switch]$FullPage = $false,
    [string]$Direction = "down"
)

# --- Config ---
$AGENT_BROWSER_CMD = "$env:APPDATA\npm\agent-browser.cmd"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Helper: Run agent-browser and capture output ---
function Invoke-Browser {
    param([string]$CmdArgs)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "cmd"
        $psi.Arguments = "/c agent-browser $CmdArgs"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        $proc.Start() | Out-Null

        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        return @{
            ExitCode = $proc.ExitCode
            Output   = $stdout.Trim()
            Error    = $stderr.Trim()
            Success  = ($proc.ExitCode -eq 0)
        }
    } catch {
        return @{
            ExitCode = -1
            Output   = ""
            Error    = $_.Exception.Message
            Success  = $false
        }
    }
}

# --- Helper: Build session args ---
function Get-SessionArgs {
    $args = ""
    if ($SessionName -ne "default") { $args += "--session-name `"$SessionName`" " }
    if ($Profile) { $args += "--profile `"$Profile`" " }
    return $args.Trim()
}

# --- Helper: Output result in standard format ---
function Write-Result($ok, $actionDesc, $data) {
    if ($ok) {
        Write-Output "OK|$actionDesc|$data"
    } else {
        Write-Output "ERROR|$actionDesc|$data"
    }
}

$sessionArg = Get-SessionArgs

switch ($Action) {
    "start" {
        $targetUrl = if ($Url) { $Url } else { "about:blank" }
        $r = Invoke-Browser "$sessionArg open `"$targetUrl`""
        if ($r.Success) {
            Write-Result $true "browser_started" $targetUrl
        } else {
            Write-Result $false "browser_start_failed" $r.Error
        }
    }

    "stop" {
        # agent-browser doesn't have an explicit stop; closing the daemon
        $r = Invoke-Browser "$sessionArg open about:blank"
        Write-Result $true "browser_stopped" "session closed"
    }

    "open" {
        if (-not $Url) {
            Write-Result $false "open_failed" "Url parameter is required"
            break
        }
        $r = Invoke-Browser "$sessionArg open `"$Url`""
        if ($r.Success) {
            # Wait for page to settle (2s default, or explicit wait)
            Invoke-Browser "$sessionArg wait 2000" | Out-Null
            Write-Result $true "navigated" $Url
        } else {
            Write-Result $false "navigate_failed" $r.Error
        }
    }

    "snapshot" {
        $snapArgs = "$sessionArg snapshot"
        if ($Detail) { $snapArgs += " -i" }
        $r = Invoke-Browser $snapArgs
        if ($r.Success) {
            Write-Output $r.Output
            Write-Result $true "snapshot_ok" "accessibility tree captured"
        } else {
            Write-Result $false "snapshot_failed" $r.Error
        }
    }

    "click" {
        if (-not $Target) {
            Write-Result $false "click_failed" "Target parameter is required (e.g. @e1 or #mybtn)"
            break
        }
        $r = Invoke-Browser "$sessionArg click `"$Target`""
        if ($r.Success) {
            Write-Result $true "clicked" $Target
        } else {
            Write-Result $false "click_failed|$Target" $r.Error
        }
    }

    "dblclick" {
        if (-not $Target) {
            Write-Result $false "dblclick_failed" "Target parameter is required"
            break
        }
        $r = Invoke-Browser "$sessionArg dblclick `"$Target`""
        if ($r.Success) {
            Write-Result $true "dblclicked" $Target
        } else {
            Write-Result $false "dblclick_failed|$Target" $r.Error
        }
    }

    "fill" {
        if (-not $Target -or -not $Text) {
            Write-Result $false "fill_failed" "Target and Text parameters are required"
            break
        }
        $r = Invoke-Browser "$sessionArg fill `"$Target`" `"$Text`""
        if ($r.Success) {
            Write-Result $true "filled" "$Target = `"$Text`""
        } else {
            Write-Result $false "fill_failed|$Target" $r.Error
        }
    }

    "type" {
        if (-not $Target -or -not $Text) {
            Write-Result $false "type_failed" "Target and Text parameters are required"
            break
        }
        $r = Invoke-Browser "$sessionArg type `"$Target`" `"$Text`""
        if ($r.Success) {
            Write-Result $true "typed" "$Target = `"$Text`""
        } else {
            Write-Result $false "type_failed|$Target" $r.Error
        }
    }

    "screenshot" {
        $ssPath = $Path
        if (-not $ssPath) {
            $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
            $ssPath = Join-Path $env:TEMP "browser_${timestamp}.png"
        }
        $ssArgs = "$sessionArg screenshot `"$ssPath`""
        if ($Annotate) { $ssArgs += " --annotate" }
        if ($FullPage) { $ssArgs += " --full" }
        $r = Invoke-Browser $ssArgs
        if ($r.Success -and (Test-Path $ssPath)) {
            Write-Result $true "screenshot_ok" $ssPath
        } else {
            Write-Result $false "screenshot_failed" ($r.Error + " " + $r.Output)
        }
    }

    "extract" {
        # Use snapshot for text extraction; can be extended with JS eval
        $r = Invoke-Browser "$sessionArg snapshot -i"
        if ($r.Success) {
            Write-Output $r.Output
            Write-Result $true "extract_ok" "page content extracted"
        } else {
            Write-Result $false "extract_failed" $r.Error
        }
    }

    "electron" {
        if (-not $App) {
            Write-Result $false "electron_failed" "App parameter is required (e.g. Slack, Code)"
            break
        }
        # agent-browser auto-connect discovers Electron apps via CDP
        $r = Invoke-Browser "--auto-connect snapshot"
        if ($r.Success) {
            Write-Result $true "electron_connected" $App
        } else {
            # Try loading electron skill
            $r2 = Invoke-Browser "skills get electron"
            Write-Result $false "electron_connect_failed" "Could not connect. Try loading electron skill: agent-browser skills get electron"
        }
    }

    "session" {
        $info = @{
            sessionName = $SessionName
            profile     = if ($Profile) { $Profile } else { "default" }
            binary      = $AGENT_BROWSER
        }
        Write-Result $true "session_info" ($info | ConvertTo-Json -Compress)
    }

    "wait" {
        if (-not $Target) {
            Write-Result $false "wait_failed" "Target parameter is required (ms or selector)"
            break
        }
        $r = Invoke-Browser "$sessionArg wait `"$Target`""
        if ($r.Success) {
            Write-Result $true "wait_done" $Target
        } else {
            Write-Result $false "wait_timeout|$Target" $r.Error
        }
    }

    "press" {
        if (-not $Key) {
            Write-Result $false "press_failed" "Key parameter is required"
            break
        }
        $r = Invoke-Browser "$sessionArg press `"$Key`""
        if ($r.Success) {
            Write-Result $true "pressed" $Key
        } else {
            Write-Result $false "press_failed|$Key" $r.Error
        }
    }

    "scroll" {
        $scrollArg = $Direction
        if ($Amount -ne 100) { $scrollArg += " $Amount" }
        $r = Invoke-Browser "$sessionArg scroll $scrollArg"
        if ($r.Success) {
            Write-Result $true "scrolled" "$Direction $Amount"
        } else {
            Write-Result $false "scroll_failed" $r.Error
        }
    }

    "hover" {
        if (-not $Target) {
            Write-Result $false "hover_failed" "Target parameter is required"
            break
        }
        $r = Invoke-Browser "$sessionArg hover `"$Target`""
        if ($r.Success) {
            Write-Result $true "hovered" $Target
        } else {
            Write-Result $false "hover_failed|$Target" $r.Error
        }
    }

    "select" {
        if (-not $Target -or -not $Text) {
            Write-Result $false "select_failed" "Target and Text parameters are required"
            break
        }
        $r = Invoke-Browser "$sessionArg select `"$Target`" `"$Text`""
        if ($r.Success) {
            Write-Result $true "selected" "$Target = `"$Text`""
        } else {
            Write-Result $false "select_failed|$Target" $r.Error
        }
    }
}
