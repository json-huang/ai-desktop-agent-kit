# Visual Diff / Operation Verification Script
# Compares two screenshots (before/after) and reports changes
# Usage:
#   .\verify.ps1 -Before "before.png" -After "after.png"
#   .\verify.ps1 -Before "before.png" -After "after.png" -Diff "diff.png"    # Also save diff image
#   .\verify.ps1 -Before "before.png" -After "after.png" -Threshold 30        # Min pixel change threshold (0-255)
#   .\verify.ps1 -Capture -Action { Start-Process notepad }                   # Auto capture before+after

param(
    [string]$Before = "",
    [string]$After = "",
    [string]$Diff = "",                # Output diff image path (optional)
    [int]$Threshold = 20,             # Pixel change threshold (0–255), filters noise
    [switch]$Capture,                 # Auto-capture before/after mode
    [scriptblock]$Action = $null      # Action to perform between captures (for -Capture mode)
)

Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class VisualDiff
{
    public struct DiffRect
    {
        public int Left, Top, Right, Bottom;
        public int Area() { return (Right - Left) * (Bottom - Top); }
    }

    public struct DiffResult
    {
        public int ChangedPixels;        // Pixels that differ above threshold
        public int TotalPixels;
        public float ChangePercent;
        public List<DiffRect> ChangedRegions;
        public string DiffImagePath;
    }

    /// Compare two images pixel by pixel, return changed regions
    public static DiffResult Compare(string beforePath, string afterPath,
        int threshold, string diffOutputPath)
    {
        using (Bitmap before = new Bitmap(beforePath))
        using (Bitmap after = new Bitmap(afterPath))
        {
            int w = Math.Min(before.Width, after.Width);
            int h = Math.Min(before.Height, after.Height);
            int total = w * h;

            bool[] changed = new bool[total]; // flat array for clustering
            Bitmap diffBmp = null;
            BitmapData diffData = null;
            byte[] diffBytes = null;
            int diffStride = 0;

            if (!string.IsNullOrEmpty(diffOutputPath))
            {
                diffBmp = new Bitmap(w, h, PixelFormat.Format24bppRgb);
            }

            // Lock all three bitmaps
            BitmapData beforeData = before.LockBits(
                new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
            BitmapData afterData = after.LockBits(
                new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);

            int stride = beforeData.Stride;
            byte[] beforeBytes = new byte[stride * h];
            byte[] afterBytes = new byte[stride * h];
            Marshal.Copy(beforeData.Scan0, beforeBytes, 0, beforeBytes.Length);
            Marshal.Copy(afterData.Scan0, afterBytes, 0, afterBytes.Length);

            if (diffBmp != null)
            {
                diffData = diffBmp.LockBits(
                    new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
                diffStride = diffData.Stride;
                diffBytes = new byte[diffStride * h];
                // Initialize diff image as dark (unchanged areas will be dimmed before)
                for (int y = 0; y < h; y++)
                {
                    int rowOff = y * diffStride;
                    int srcRowOff = y * stride;
                    for (int x = 0; x < w; x++)
                    {
                        int si = srcRowOff + x * 3;
                        int di = rowOff + x * 3;
                        diffBytes[di] = (byte)(beforeBytes[si] / 3);       // B
                        diffBytes[di + 1] = (byte)(beforeBytes[si + 1] / 3); // G - dimmed
                        diffBytes[di + 2] = (byte)(beforeBytes[si + 2] / 3); // R
                    }
                }
            }

            int changedCount = 0;
            for (int y = 0; y < h; y++)
            {
                int rowOff = y * stride;
                int dRowOff = y * diffStride;
                for (int x = 0; x < w; x++)
                {
                    int idx = rowOff + x * 3;
                    int b = Math.Abs(beforeBytes[idx] - afterBytes[idx]);
                    int g = Math.Abs(beforeBytes[idx + 1] - afterBytes[idx + 1]);
                    int r = Math.Abs(beforeBytes[idx + 2] - afterBytes[idx + 2]);
                    int maxDiff = Math.Max(b, Math.Max(g, r));

                    if (maxDiff > threshold)
                    {
                        changed[y * w + x] = true;
                        changedCount++;

                        if (diffBytes != null)
                        {
                            int di = dRowOff + x * 3;
                            diffBytes[di] = 0;                          // B
                            diffBytes[di + 1] = 0;                      // G - bright red highlight
                            diffBytes[di + 2] = 255;                    // R
                        }
                    }
                }
            }

            before.UnlockBits(beforeData);
            after.UnlockBits(afterData);

            if (diffBmp != null)
            {
                Marshal.Copy(diffBytes, 0, diffData.Scan0, diffBytes.Length);
                diffBmp.UnlockBits(diffData);
                diffBmp.Save(diffOutputPath, ImageFormat.Png);
                diffBmp.Dispose();
            }

            // Cluster changed pixels into bounding rectangles (simple dilation + connected components)
            var regions = ClusterRegions(changed, w, h, 10);

            return new DiffResult
            {
                ChangedPixels = changedCount,
                TotalPixels = total,
                ChangePercent = (float)changedCount / total * 100f,
                ChangedRegions = regions,
                DiffImagePath = diffOutputPath ?? ""
            };
        }
    }

    /// Simple clustering: find bounding boxes of connected changed regions
    private static List<DiffRect> ClusterRegions(bool[] changed, int w, int h, int gapTolerance)
    {
        var regions = new List<DiffRect>();
        bool[] visited = new bool[changed.Length];

        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                int idx = y * w + x;
                if (changed[idx] && !visited[idx])
                {
                    // Flood fill to find connected component
                    int minX = x, maxX = x, minY = y, maxY = y;
                    var stack = new Stack<Point>();
                    stack.Push(new Point(x, y));
                    visited[idx] = true;

                    while (stack.Count > 0)
                    {
                        Point p = stack.Pop();
                        if (p.X < minX) minX = p.X;
                        if (p.X > maxX) maxX = p.X;
                        if (p.Y < minY) minY = p.Y;
                        if (p.Y > maxY) maxY = p.Y;

                        // Check 8-connected neighbors
                        for (int dy = -1; dy <= 1; dy++)
                        {
                            for (int dx = -1; dx <= 1; dx++)
                            {
                                if (dx == 0 && dy == 0) continue;
                                int nx = p.X + dx, ny = p.Y + dy;
                                if (nx >= 0 && nx < w && ny >= 0 && ny < h)
                                {
                                    int ni = ny * w + nx;
                                    if (changed[ni] && !visited[ni])
                                    {
                                        visited[ni] = true;
                                        stack.Push(new Point(nx, ny));
                                    }
                                }
                            }
                        }
                    }

                    // Expand by gap tolerance
                    regions.Add(new DiffRect
                    {
                        Left = Math.Max(0, minX - gapTolerance),
                        Top = Math.Max(0, minY - gapTolerance),
                        Right = Math.Min(w, maxX + gapTolerance + 1),
                        Bottom = Math.Min(h, maxY + gapTolerance + 1)
                    });
                }
            }
        }

        // Sort by area descending, keep top 20
        regions.Sort((a, b) => b.Area().CompareTo(a.Area()));
        if (regions.Count > 20)
            regions.RemoveRange(20, regions.Count - 20);

        return regions;
    }

    private struct Point { public int X, Y; public Point(int x, int y) { X = x; Y = y; } }
}
'@ -ReferencedAssemblies System.Drawing

