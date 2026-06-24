# System Control Script
# Usage:
#   .\system.ps1 -Action launch -Target "notepad"           # Launch app
#   .\system.ps1 -Action launch -Target "notepad" -Args "file.txt"
#   .\system.ps1 -Action kill -Target "notepad"              # Kill process by name
#   .\system.ps1 -Action killpid -ProcessId 1234              # Kill process by PID
#   .\system.ps1 -Action info                                # System info summary
#   .\system.ps1 -Action processes                           # Top CPU processes
#   .\system.ps1 -Action clipboard                           # Get clipboard text
#   .\system.ps1 -Action setclip -Text "hello"               # Set clipboard text

param(
    [ValidateSet("launch","kill","killpid","info","processes","clipboard","setclip")]
    [string]$Action = "info",
    [string]$Target = "",
    [string]$Args = "",
    [int]$ProcessId = 0,
    [string]$Text = ""
)

switch ($Action) {
    "launch" {
        try {
            if ($Args) {
                $proc = Start-Process $Target -ArgumentList $Args -PassThru
            } else {
                $proc = Start-Process $Target -PassThru
            }
            Start-Sleep -Milliseconds 500
            $alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
            Write-Output "OK|launched|$Target|PID=$($proc.Id)|alive=$($alive -ne $null)"
        } catch {
            Write-Output "ERROR|launch|$Target|$_"
        }
    }
    "kill" {
        try {
            $procs = Get-Process $Target -ErrorAction SilentlyContinue
            if (-not $procs) { Write-Output "NOTFOUND|$Target"; break }
            $procs | ForEach-Object { Stop-Process -Id $_.Id -Force; Write-Output "OK|killed|$($_.ProcessName)|PID=$($_.Id)" }
        } catch {
            Write-Output "ERROR|kill|$Target|$_"
        }
    }
    "killpid" {
        try {
            $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
            if (-not $proc) { Write-Output "NOTFOUND|PID=$ProcessId"; break }
            Stop-Process -Id $ProcessId -Force
            Write-Output "OK|killed|$($proc.ProcessName)|PID=$ProcessId"
        } catch {
            Write-Output "ERROR|killpid|$_"
        }
    }
    "info" {
        $os = Get-CimInstance Win32_OperatingSystem
        $cpu = Get-CimInstance Win32_Processor
        $mem = Get-CimInstance Win32_ComputerSystem
        $gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
        Write-Output "OS=$($os.Caption)"
        Write-Output "CPU=$($cpu.Name.Trim())"
        Write-Output "Cores=$($cpu.NumberOfCores) Logical=$($cpu.NumberOfLogicalProcessors)"
        Write-Output "RAM=$([math]::Round($mem.TotalPhysicalMemory/1GB,1))GB"
        Write-Output "GPU=$($gpu.Name)"
        Write-Output "Screen=$([math]::Round(($gpu.CurrentHorizontalResolution)))x$([math]::Round(($gpu.CurrentVerticalResolution)))"
    }
    "processes" {
        Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 | ForEach-Object {
            Write-Output "$($_.Id)|$($_.ProcessName)|CPU=$([math]::Round($_.CPU,1))s|MEM=$([math]::Round($_.WorkingSet64/1MB,1))MB"
        }
    }
    "clipboard" {
        Add-Type -AssemblyName System.Windows.Forms
        Write-Output ([System.Windows.Forms.Clipboard]::GetText())
    }
    "setclip" {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Clipboard]::SetText($Text)
        Write-Output "OK|clipboard set|$Text"
    }
}
