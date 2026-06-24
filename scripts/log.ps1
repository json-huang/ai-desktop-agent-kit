# Desktop Control Operation Logger
# Records every desktop operation with structured JSON for audit + debugging
# Usage:
#   .\log.ps1 -Action log -Script "mouse.ps1" -Op "clickat" -Params @{X=500;Y=300} -Result "OK|clicked|500,300" -DurationMs 234
#   .\log.ps1 -Action query -Last 20
#   .\log.ps1 -Action query -Script "mouse" -Status "ERROR"
#   .\log.ps1 -Action query -Since "2026-06-22T10:00:00"
#   .\log.ps1 -Action summary
#   .\log.ps1 -Action stats -Script "screenshot"
#   .\log.ps1 -Action clear

param(
    [ValidateSet("log","query","summary","stats","clear")]
    [string]$Action = "query",

    # --- log ---
    [string]$Script = "",
    [string]$Op = "",
    [hashtable]$Params = @{},
    [string]$Result = "",
    [long]$DurationMs = 0,

    # --- query ---
    [int]$Last = 50,
    [string]$Status = "",      # OK / ERROR / NOTFOUND
    [string]$Since = "",       # ISO datetime
    [string]$Until = ""
)

$LogFile = "$env:USERPROFILE\.claude\logs\desktop_operations.jsonl"
$LogDir = Split-Path $LogFile -Parent

# Ensure log directory exists
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# ============================================================
# Action: log — append a new entry
# ============================================================
if ($Action -eq "log") {
    $status = "OK"
    if ($Result -match "^ERROR") { $status = "ERROR" }
    elseif ($Result -match "^NOTFOUND") { $status = "NOTFOUND" }

    $entry = [ordered]@{
        timestamp   = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fff")
        script      = $Script
        operation   = $Op
        params      = $Params
        result      = $Result
        status      = $status
        duration_ms = $DurationMs
    }

    $json = $entry | ConvertTo-Json -Compress -Depth 3
    Add-Content -Path $LogFile -Value $json -Encoding UTF8
    Write-Output "OK|logged|$($entry.script):$($entry.operation)|$status"
}

# ============================================================
# Action: query — read and filter log entries
# ============================================================
elseif ($Action -eq "query") {
    if (-not (Test-Path $LogFile)) {
        Write-Output "EMPTY|no log file yet"
        return
    }

    $lines = Get-Content $LogFile -Encoding UTF8
    if (-not $lines) {
        Write-Output "EMPTY|no entries"
        return
    }

    $entries = $lines | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ -ne $null }

    # Filter
    if ($Script) {
        $entries = $entries | Where-Object { $_.script -like "*$Script*" }
    }
    if ($Status) {
        $entries = $entries | Where-Object { $_.status -eq $Status }
    }
    if ($Since) {
        $sinceDate = [DateTime]::Parse($Since)
        $entries = $entries | Where-Object { [DateTime]$_.timestamp -ge $sinceDate }
    }
    if ($Until) {
        $untilDate = [DateTime]::Parse($Until)
        $entries = $entries | Where-Object { [DateTime]$_.timestamp -le $untilDate }
    }

    # Sort by timestamp descending, take last N (cast to avoid string sort)
    $entries = $entries | Sort-Object timestamp -Descending | Select-Object -First $Last

    if (-not $entries -or @($entries).Count -eq 0) {
        Write-Output "EMPTY|no matching entries"
        return
    }

    $entries | ForEach-Object {
        $pstr = ""
        if ($_.params -and $_.params.Count -gt 0) {
            $parts = @()
            foreach ($k in $_.params.Keys) {
                $parts += "$k=$($_.params[$k])"
            }
            $pstr = ($parts -join ',')
        }
        if ($pstr.Length -gt 60) { $pstr = $pstr.Substring(0, 57) + "..." }
        Write-Output "$($_.timestamp)|$($_.script):$($_.operation)|$($_.status)|$($_.duration_ms)ms|[$pstr]|$($_.result)"
    }
}

