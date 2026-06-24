# Keyboard Control Script v2 — Win32 SendInput + Unicode support
# Supports Chinese, emoji, and all Unicode characters via KEYEVENTF_UNICODE
# Usage:
#   .\keyboard.ps1 -Action type -Text "Hello 你好 👋"      # Type text (Unicode)
#   .\keyboard.ps1 -Action key -Key Enter                   # Press single key
#   .\keyboard.ps1 -Action hotkey -Mod Ctrl -Key C          # Press Ctrl+C
#   .\keyboard.ps1 -Action hotkey -Mod Alt -Key F4          # Press Alt+F4

param(
    [ValidateSet("type","key","hotkey")]
    [string]$Action = "type",
    [string]$Text = "",
    [string]$Key = "",
    [string]$Mod = ""
)

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public class KB
{
    // --- SendInput structures ---
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

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

    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT_UNION
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public uint type;
        public INPUT_UNION u;
    }

    // --- P/Invoke ---
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern short VkKeyScan(char ch);

    [DllImport("user32.dll")]
    public static extern short VkKeyScanEx(char ch, IntPtr dwhkl);

    // --- Constants ---
    public const uint INPUT_KEYBOARD    = 1;
    public const uint KEYEVENTF_KEYDOWN = 0x0000;
    public const uint KEYEVENTF_KEYUP   = 0x0002;
    public const uint KEYEVENTF_UNICODE = 0x0004;

    // --- Unicode text typing via SendInput ---
    public static void TypeText(string text)
    {
        if (string.IsNullOrEmpty(text)) return;

        int len = text.Length;
        INPUT[] inputs = new INPUT[len * 2]; // keydown + keyup per char

        for (int i = 0; i < len; i++)
        {
            char ch = text[i];
            int idx = i * 2;

            // KeyDown with KEYEVENTF_UNICODE
            inputs[idx].type = INPUT_KEYBOARD;
            inputs[idx].u.ki.wVk = 0;
            inputs[idx].u.ki.wScan = ch;       // Unicode codepoint in wScan
            inputs[idx].u.ki.dwFlags = KEYEVENTF_UNICODE;

            // KeyUp with KEYEVENTF_UNICODE
            inputs[idx + 1].type = INPUT_KEYBOARD;
            inputs[idx + 1].u.ki.wVk = 0;
            inputs[idx + 1].u.ki.wScan = ch;
            inputs[idx + 1].u.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        }

        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    // --- VK-based single key press (for non-character keys) ---
    public static void PressKey(byte vk)
    {
        keybd_event(vk, 0, KEYEVENTF_KEYDOWN, UIntPtr.Zero);
        keybd_event(vk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    public static void HoldKey(byte vk)
    {
        keybd_event(vk, 0, KEYEVENTF_KEYDOWN, UIntPtr.Zero);
    }

    public static void ReleaseKey(byte vk)
    {
        keybd_event(vk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
'@

# Virtual key codes for special keys (non-character keys use keybd_event)
$VK = @{
    Enter=0x0D; Tab=0x09; Escape=0x1B; Space=0x20;
    Left=0x25; Up=0x26; Right=0x27; Down=0x28;
    Shift=0x10; Ctrl=0x11; Alt=0x12; Win=0x5B;
    Backspace=0x08; Delete=0x2E; Insert=0x2D; Home=0x24; End=0x23;
    PageUp=0x21; PageDown=0x22; PrintScreen=0x2C;
    F1=0x70; F2=0x71; F3=0x72; F4=0x73; F5=0x74;
    F6=0x75; F7=0x76; F8=0x77; F9=0x78; F10=0x79; F11=0x7A; F12=0x7B;
    CapsLock=0x14; NumLock=0x90; ScrollLock=0x91;
}

switch ($Action) {
    "type" {
        if (-not $Text) {
            Write-Output "ERROR|no text provided"
            break
        }
        [KB]::TypeText($Text)
        Write-Output "OK|typed|$Text"
    }
    "key" {
        $vk = $VK[$Key]
        if (-not $vk) {
            Write-Output "ERROR|unknown key: $Key"
            break
        }
        [KB]::PressKey($vk)
        Write-Output "OK|pressed|$Key"
    }
    "hotkey" {
        $modVk = $VK[$Mod]
        $keyVk = $VK[$Key]
        if (-not $modVk) {
            Write-Output "ERROR|unknown modifier: $Mod"
            break
        }
        if (-not $keyVk) {
            Write-Output "ERROR|unknown key: $Key"
            break
        }
        [KB]::HoldKey($modVk)
        Start-Sleep -Milliseconds 30
        [KB]::PressKey($keyVk)
        Start-Sleep -Milliseconds 30
        [KB]::ReleaseKey($modVk)
        Write-Output "OK|hotkey|$Mod+$Key"
    }
}