# ============================================================
# Internal helper functions (mocked in tests)
# ============================================================
function _InvokeScreenshot { param($Path) & "$PSScriptRoot\screenshot.ps1" -Path $Path }
function _InvokeOcr {
    param($Image, [switch]$Detailed)
    if ($Detailed) {
        & "$PSScriptRoot\ocr.ps1" -Image $Image -Detail
    } else {
        & "$PSScriptRoot\ocr.ps1" -Image $Image
    }
}
function _InvokeUia { & "$PSScriptRoot\uia.ps1" }
function _InvokeWindow { param($Action) & "$PSScriptRoot\window.ps1" -Action $Action }
function _InvokePixelDiff { param($Before, $After) [VisualDiff]::Compare($Before, $After, 20, "") }

# ============================================================
# Multi-Modal Step Verification
# Combines pixel diff + OCR + UIA + negative checks into a
# weighted verdict: SUCCESS | FAILURE | UNCERTAIN
# ============================================================
function Invoke-StepVerification {
    param(
        [Parameter(Mandatory=$true)]
        [string]$BeforeScreenshot,

        [Parameter(Mandatory=$true)]
        [hashtable]$ExpectedOutcome,

        [Parameter(Mandatory=$true)]
        [string]$OutputDir
    )

    # Ensure output directory exists
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # Initialize scores with neutral defaults
    $scores = @{
        pixel_diff = 0.5
        ocr        = 0.5
        uia_state  = 0.5
        negative   = $true   # $true = no errors found
    }

    # --- 1. Capture post-action screenshot ---
    $afterPath = Join-Path $OutputDir "verify_after_$(Get-Date -Format 'HHmmss').png"
    try {
        $captureResult = _InvokeScreenshot -Path $afterPath
        if ($captureResult -match 'OK\|([^|]+)\|') {
            $afterPath = $matches[1]
        }
    }
    catch {
        Write-Host "VERIFY|ERROR|screenshot capture failed: $_"
        return "FAILURE"
    }

    if (-not (Test-Path $afterPath)) {
        Write-Host "VERIFY|ERROR|post-action screenshot not found: $afterPath"
        return "FAILURE"
    }

    # --- 2. Pixel diff check ---
    try {
        $diffResult = _InvokePixelDiff -Before $BeforeScreenshot -After $afterPath
        $changePct = $diffResult.ChangePercent
        if ($changePct -gt 2.0 -and $changePct -lt 80.0) {
            $scores.pixel_diff = [Math]::Min(1.0, $changePct / 10.0)
        }
        elseif ($changePct -le 2.0) {
            $scores.pixel_diff = 0.2
        }
        else {
            $scores.pixel_diff = 0.3
        }
    }
    catch {
        # Pixel diff failed -- keep neutral score
    }

    # --- 3. OCR text confirmation ---
    $expectedTexts = @()
    if ($ExpectedOutcome.ContainsKey('ocr_check') -and $ExpectedOutcome.ocr_check) {
        $expectedTexts = $ExpectedOutcome.ocr_check -split '\s*,\s*' | Where-Object { $_ }
    }

    $ocrOutput = ""
    if ($expectedTexts.Count -gt 0) {
        try {
            $ocrOutput = _InvokeOcr -Image $afterPath -Detailed
            $foundCount = 0
            foreach ($expected in $expectedTexts) {
                $escaped = [regex]::Escape($expected.Trim())
                if ($ocrOutput -match $escaped) {
                    $foundCount++
                }
            }
            $scores.ocr = $foundCount / $expectedTexts.Count
        }
        catch {
            $scores.ocr = 0.0
        }
    }

    # --- 4. UIA element state check ---
    if ($ExpectedOutcome.ContainsKey('ui_state') -and $ExpectedOutcome.ui_state) {
        try {
            $uiaOutput = _InvokeUia
            $uiaOutputString = ($uiaOutput | Out-String)
            if ($uiaOutputString -match [regex]::Escape($ExpectedOutcome.ui_state)) {
                $scores.uia_state = 1.0
            }
            else {
                $scores.uia_state = 0.0
            }
        }
        catch {
            $scores.uia_state = 0.0
        }
    }

    # --- 5. Negative verification ---
    if ($ExpectedOutcome.ContainsKey('negative_check') -and $ExpectedOutcome.negative_check) {
        $errorPatterns = @("Error", "Failed", "denied", "cannot", "Unable to", "not responding", "Access denied", "permission")
        $windowErrorPatterns = @("Error", "Warning", "Exception")

        # 5a. OCR error pattern check (reuse ocrOutput if available)
        $negOcrOutput = $ocrOutput
        if (-not $negOcrOutput) {
            try { $negOcrOutput = _InvokeOcr -Image $afterPath -Detailed } catch { }
        }

        $ocrHit = $false
        foreach ($pattern in $errorPatterns) {
            if ($negOcrOutput -and ($negOcrOutput -match [regex]::Escape($pattern))) {
                $ocrHit = $true
                break
            }
        }

        # 5b. Window error title check
        $windowHit = $false
        try {
            $windowList = _InvokeWindow -Action "list"
            $windowListString = ($windowList | Out-String)
            foreach ($pattern in $windowErrorPatterns) {
                if ($windowListString -match [regex]::Escape($pattern)) {
                    $windowHit = $true
                    break
                }
            }
        }
        catch {
            # Window enumeration failed -- skip negative window check
        }

        if ($ocrHit -or $windowHit) {
            $scores.negative = $false
        }
    }

    # --- 6. Weighted verdict calculation ---
    $weights = @{
        pixel_diff = 0.15
        ocr        = 0.35
        uia_state  = 0.40
        negative   = 0.10
    }

    $totalScore = ($scores.pixel_diff * $weights.pixel_diff) +
                  ($scores.ocr * $weights.ocr) +
                  ($scores.uia_state * $weights.uia_state) +
                  (([int]$scores.negative) * $weights.negative)

    # --- 7. Diagnostic output ---
    Write-Host "VERIFY|scores|diff=$($scores.pixel_diff)|ocr=$($scores.ocr)|uia=$($scores.uia_state)|neg=$($scores.negative)|total=$totalScore"

    # --- 8. Verdict ---
    if (-not $scores.negative) {
        return "FAILURE"
    }
    if ($totalScore -ge 0.60) {
        return "SUCCESS"
    }
    if ($totalScore -ge 0.30) {
        return "UNCERTAIN"
    }
    return "FAILURE"
}

