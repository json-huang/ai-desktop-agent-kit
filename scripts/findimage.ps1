# Image Template Matching Script — find a template within a larger image
# Uses Normalized Cross-Correlation (NCC) for robust matching
# Usage:
#   .\findimage.ps1 -Template "button.png"                          # Search full screen for button.png
#   .\findimage.ps1 -Template "icon.png" -Screen "screenshot.png"    # Search a specific image
#   .\findimage.ps1 -Template "x.png" -Threshold 0.85 -TopN 5       # Return top 5 matches above 0.85
#   .\findimage.ps1 -Template "x.png" -Region 100,200,500,400        # Search within region only

param(
    [Parameter(Mandatory=$true)]
    [string]$Template,

    [string]$Screen = "",            # If empty, take a new screenshot
    [float]$Threshold = 0.7,         # NCC confidence threshold (0.0–1.0)
    [int]$TopN = 1,                  # Return top N matches
    [string]$Region = ""             # "Left,Top,Width,Height" — limit search area
)

Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class ImageFinder
{
    /// Result of a template match
    public struct MatchResult
    {
        public int X, Y;          // Top-left of match in screen coordinates
        public float Score;       // NCC score (0.0–1.0, higher = better)
        public int CenterX() { return X + TemplateW / 2; }
        public int CenterY() { return Y + TemplateH / 2; }
        public int TemplateW, TemplateH;
    }

    /// Convert Bitmap to float array for faster NCC computation
    private static float[,] BitmapToGrayscaleFloat(Bitmap bmp)
    {
        int w = bmp.Width, h = bmp.Height;
        float[,] result = new float[w, h];
        BitmapData data = bmp.LockBits(new Rectangle(0, 0, w, h),
            ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
        int stride = data.Stride;
        byte[] bytes = new byte[stride * h];
        Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
        bmp.UnlockBits(data);

        for (int y = 0; y < h; y++)
        {
            int rowOffset = y * stride;
            for (int x = 0; x < w; x++)
            {
                int idx = rowOffset + x * 3;
                float gray = bytes[idx + 2] * 0.299f + bytes[idx + 1] * 0.587f + bytes[idx] * 0.114f;
                result[x, y] = gray;
            }
        }
        return result;
    }

    /// Normalized Cross-Correlation template matching
    /// Returns matches sorted by score descending
    public static List<MatchResult> FindTemplate(
        string screenPath, string templatePath,
        float threshold, int topN,
        int regionLeft, int regionTop, int regionW, int regionH)
    {
        using (Bitmap screenBmp = new Bitmap(screenPath))
        using (Bitmap templateBmp = new Bitmap(templatePath))
        {
            int tplW = templateBmp.Width, tplH = templateBmp.Height;
            int scrW = screenBmp.Width, scrH = screenBmp.Height;

            // Validate template fits
            if (tplW > scrW || tplH > scrH)
                throw new Exception("Template (" + tplW + "x" + tplH + ") larger than screen (" + scrW + "x" + scrH + ")");

            // Determine search region
            int searchLeft = 0, searchTop = 0;
            int searchRight = scrW - tplW, searchBottom = scrH - tplH;

            if (regionW > 0 && regionH > 0)
            {
                searchLeft = Math.Max(0, regionLeft);
                searchTop = Math.Max(0, regionTop);
                searchRight = Math.Min(scrW - tplW, regionLeft + regionW - tplW);
                searchBottom = Math.Min(scrH - tplH, regionTop + regionH - tplH);
                if (searchRight < searchLeft || searchBottom < searchTop)
                    throw new Exception("Search region is too small for template");
            }

            int searchW = searchRight - searchLeft + 1;
            int searchH = searchBottom - searchTop + 1;

            // Convert to grayscale float arrays
            float[,] screen = BitmapToGrayscaleFloat(screenBmp);
            float[,] tpl = BitmapToGrayscaleFloat(templateBmp);

            // Precompute template statistics
            float tplMean = 0, tplStd = 0;
            float tplN = tplW * tplH;
            for (int tx = 0; tx < tplW; tx++)
                for (int ty = 0; ty < tplH; ty++)
                    tplMean += tpl[tx, ty];
            tplMean /= tplN;
            for (int tx = 0; tx < tplW; tx++)
                for (int ty = 0; ty < tplH; ty++)
                {
                    float d = tpl[tx, ty] - tplMean;
                    tplStd += d * d;
                }
            tplStd = (float)Math.Sqrt(tplStd);
            if (tplStd < 1e-6f) tplStd = 1f; // avoid division by zero

            // Sliding window NCC
            var results = new List<MatchResult>();

            for (int sy = searchTop; sy <= searchBottom; sy++)
            {
                for (int sx = searchLeft; sx <= searchRight; sx++)
                {
                    // Compute window mean
                    float winMean = 0;
                    for (int tx = 0; tx < tplW; tx++)
                        for (int ty = 0; ty < tplH; ty++)
                            winMean += screen[sx + tx, sy + ty];
                    winMean /= tplN;

                    // Compute NCC numerator and window std
                    float numer = 0, winStd = 0;
                    for (int tx = 0; tx < tplW; tx++)
                    {
                        for (int ty = 0; ty < tplH; ty++)
                        {
                            float sv = screen[sx + tx, sy + ty] - winMean;
                            float tv = tpl[tx, ty] - tplMean;
                            numer += sv * tv;
                            winStd += sv * sv;
                        }
                    }
                    winStd = (float)Math.Sqrt(winStd);
                    if (winStd < 1e-6f) winStd = 1f;

                    float ncc = numer / (winStd * tplStd);

                    if (ncc >= threshold)
                    {
                        results.Add(new MatchResult
                        {
                            X = sx, Y = sy,
                            Score = ncc,
                            TemplateW = tplW, TemplateH = tplH
                        });
                    }
                }
            }

            // Sort by score descending, take top N
            results.Sort((a, b) => b.Score.CompareTo(a.Score));
            if (results.Count > topN)
                results.RemoveRange(topN, results.Count - topN);

            return results;
        }
    }
}
'@ -ReferencedAssemblies System.Drawing

try {
    # Resolve screen image
    if (-not $Screen) {
        $Screen = "$env:TEMP\_findimage_screen.png"
        $args = @("-ExecutionPolicy", "Bypass", "-File", "$env:USERPROFILE\.claude\scripts\screenshot.ps1", "-Path", $Screen)
        $res = & powershell $args
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Screen)) {
            Write-Output "ERROR|failed to capture screen"
            exit 1
        }
    }
    elseif (-not (Test-Path $Screen)) {
        Write-Output "ERROR|screen image not found: $Screen"
        exit 1
    }

    if (-not (Test-Path $Template)) {
        Write-Output "ERROR|template image not found: $Template"
        exit 1
    }

    # Parse region
    $rLeft = 0; $rTop = 0; $rW = -1; $rH = -1
    if ($Region) {
        $parts = $Region -split ','
        if ($parts.Count -eq 4) {
            $rLeft = [int]$parts[0]; $rTop = [int]$parts[1]
            $rW = [int]$parts[2]; $rH = [int]$parts[3]
        }
    }

    $matches = [ImageFinder]::FindTemplate($Screen, $Template, $Threshold, $TopN, $rLeft, $rTop, $rW, $rH)

    if ($matches.Count -eq 0) {
        Write-Output "NOTFOUND|threshold=$Threshold"
    }
    else {
        foreach ($m in $matches) {
            Write-Output "OK|$($m.CenterX()),$($m.CenterY())|score=$([math]::Round($m.Score,4))|rect=$($m.X),$($m.Y),$($m.TemplateW),$($m.TemplateH)"
        }
    }

    # Cleanup temp screenshot
    if ($Screen -eq "$env:TEMP\_findimage_screen.png") {
        Remove-Item $Screen -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Write-Output "ERROR|$_"
}