# ============================================================
# Action: summary — high-level overview of recent operations
# ============================================================
elseif ($Action -eq "summary") {
    if (-not (Test-Path $LogFile)) {
        Write-Output "EMPTY|no log file yet"
        return
    }

    $lines = Get-Content $LogFile -Encoding UTF8
    $entries = $lines | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ -ne $null }

    $total = @($entries).Count
    if ($total -eq 0) {
        Write-Output "EMPTY|no entries"
        return
    }

    $ok = ($entries | Where-Object { $_.status -eq "OK" }).Count
    $err = ($entries | Where-Object { $_.status -eq "ERROR" }).Count
    $nf = ($entries | Where-Object { $_.status -eq "NOTFOUND" }).Count

    # Time range
    $first = ($entries | Sort-Object timestamp | Select-Object -First 1).timestamp
    $last = ($entries | Sort-Object timestamp -Descending | Select-Object -First 1).timestamp

    # Per-script breakdown
    $byScript = $entries | Group-Object script | Sort-Object Count -Descending

    Write-Output "=== Operation Summary ==="
    Write-Output "Total: $total | OK: $ok | ERROR: $err | NOTFOUND: $nf"
    Write-Output "From: $first"
    Write-Output "To:   $last"
    Write-Output ""
    Write-Output "By Script:"
    $byScript | ForEach-Object {
        $okc = ($_.Group | Where-Object { $_.status -eq "OK" }).Count
        Write-Output "  $($_.Name): $($_.Count) ops ($okc OK)"
    }

    # Avg duration
    $durations = $entries | Where-Object { $_.duration_ms -gt 0 } | ForEach-Object { $_.duration_ms }
    if ($durations) {
        $avg = ($durations | Measure-Object -Average).Average
        Write-Output ""
        Write-Output "Avg Duration: $([math]::Round($avg, 0))ms"
    }

    # Recent errors
    $recentErrors = $entries | Where-Object { $_.status -eq "ERROR" } | Sort-Object timestamp -Descending | Select-Object -First 3
    if ($recentErrors) {
        Write-Output ""
        Write-Output "Recent Errors:"
        $recentErrors | ForEach-Object {
            Write-Output "  $($_.timestamp) | $($_.script):$($_.operation) | $($_.result)"
        }
    }
}

# ============================================================
# Action: stats — statistics for a specific script
# ============================================================
elseif ($Action -eq "stats") {
    if (-not (Test-Path $LogFile)) {
        Write-Output "EMPTY|no log file yet"
        return
    }

    $lines = Get-Content $LogFile -Encoding UTF8
    $entries = $lines | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null }
    } | Where-Object { $_ -ne $null }

    if ($Script) {
        $entries = $entries | Where-Object { $_.script -like "*$Script*" }
    }

    $total = @($entries).Count
    if ($total -eq 0) {
        Write-Output "EMPTY|no matching entries"
        return
    }

    $okRate = [math]::Round((($entries | Where-Object { $_.status -eq "OK" }).Count / $total) * 100, 1)

    # Average duration
    $durations = $entries | Where-Object { $_.duration_ms -gt 0 } | ForEach-Object { $_.duration_ms }
    $avgDur = if ($durations) { [math]::Round(($durations | Measure-Object -Average).Average, 0) } else { "N/A" }

    # Operations breakdown
    $byOp = $entries | Group-Object operation | Sort-Object Count -Descending

    Write-Output "=== Stats for: $($Script -replace '^$','ALL') ==="
    Write-Output "Total Ops: $total | Success Rate: ${okRate}% | Avg Duration: ${avgDur}ms"
    Write-Output ""
    Write-Output "By Operation:"
    $byOp | ForEach-Object {
        Write-Output "  $($_.Name): $($_.Count)"
    }
}

# ============================================================
# Action: clear — clear the log file
# ============================================================
elseif ($Action -eq "clear") {
    if (Test-Path $LogFile) {
        Remove-Item $LogFile -Force
        Write-Output "OK|log cleared"
    } else {
        Write-Output "OK|no log to clear"
    }
}
