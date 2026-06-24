# UIA Perception Tier — Windows UI Automation tree walker
# Walks the UIA tree of a target window and outputs structured element descriptors.
# Uses System.Windows.Automation (managed .NET) for fast, free element detection.
#
# Usage:
#   .\uia.ps1                                          # Dump UIA tree of foreground window
#   .\uia.ps1 -WindowTitle "记事本"                      # Dump UIA tree of Notepad
#   .\uia.ps1 -WindowTitle "Chrome" -MaxElements 200     # Limit to 200 elements
#   .\uia.ps1 -WindowTitle "记事本" -OutputPath "uia.json" # Export to JSON
#   .\uia.ps1 -MaxDepth 10 -TimeoutMs 3000               # Shallow/fast walk

param(
    [string]$WindowTitle = "",      # Window title substring to target (empty = foreground window)
    [int]$TimeoutMs = 5000,         # Max tree walk time (ms)
    [int]$MaxDepth = 20,            # Max tree depth
    [int]$MaxElements = 500,        # Max elements to return
    [string]$OutputPath = ""        # If set, write JSON to this path
)

# ============================================================
# Step 1: Compile UIA helper DLL (cached)
# ============================================================
$uiaDll = "$env:TEMP\UiaHelper_v1.dll"

if (-not (Test-Path $uiaDll)) {
    $csSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;

namespace UiaTool
{
    public struct UiaElement
    {
        public string Type;           // ControlType.ProgrammaticName, e.g. "ControlType.Button"
        public string Name;           // element name/label
        public string AutomationId;
        public string ClassName;
        public int Left, Top, Width, Height;  // BoundingRectangle in physical pixels
        public bool IsEnabled;
        public bool IsOffscreen;
        public bool HasKeyboardFocus;
        public int ProcessId;
        public int Depth;             // tree depth (0 = root)
        public int ParentIndex;       // index of parent in list (-1 = root)
        public double Confidence;     // 0.99 for UIA source
    }

    public class UiaHelper
    {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        public static extern bool SetProcessDpiAwarenessContext(int dpiAwarenessContext);

        [DllImport("user32.dll")]
        public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

        [DllImport("user32.dll")]
        public static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll")]
        public static extern bool EnumWindows(EnumWinProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll")]
        public static extern bool IsWindowVisible(IntPtr hWnd);

        public delegate bool EnumWinProc(IntPtr hWnd, IntPtr lParam);

        private const int DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = -4;

        private static List<UiaElement> _results;
        private static Stopwatch _stopwatch;
        private static int _maxDepth;
        private static int _maxElements;
        private static int _timeoutMs;
        private static bool _timedOut;

        /// Find a visible window whose title contains partialTitle
        public static IntPtr FindWindowByTitle(string partialTitle)
        {
            IntPtr found = IntPtr.Zero;
            EnumWindows((h, l) => {
                if (IsWindowVisible(h))
                {
                    int len = GetWindowTextLength(h);
                    if (len > 0)
                    {
                        var sb = new StringBuilder(len + 1);
                        GetWindowText(h, sb, sb.Capacity);
                        if (sb.ToString().Contains(partialTitle))
                        {
                            found = h;
                            return false; // stop enumeration
                        }
                    }
                }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        /// Walk the UIA tree from a given root element
        private static void WalkTree(AutomationElement element, int depth, int parentIndex)
        {
            if (_timedOut) return;
            if (_stopwatch.ElapsedMilliseconds > _timeoutMs)
            {
                _timedOut = true;
                return;
            }
            if (depth > _maxDepth) return;
            if (_results.Count >= _maxElements) return;

            int myIndex = -1;
            try
            {
                var current = element.Current;
                var rect = current.BoundingRectangle;

                // Filter: skip offscreen elements and empty rectangles
                if (!current.IsOffscreen && !rect.IsEmpty)
                {
                    myIndex = _results.Count;
                    _results.Add(new UiaElement
                    {
                        Type = current.ControlType != null ? current.ControlType.ProgrammaticName : "ControlType.Unknown",
                        Name = current.Name ?? "",
                        AutomationId = current.AutomationId ?? "",
                        ClassName = current.ClassName ?? "",
                        Left = (int)rect.Left,
                        Top = (int)rect.Top,
                        Width = (int)rect.Width,
                        Height = (int)rect.Height,
                        IsEnabled = current.IsEnabled,
                        IsOffscreen = current.IsOffscreen,
                        HasKeyboardFocus = current.HasKeyboardFocus,
                        ProcessId = current.ProcessId,
                        Depth = depth,
                        ParentIndex = parentIndex,
                        Confidence = 0.99
                    });

                    if (_results.Count >= _maxElements) return;
                }
            }
            catch (ElementNotAvailableException)
            {
                // Element was destroyed between enumeration and property access — skip it
                return;
            }

            // Walk children using ControlViewWalker
            try
            {
                var walker = TreeWalker.ControlViewWalker;
                var child = walker.GetFirstChild(element);
                while (child != null)
                {
                    if (_timedOut) return;
                    if (_stopwatch.ElapsedMilliseconds > _timeoutMs)
                    {
                        _timedOut = true;
                        return;
                    }
                    if (_results.Count >= _maxElements) return;

                    WalkTree(child, depth + 1, myIndex);

                    try
                    {
                        child = walker.GetNextSibling(child);
                    }
                    catch (ElementNotAvailableException)
                    {
                        break; // sibling no longer available
                    }
                }
            }
            catch (ElementNotAvailableException)
            {
                // Root element no longer available
            }
        }

        /// Get UIA elements for a given window handle
        public static List<UiaElement> GetElements(IntPtr hwnd, int timeoutMs, int maxDepth, int maxElements)
        {
            SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

            _results = new List<UiaElement>();
            _stopwatch = Stopwatch.StartNew();
            _maxDepth = maxDepth;
            _maxElements = maxElements;
            _timeoutMs = timeoutMs;
            _timedOut = false;

            try
            {
                AutomationElement root = AutomationElement.FromHandle(hwnd);
                if (root != null)
                {
                    WalkTree(root, 0, -1);
                }
            }
            catch (Exception)
            {
                // Window may have been closed or is not UIA-accessible
            }
            finally
            {
                _stopwatch.Stop();
            }

            return _results;
        }
    }
}
'@

    $csFile = "$env:TEMP\_uia_helper.cs"
    Set-Content -Path $csFile -Value $csSource -Encoding UTF8

    # Find csc.exe
    $csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    }

    # UIA assembly paths from GAC
    $gacBase = "$env:SystemRoot\Microsoft.NET\assembly\GAC_MSIL"
    $uiaClient = "$gacBase\UIAutomationClient\v4.0_4.0.0.0__31bf3856ad364e35\UIAutomationClient.dll"
    $uiaTypes = "$gacBase\UIAutomationTypes\v4.0_4.0.0.0__31bf3856ad364e35\UIAutomationTypes.dll"
    $windowsBase = "$gacBase\WindowsBase\v4.0_4.0.0.0__31bf3856ad364e35\WindowsBase.dll"

    $args = @(
        "/target:library",
        "/out:$uiaDll",
        "/nologo",
        "/optimize",
        "/nowarn:168,1701,1702",
        "/r:$uiaClient",
        "/r:$uiaTypes",
        "/r:$windowsBase"
    ) + @($csFile)

    $result = & $csc $args 2>&1
    Remove-Item $csFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $uiaDll)) {
        Write-Output "ERROR|UIA compilation failed."
        Write-Output "ERROR|Compiler output: $result"
        Write-Output "ERROR|Ensure .NET Framework 4.8 is installed."
        exit 1
    }
}

# ============================================================
# Step 2: Load DLL
# ============================================================
Add-Type -Path $uiaDll

# ============================================================
# Step 3: PowerShell wrapper function
# ============================================================
function Get-UiaElements {
    param(
        [string]$WindowTitle = "",
        [int]$TimeoutMs = 5000,
        [int]$MaxDepth = 20,
        [int]$MaxElements = 500,
        [string]$OutputPath = ""
    )

    # Resolve window handle
    if ($WindowTitle) {
        $hwnd = [UiaTool.UiaHelper]::FindWindowByTitle($WindowTitle)
        if ($hwnd -eq [IntPtr]::Zero) {
            Write-Output "ERROR|window not found: $WindowTitle"
            return
        }
    }
    else {
        $hwnd = [UiaTool.UiaHelper]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) {
            Write-Output "ERROR|no foreground window"
            return
        }
    }

    # Run UIA tree walk
    $elements = [UiaTool.UiaHelper]::GetElements($hwnd, $TimeoutMs, $MaxDepth, $MaxElements)

    if ($OutputPath) {
        $elements | ConvertTo-Json -Depth ($MaxDepth + 2) | Set-Content -Path $OutputPath -Encoding UTF8
        Write-Output "OK|exported to $OutputPath|$($elements.Count) elements"
    }

    # Return elements as pipeline objects
    $elements
}

# ============================================================
# Step 4: Execute when run as script (NOT when dot-sourced)
# ============================================================
if ($MyInvocation.InvocationName -ne '.') {
try {
    $elements = Get-UiaElements -WindowTitle $WindowTitle -TimeoutMs $TimeoutMs -MaxDepth $MaxDepth -MaxElements $MaxElements

    if (-not $OutputPath) {
        foreach ($el in $elements) {
            $line = "ELEMENT|$($el.Type)|$($el.Name)|$($el.Left),$($el.Top),$($el.Width),$($el.Height)|Enabled=$($el.IsEnabled)|Confidence=$($el.Confidence)"
            Write-Output $line
        }
    }

    Write-Output "OK|$($elements.Count) elements found"
}
catch {
    Write-Output "ERROR|$_"
}
}
