# Window Management Script - Win32 API
# Usage:
#   .\window.ps1 -Action list                              # List all visible windows
#   .\window.ps1 -Action find -Title "记事本"               # Find window by title
#   .\window.ps1 -Action focus -Title "Chrome"              # Focus window
#   .\window.ps1 -Action move -Title "记事本" -X 0 -Y 0     # Move window
#   .\window.ps1 -Action resize -Title "记事本" -W 800 -H 600  # Resize window
#   .\window.ps1 -Action info                               # Info about foreground window

param(
    [ValidateSet("list","find","focus","move","resize","info")]
    [string]$Action = "list",
    [string]$Title = "",
    [int]$X = -1,
    [int]$Y = -1,
    [int]$W = -1,
    [int]$H = -1
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Collections.Generic;
public class WIN {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWinProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    public delegate bool EnumWinProc(IntPtr hWnd, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public static IntPtr HWND_TOP = IntPtr.Zero;
    public const uint SWP_NOSIZE = 0x0001, SWP_NOMOVE = 0x0002, SWP_SHOWWINDOW = 0x0040;
    public const int SW_RESTORE = 9;
    public static List<WINFO> GetWindows() {
        var list = new List<WINFO>();
        EnumWindows((h,l) => { if (IsWindowVisible(h)) { int len = GetWindowTextLength(h); if (len>0) { var sb = new StringBuilder(len+1); GetWindowText(h,sb,sb.Capacity); RECT r; GetWindowRect(h,out r); list.Add(new WINFO{Handle=h,Title=sb.ToString(),Rect=r}); } } return true; }, IntPtr.Zero);
        return list;
    }
    public static IntPtr FindWin(string partialTitle) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h,l) => { if (IsWindowVisible(h)) { int len = GetWindowTextLength(h); if (len>0) { var sb = new StringBuilder(len+1); GetWindowText(h,sb,sb.Capacity); if (sb.ToString().Contains(partialTitle)) { found = h; return false; } } } return true; }, IntPtr.Zero);
        return found;
    }
}
public class WINFO { public IntPtr Handle; public string Title; public WIN.RECT Rect; }
'@

switch ($Action) {
    "list" {
        $wins = [WIN]::GetWindows()
        $wins | ForEach-Object {
            $w = $_.Rect.Right - $_.Rect.Left
            $h = $_.Rect.Bottom - $_.Rect.Top
            Write-Output "$($_.Handle)|$($_.Title)|$($_.Rect.Left),$($_.Rect.Top)|${w}x${h}"
        }
    }
    "info" {
        $hwnd = [WIN]::GetForegroundWindow()
        $sb = New-Object System.Text.StringBuilder(256)
        [WIN]::GetWindowText($hwnd, $sb, 256) | Out-Null
        $r = New-Object WIN+RECT
        [WIN]::GetWindowRect($hwnd, [ref]$r) | Out-Null
        $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
        Write-Output "OK|$($sb.ToString())|$hwnd|$($r.Left),$($r.Top)|${w}x${h}"
    }
    "find" {
        $hwnd = [WIN]::FindWin($Title)
        if ($hwnd -ne [IntPtr]::Zero) {
            $sb = New-Object System.Text.StringBuilder(256)
            [WIN]::GetWindowText($hwnd, $sb, 256) | Out-Null
            Write-Output "OK|$($sb.ToString())|$hwnd"
        } else {
            Write-Output "NOTFOUND|$Title"
        }
    }
    "focus" {
        $hwnd = [WIN]::FindWin($Title)
        if ($hwnd -eq [IntPtr]::Zero) { Write-Output "NOTFOUND|$Title"; break }
        if ([WIN]::IsIconic($hwnd)) { [WIN]::ShowWindow($hwnd, [WIN]::SW_RESTORE) | Out-Null }
        [WIN]::SetForegroundWindow($hwnd) | Out-Null
        Start-Sleep -Milliseconds 200
        Write-Output "OK|focused|$Title"
    }
    "move" {
        $hwnd = if ($Title) { [WIN]::FindWin($Title) } else { [WIN]::GetForegroundWindow() }
        if ($hwnd -eq [IntPtr]::Zero) { Write-Output "NOTFOUND|$Title"; break }
        [WIN]::SetWindowPos($hwnd, [WIN]::HWND_TOP, $X, $Y, 0, 0, [WIN]::SWP_NOSIZE -bor [WIN]::SWP_SHOWWINDOW) | Out-Null
        Write-Output "OK|moved|$Title|$X,$Y"
    }
    "resize" {
        $hwnd = if ($Title) { [WIN]::FindWin($Title) } else { [WIN]::GetForegroundWindow() }
        if ($hwnd -eq [IntPtr]::Zero) { Write-Output "NOTFOUND|$Title"; break }
        if ($X -ge 0 -and $Y -ge 0) {
            [WIN]::MoveWindow($hwnd, $X, $Y, $W, $H, $true) | Out-Null
        } else {
            [WIN]::SetWindowPos($hwnd, [WIN]::HWND_TOP, 0, 0, $W, $H, [WIN]::SWP_NOMOVE -bor [WIN]::SWP_SHOWWINDOW) | Out-Null
        }
        Write-Output "OK|resized|$Title|${W}x${H}"
    }
}
