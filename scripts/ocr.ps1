# OCR Text Recognition Script — Windows 10 built-in OCR via Windows.Media.Ocr
# Extracts text from screenshots or image files
# Usage:
#   .\ocr.ps1                                      # OCR current screen
#   .\ocr.ps1 -Image "screenshot.png"              # OCR a specific image
#   .\ocr.ps1 -Image "screen.png" -Lang "zh-Hans"  # Chinese simplified
#   .\ocr.ps1 -Image "screen.png" -Lang "en"       # English
#   .\ocr.ps1 -Image "screen.png" -Detail          # Show per-line text + bounding boxes

param(
    [string]$Image = "",
    [string]$Lang = "",            # Language tag: zh-Hans, en, ja, ko, etc. Empty = system default
    [switch]$Detail                # Show per-line bounding boxes
)

# ============================================================
# Step 1: Compile OCR helper DLL (cached)
# ============================================================
$ocrDll = "$env:TEMP\OcrHelper_v2.dll"
$winmdDir = "$env:SystemRoot\System32\WinMetadata"

if (-not (Test-Path $ocrDll)) {
    $csSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Media.Ocr;
using Windows.Storage;
using Windows.Storage.Streams;

namespace OcrTool
{
    public struct OcrWord
    {
        public string Text;
        public int Left, Top, Width, Height;
    }

    public struct OcrLine
    {
        public string Text;
        public int Left, Top, Width, Height;
        public OcrWord[] Words;
    }

    public struct OcrResult
    {
        public string FullText;
        public OcrLine[] Lines;
    }

    public class OcrHelper
    {
        /// Synchronously wait for a WinRT IAsyncOperation
        private static T AwaitWinRT<T>(IAsyncOperation<T> op)
        {
            while (op.Status == AsyncStatus.Started)
            {
                Thread.Sleep(5);
            }
            if (op.Status == AsyncStatus.Completed)
                return op.GetResults();
            if (op.Status == AsyncStatus.Error)
                throw new Exception("WinRT async operation failed: " + op.ErrorCode);
            throw new Exception("WinRT async operation cancelled");
        }

        /// Run OCR on an image file and return structured result
        public static OcrResult Recognize(string imagePath, string languageTag)
        {
            // 1. Open image file
            var file = AwaitWinRT(StorageFile.GetFileFromPathAsync(imagePath));

            // 2. Decode to SoftwareBitmap
            SoftwareBitmap bitmap;
            using (var stream = AwaitWinRT(file.OpenReadAsync()))
            {
                var decoder = AwaitWinRT(BitmapDecoder.CreateAsync(stream));
                var frame = AwaitWinRT(decoder.GetSoftwareBitmapAsync());

                if (frame.BitmapPixelFormat == BitmapPixelFormat.Bgra8 ||
                    frame.BitmapPixelFormat == BitmapPixelFormat.Rgba8)
                {
                    bitmap = frame;
                }
                else
                {
                    bitmap = SoftwareBitmap.Convert(frame, BitmapPixelFormat.Bgra8);
                }
            }

            // 3. Create OCR engine
            OcrEngine engine;
            if (!string.IsNullOrEmpty(languageTag))
            {
                engine = OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language(languageTag));
                if (engine == null)
                {
                    throw new Exception("OCR language '" + languageTag + "' is not available on this system. " +
                        "Install it via Settings → Time & Language → Language → Add a language.");
                }
            }
            else
            {
                engine = OcrEngine.TryCreateFromUserProfileLanguages();
                if (engine == null)
                {
                    throw new Exception("No OCR language available. Install a language pack in Windows Settings.");
                }
            }

            // 4. Run recognition
            var ocrResult = AwaitWinRT(engine.RecognizeAsync(bitmap));

            // 5. Parse results
            var lines = new List<OcrLine>();
            foreach (var line in ocrResult.Lines)
            {
                var words = new List<OcrWord>();
                int lineLeft = int.MaxValue, lineTop = int.MaxValue;
                int lineRight = 0, lineBottom = 0;

                foreach (var word in line.Words)
                {
                    int wl = (int)word.BoundingRect.Left;
                    int wt = (int)word.BoundingRect.Top;
                    int ww = (int)word.BoundingRect.Width;
                    int wh = (int)word.BoundingRect.Height;

                    words.Add(new OcrWord
                    {
                        Text = word.Text,
                        Left = wl, Top = wt, Width = ww, Height = wh
                    });

                    if (wl < lineLeft) lineLeft = wl;
                    if (wt < lineTop) lineTop = wt;
                    if (wl + ww > lineRight) lineRight = wl + ww;
                    if (wt + wh > lineBottom) lineBottom = wt + wh;
                }

                lines.Add(new OcrLine
                {
                    Text = line.Text,
                    Left = (words.Count > 0) ? lineLeft : 0,
                    Top = (words.Count > 0) ? lineTop : 0,
                    Width = (words.Count > 0) ? lineRight - lineLeft : 0,
                    Height = (words.Count > 0) ? lineBottom - lineTop : 0,
                    Words = words.ToArray()
                });
            }

            return new OcrResult
            {
                FullText = ocrResult.Text,
                Lines = lines.ToArray()
            };
        }
    }
}
'@

    $csFile = "$env:TEMP\_ocr_helper.cs"
    Set-Content -Path $csFile -Value $csSource -Encoding UTF8

    # Find csc.exe
    $csc = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    if (-not (Test-Path $csc)) {
        $csc = "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    }

    # Build reference paths — need .NET Framework facades for WinRT compatibility
    $fxFacades = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319"
    $refAssemblies = "C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8"

    $refs = @(
        "/r:System.Runtime.WindowsRuntime.dll",
        "/r:$refAssemblies\Facades\System.Runtime.dll",
        "/r:$refAssemblies\Facades\System.Runtime.InteropServices.WindowsRuntime.dll",
        "/r:$refAssemblies\Facades\System.Threading.Tasks.dll",
        "/r:$refAssemblies\Facades\System.Collections.dll",
        "/r:$refAssemblies\Facades\System.Runtime.InteropServices.dll",
        "/r:$refAssemblies\Facades\System.Runtime.Extensions.dll",
        "/r:$refAssemblies\Facades\System.IO.dll",
        "/r:$refAssemblies\Facades\System.ObjectModel.dll",
        "/r:$winmdDir\Windows.Foundation.winmd",
        "/r:$winmdDir\Windows.Globalization.winmd",
        "/r:$winmdDir\Windows.Graphics.winmd",
        "/r:$winmdDir\Windows.Media.winmd",
        "/r:$winmdDir\Windows.Storage.winmd"
    )

    $args = @(
        "/target:library",
        "/out:$ocrDll",
        "/nologo",
        "/optimize",
        "/nowarn:168,1701,1702"
    ) + $refs + @($csFile)

    $result = & $csc $args 2>&1
    Remove-Item $csFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $ocrDll)) {
        Write-Output "ERROR|OCR compilation failed. Ensure Windows 10 SDK is available."
        Write-Output "ERROR|Compiler output: $result"
        Write-Output "ERROR|Try: Install Windows 10 SDK or add OCR language pack in Settings."
        exit 1
    }
}

