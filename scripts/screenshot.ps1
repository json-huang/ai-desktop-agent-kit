# DPI-Aware Screenshot Script v3
# Solves the "only top-left corner" problem on high-DPI (4K) displays
# Uses SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2) for mixed-DPI multi-monitor support
# Uses SM_XVIRTUALSCREEN(76), SM_YVIRTUALSCREEN(77), SM_CXVIRTUALSCREEN(78), SM_CYVIRTUALSCREEN(79)
# Win32 GDI32 BitBlt captures at physical pixel resolution across all monitors
#
# Usage:
#   .\screenshot.ps1                                    # Full screen → Desktop timestamped PNG
#   .\screenshot.ps1 -Path "C:\foo\bar.png"             # Full screen → specific path
#   .\screenshot.ps1 -Left 100 -Top 100 -W 500 -H 300   # Region capture
#   .\screenshot.ps1 -WindowTitle "记事本"               # Capture specific window
#   .\screenshot.ps1 -WindowTitle "记事本" -Path "C:\notepad.png"

param(
    [string]$Path = "$env:USERPROFILE\Desktop\screenshot_$(Get-Date -Format 'yyyyMMdd_HHmmss').png",
    [int]$Left = -1,
    [int]$Top = -1,
    [int]$Width = -1,
    [int]$Height = -1,
    [string]$WindowTitle = ""
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Text;

public class DpiAwareScreenshot
{
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(int dpiAwarenessContext);

    private const int DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4;

    [DllImport("user32.dll")]
    public static extern IntPtr GetDesktopWindow();

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindowDC(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateCompatibleDC(IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern IntPtr CreateCompatibleBitmap(IntPtr hDC, int nWidth, int nHeight);

    [DllImport("gdi32.dll")]
    public static extern IntPtr SelectObject(IntPtr hDC, IntPtr hObject);

    [DllImport("gdi32.dll")]
    public static extern bool BitBlt(IntPtr hDestDC, int x, int y, int nWidth, int nHeight, IntPtr hSrcDC, int xSrc, int ySrc, int dwRop);

    [DllImport("gdi32.dll")]
    public static extern bool StretchBlt(IntPtr hDestDC, int x, int y, int nWidth, int nHeight, IntPtr hSrcDC, int xSrc, int ySrc, int nSrcWidth, int nSrcHeight, int dwRop);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteDC(IntPtr hDC);

    [DllImport("gdi32.dll")]
    public static extern bool DeleteObject(IntPtr hObject);

    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int nIndex);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWinProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hDC, uint nFlags);

    public delegate bool EnumWinProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    // CaptureParams: the region to capture (set by caller)
    public struct CaptureParams
    {
        public int Left;
        public int Top;
        public int Width;
        public int Height;
    }

    /// Find a visible window whose title contains partialTitle
    public static IntPtr FindWindowByTitle(string partialTitle)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) => {
            if (IsWindowVisible(h)) {
                int len = GetWindowTextLength(h);
                if (len > 0) {
                    var sb = new StringBuilder(len + 1);
                    GetWindowText(h, sb, sb.Capacity);
                    if (sb.ToString().Contains(partialTitle)) {
                        found = h;
                        return false; // stop enumeration
                    }
                }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    /// Get the bounding rectangle of a window (DPI-aware)
    public static bool GetWindowBounds(IntPtr hWnd, out int left, out int top, out int width, out int height)
    {
        RECT r;
        bool ok = GetWindowRect(hWnd, out r);
        left = r.Left;
        top = r.Top;
        width = r.Right - r.Left;
        height = r.Bottom - r.Top;
        return ok;
    }

    /// Full desktop capture across all monitors (PerMonitorV2 DPI-aware)
    public static Bitmap Capture()
    {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        int x = GetSystemMetrics(76);  // SM_XVIRTUALSCREEN
        int y = GetSystemMetrics(77);  // SM_YVIRTUALSCREEN
        int w = GetSystemMetrics(78);  // SM_CXVIRTUALSCREEN
        int h = GetSystemMetrics(79);  // SM_CYVIRTUALSCREEN
        return CaptureRegion(x, y, w, h);
    }

    /// Capture a specific region of the desktop (PerMonitorV2 DPI-aware)
    public static Bitmap CaptureRegion(int srcLeft, int srcTop, int srcWidth, int srcHeight)
    {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        IntPtr hDesktop = GetDesktopWindow();
        IntPtr hDesktopDC = GetWindowDC(hDesktop);
        IntPtr hMemDC = CreateCompatibleDC(hDesktopDC);
        IntPtr hBitmap = CreateCompatibleBitmap(hDesktopDC, srcWidth, srcHeight);
        IntPtr hOldBitmap = SelectObject(hMemDC, hBitmap);
        BitBlt(hMemDC, 0, 0, srcWidth, srcHeight, hDesktopDC, srcLeft, srcTop, 0x00CC0020); // SRCCOPY
        Bitmap bmp = Image.FromHbitmap(hBitmap);
        SelectObject(hMemDC, hOldBitmap);
        DeleteObject(hBitmap);
        DeleteDC(hMemDC);
        ReleaseDC(hDesktop, hDesktopDC);
        return bmp;
    }
}
'@ -ReferencedAssemblies System.Drawing

try {
    # Resolve capture mode: Window > Region > Full-screen
    if ($WindowTitle) {
        # --- Window capture ---
        $hwnd = [DpiAwareScreenshot]::FindWindowByTitle($WindowTitle)
        if ($hwnd -eq [IntPtr]::Zero) {
            Write-Output "ERROR|window not found: $WindowTitle"
            exit 1
        }
        $left = 0; $top = 0; $w = 0; $h = 0
        [DpiAwareScreenshot]::GetWindowBounds($hwnd, [ref]$left, [ref]$top, [ref]$w, [ref]$h)
        if ($w -le 0 -or $h -le 0) {
            Write-Output "ERROR|window has zero size: $WindowTitle"
            exit 1
        }
        $bmp = [DpiAwareScreenshot]::CaptureRegion($left, $top, $w, $h)
    }
    elseif ($Left -ge 0 -and $Top -ge 0 -and $Width -gt 0 -and $Height -gt 0) {
        # --- Region capture ---
        $bmp = [DpiAwareScreenshot]::CaptureRegion($Left, $Top, $Width, $Height)
    }
    else {
        # --- Full-screen capture ---
        $bmp = [DpiAwareScreenshot]::Capture()
    }

    # Ensure output directory exists
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $w = $bmp.Width; $h = $bmp.Height
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    $file = Get-Item $Path
    Write-Output "OK|$($file.FullName)|${w}x${h}|$([math]::Round($file.Length/1KB, 1))KB"
} catch {
    Write-Output "ERROR|$_"
}
