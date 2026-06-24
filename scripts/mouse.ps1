# Mouse Control Script v2 — Win32 API (SendInput), DPI-safe
# Replaces deprecated mouse_event with SendInput
# Usage:
#   .\mouse.ps1 -Action move -X 100 -Y 200          # Move cursor
#   .\mouse.ps1 -Action click                        # Left click at current position
#   .\mouse.ps1 -Action rightclick                   # Right click at current position
#   .\mouse.ps1 -Action middleclick                  # Middle click at current position
#   .\mouse.ps1 -Action doubleclick                  # Double click at current position
#   .\mouse.ps1 -Action clickat -X 500 -Y 300        # Move and click
#   .\mouse.ps1 -Action drag -X 100 -Y 100 -ToX 500 -ToY 500
#   .\mouse.ps1 -Action scroll -Amount 120           # Scroll (positive=up)
#   .\mouse.ps1 -Action position                     # Get current position

param(
    [ValidateSet("move","click","rightclick","middleclick","doubleclick","clickat","drag","scroll","position")]
    [string]$Action = "position",
    [int]$X = 0,
    [int]$Y = 0,
    [int]$ToX = 0,
    [int]$ToY = 0,
    [int]$Amount = 120
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class MOUSE
{
    // --- Structs for SendInput ---
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public MOUSEINPUT mi;
    }

    // --- P/Invoke ---
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    // --- Flags ---
    public const uint INPUT_MOUSE       = 0;
    public const uint MOUSEEVENTF_MOVE      = 0x0001;
    public const uint MOUSEEVENTF_LEFTDOWN  = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP    = 0x0004;
    public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    public const uint MOUSEEVENTF_RIGHTUP   = 0x0010;
    public const uint MOUSEEVENTF_MIDDLEDOWN= 0x0020;
    public const uint MOUSEEVENTF_MIDDLEUP  = 0x0040;
    public const uint MOUSEEVENTF_WHEEL     = 0x0800;

    // --- Helper: send a single mouse input ---
    private static void SendMouseInput(uint flags, uint data)
    {
        INPUT[] inputs = new INPUT[1];
        inputs[0].type = INPUT_MOUSE;
        inputs[0].mi.dwFlags = flags;
        inputs[0].mi.mouseData = data;
        SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    // --- Public API ---
    public static void LeftDown()  { SendMouseInput(MOUSEEVENTF_LEFTDOWN, 0); }
    public static void LeftUp()    { SendMouseInput(MOUSEEVENTF_LEFTUP, 0); }
    public static void RightDown() { SendMouseInput(MOUSEEVENTF_RIGHTDOWN, 0); }
    public static void RightUp()   { SendMouseInput(MOUSEEVENTF_RIGHTUP, 0); }
    public static void MiddleDown(){ SendMouseInput(MOUSEEVENTF_MIDDLEDOWN, 0); }
    public static void MiddleUp()  { SendMouseInput(MOUSEEVENTF_MIDDLEUP, 0); }
    public static void Wheel(int amount) { SendMouseInput(MOUSEEVENTF_WHEEL, (uint)amount); }
}
'@

# --- Helper functions (keep SetCursorPos — it's not deprecated) ---

function Get-Pos {
    $p = New-Object MOUSE+POINT
    [MOUSE]::GetCursorPos([ref]$p) | Out-Null
    return @{X=$p.X; Y=$p.Y}
}

function Move-To($x, $y) {
    [MOUSE]::SetCursorPos($x, $y)
    Start-Sleep -Milliseconds 20
}

function Send-Click($downAction, $upAction) {
    & $downAction
    Start-Sleep -Milliseconds 15
    & $upAction
    Start-Sleep -Milliseconds 15
}

switch ($Action) {
    "position" {
        $p = Get-Pos
        Write-Output "$($p.X),$($p.Y)"
    }
    "move" {
        Move-To $X $Y
        $p = Get-Pos
        Write-Output "OK|moved|$($p.X),$($p.Y)"
    }
    "click" {
        Send-Click { [MOUSE]::LeftDown() } { [MOUSE]::LeftUp() }
        Write-Output "OK|clicked"
    }
    "rightclick" {
        Send-Click { [MOUSE]::RightDown() } { [MOUSE]::RightUp() }
        Write-Output "OK|rightclicked"
    }
    "middleclick" {
        Send-Click { [MOUSE]::MiddleDown() } { [MOUSE]::MiddleUp() }
        Write-Output "OK|middleclicked"
    }
    "doubleclick" {
        Send-Click { [MOUSE]::LeftDown() } { [MOUSE]::LeftUp() }
        Start-Sleep -Milliseconds 50
        Send-Click { [MOUSE]::LeftDown() } { [MOUSE]::LeftUp() }
        Write-Output "OK|doubleclicked"
    }
    "clickat" {
        Move-To $X $Y
        Send-Click { [MOUSE]::LeftDown() } { [MOUSE]::LeftUp() }
        Write-Output "OK|clicked|$X,$Y"
    }
    "drag" {
        Move-To $X $Y
        [MOUSE]::LeftDown()
        Start-Sleep -Milliseconds 30
        $steps = 20
        for ($i = 1; $i -le $steps; $i++) {
            $cx = $X + ($ToX - $X) * $i / $steps
            $cy = $Y + ($ToY - $Y) * $i / $steps
            Move-To $cx $cy
        }
        [MOUSE]::LeftUp()
        Write-Output "OK|dragged|$X,$Y->$ToX,$ToY"
    }
    "scroll" {
        [MOUSE]::Wheel($Amount)
        Write-Output "OK|scrolled|$Amount"
    }
}