# Only run standalone logic when invoked as script (not dot-sourced)
if ($MyInvocation.InvocationName -ne '.') {

# --- Auto-capture mode ---
if ($Capture) {
    if (-not $Action) {
        Write-Output "ERROR|-Capture requires -Action scriptblock"
        exit 1
    }

    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $Before = "$env:TEMP\_verify_before_$ts.png"
    $After  = "$env:TEMP\_verify_after_$ts.png"

    # Capture "before"
    $res = & powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\scripts\screenshot.ps1" -Path $Before
    if (-not (Test-Path $Before)) {
        Write-Output "ERROR|failed to capture before screenshot"
        exit 1
    }

    # Execute the action
    try {
        & $Action
    }
    catch {
        Write-Output "WARN|action threw: $_"
    }
    Start-Sleep -Milliseconds 800  # Wait for UI to settle

    # Capture "after"
    $res = & powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\scripts\screenshot.ps1" -Path $After
    if (-not (Test-Path $After)) {
        Write-Output "ERROR|failed to capture after screenshot"
        Remove-Item $Before -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

# --- Validate inputs ---
if (-not $Before -or -not (Test-Path $Before)) {
    Write-Output "ERROR|before image not found: $Before"
    exit 1
}
if (-not $After -or -not (Test-Path $After)) {
    Write-Output "ERROR|after image not found: $After"
    exit 1
}

# --- Run comparison ---
try {
    $result = [VisualDiff]::Compare($Before, $After, $Threshold, $Diff)

    Write-Output "OK|changed=$($result.ChangedPixels)/$($result.TotalPixels)|$([math]::Round($result.ChangePercent, 2))%"
    Write-Output "regions=$($result.ChangedRegions.Count)"

    foreach ($r in $result.ChangedRegions) {
        Write-Output "region|$($r.Left),$($r.Top)|$($r.Right-$r.Left)x$($r.Bottom-$r.Top)"
    }

    if ($Diff) {
        Write-Output "diff|$Diff"
    }

    # Cleanup temp files
    if ($Capture) {
        Remove-Item $Before, $After -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Write-Output "ERROR|$_"
    # Cleanup even on error
    if ($Capture) {
        Remove-Item $Before, $After -Force -ErrorAction SilentlyContinue
    }
}

} # end dot-source guard