# ============================================================
# Step 2: Load DLL and run OCR
# ============================================================
try {
    Add-Type -Path $ocrDll -ReferencedAssemblies "System.Runtime.WindowsRuntime"

    # Resolve image
    if (-not $Image) {
        $Image = "$env:TEMP\_ocr_screen.png"
        $res = & powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\scripts\screenshot.ps1" -Path $Image
        if (-not (Test-Path $Image)) {
            Write-Output "ERROR|failed to capture screen"
            exit 1
        }
    }
    elseif (-not (Test-Path $Image)) {
        Write-Output "ERROR|image not found: $Image"
        exit 1
    }

    $ocrResult = [OcrTool.OcrHelper]::Recognize((Resolve-Path $Image).Path, $Lang)

    # Output
    Write-Output "OK|lang=$($Lang -replace '^$','auto')"

    if ($Detail) {
        foreach ($line in $ocrResult.Lines) {
            Write-Output "LINE|$($line.Text)|$($line.Left),$($line.Top)|$($line.Width)x$($line.Height)"
            foreach ($word in $line.Words) {
                Write-Output "  WORD|$($word.Text)|$($word.Left),$($word.Top)|$($word.Width)x$($word.Height)"
            }
        }
    }
    else {
        # Simple output: each line of text
        if ($ocrResult.FullText) {
            $ocrResult.FullText -split '\r?\n' | Where-Object { $_ -ne '' } | ForEach-Object {
                Write-Output "TEXT|$_"
            }
        }
        else {
            Write-Output "TEXT|(no text found)"
        }
    }

    # Cleanup temp screenshot
    if ($Image -eq "$env:TEMP\_ocr_screen.png") {
        Remove-Item $Image -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Write-Output "ERROR|$_"
    if ($Image -eq "$env:TEMP\_ocr_screen.png") {
        Remove-Item $Image -Force -ErrorAction SilentlyContinue
    }
}
