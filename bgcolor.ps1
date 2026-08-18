# bgcolor.ps1 - set this console window's background color.
#
#   bgcolor            show the numbered list
#   bgcolor 12         set background to color 12
#   bgcolor 336699     set background to any hex color (NO leading #)
#   bgcolor set 12 1A2B3C   permanently redefine color 12 in the list
#
# Every color in the list is dark enough that white text stays readable.
# This script does not touch the Windows Properties palette.
param([string]$Pick, [string]$SetSlot, [string]$SetHex)

# ---------------------------------------------------------------------
# THE LIST. The number on the left is what you type: bgcolor 12
# 1-5 are your originals, unchanged. 6-16 are dark presets.
# Edit here, or use: bgcolor set <N> <RRGGBB>
# ---------------------------------------------------------------------
$Colors = [ordered]@{
    green    = '003000'
    blue     = '012456'
    purple   = '400040'
    charcoal = '202020'
    olive    = '504000'
    wine     = '4A1020'
    teal     = '063038'
    rust     = '4A2408'
    indigo   = '201050'
    forest   = '0D3018'
    magenta  = '3A0A30'
    slate    = '1E2A38'
    brown    = '302010'
    navy     = '0B1B3A'
    midnight = '0A0F1E'
    black    = '0C0C0C'
}

if ($Pick -match '^(/h|/\?|-h|--help|help)$') {
    Write-Host @'
bgcolor - change this console window's background color

SETTING A COLOR (run inside the window you want to change):
  bgcolor            show the numbered list
  bgcolor 12         set background to color 12 from that list
  bgcolor 336699     set background to any hex color you like
  bgcolor set 12 1A2B3C
                     permanently change what color 12 is in the list
  bgcolor /h         this help

THESE WILL NOT WORK - and this is probably what bit you:
  bgcolor #003366          <-- WRONG. Silently just prints the list.
  bgcolor set 16 #000000   <-- WRONG. Complains the hex is missing.

  Why: PowerShell treats an unquoted # as the start of a comment and
  throws away the rest of the line BEFORE this script ever runs, so the
  script genuinely receives nothing. It cannot be fixed here; the color
  is gone before the program starts.

  Do this instead - drop the # entirely:
  bgcolor 003366
  bgcolor set 16 000000

  Or quote it, which also works:
  bgcolor '#003366'
  bgcolor set 16 '#000000'

NOTES:
  The list is this script's own menu and persists forever. It is not
  the Windows Properties palette - that is left alone, so nothing here
  can damage your text colors.
  A background change lasts until the window closes.
  Names also work if you ever want them: bgcolor teal

TO UNDO: bgcolor 16 (the Windows default black), or close the window.

INSTALLED AS: C:\Users\Bob\.claudecm\bgcolor.ps1, with a two-line
bgcolor.cmd shim in C:\Users\Bob\bin so plain "bgcolor" works anywhere.
'@
    exit 0
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class BgPal {
    [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short L; public short T; public short R; public short B; }
    [StructLayout(LayoutKind.Sequential)] public struct CSBIEX {
        public int cbSize; public COORD dwSize; public COORD dwCursorPosition; public ushort wAttributes;
        public SMALL_RECT srWindow; public COORD dwMaximumWindowSize; public ushort wPopupAttributes;
        public bool bFullscreenSupported;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public uint[] ColorTable;
    }
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string n, uint acc, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int h);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleScreenBufferInfoEx(IntPtr h, ref CSBIEX info);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleScreenBufferInfoEx(IntPtr h, ref CSBIEX info);
}
"@ -ErrorAction SilentlyContinue

function Get-Info {
    $i = New-Object BgPal+CSBIEX
    $i.cbSize = [Runtime.InteropServices.Marshal]::SizeOf([type][BgPal+CSBIEX])
    # CONOUT$ reaches the real console even when stdout is redirected;
    # GetStdHandle(-11) returns the pipe in that case and the call fails.
    $h = [BgPal]::CreateFileW("CONOUT$", [uint32]3221225472, [uint32]3, [IntPtr]::Zero, [uint32]3, [uint32]0, [IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr](-1)) { $h = [BgPal]::GetStdHandle(-11) }
    if (-not [BgPal]::GetConsoleScreenBufferInfoEx($h, [ref]$i)) { return $null }
    ,@($h, $i)
}

function Rgb($c) { '#{0:X2}{1:X2}{2:X2}' -f ($c -band 0xFF), (($c -shr 8) -band 0xFF), (($c -shr 16) -band 0xFF) }

function HexToColor($hex) {
    $r = [Convert]::ToInt32($hex.Substring(0,2),16)
    $g = [Convert]::ToInt32($hex.Substring(2,2),16)
    $b = [Convert]::ToInt32($hex.Substring(4,2),16)
    [uint32]($r -bor ($g -shl 8) -bor ($b -shl 16))
}

$got = Get-Info
if (-not $got) { Write-Host "Cannot reach this console (run me inside a real console window)."; exit 1 }
$h, $info = $got
$bgIdx = ($info.wAttributes -shr 4) -band 0xF
$names = @($Colors.Keys)

# ---- no arguments: show the list ----
if (-not $Pick) {
    $curBg = (Rgb $info.ColorTable[$bgIdx]).ToUpper()
    Write-Host ""
    for ($i = 0; $i -lt $names.Count; $i++) {
        $nm = $names[$i]
        $hx = $Colors[$nm]
        $mark = ""
        if (("#" + $hx).ToUpper() -eq $curBg) { $mark = "   <-- current" }
        Write-Host ("  {0,2}   #{1}   {2}{3}" -f ($i + 1), $hx.ToUpper(), $nm, $mark)
    }
    Write-Host ""
    Write-Host "  bgcolor 12       set background to number 12"
    Write-Host "  bgcolor 336699   any hex, NO leading # (PowerShell deletes it)"
    Write-Host "  bgcolor /h       more"
    exit 0
}

# ---- set: permanently redefine an entry in the list above ----
if ($Pick -eq 'set') {
    if (-not $SetHex) {
        Write-Host "No hex color received."
        Write-Host "PowerShell treats an unquoted # as a comment, so the color was thrown away"
        Write-Host "before this script ran. Drop the # entirely:"
        Write-Host "  bgcolor set $SetSlot 336699"
        exit 1
    }
    if ($SetSlot -notmatch '^\d+$' -or [int]$SetSlot -lt 1 -or [int]$SetSlot -gt $names.Count -or $SetHex -notmatch '^#?([0-9A-Fa-f]{6})$') {
        Write-Host ("Usage: bgcolor set <1..{0}> <RRGGBB>" -f $names.Count)
        exit 1
    }
    $hex  = $Matches[1].ToUpper()
    $name = $names[[int]$SetSlot - 1]
    $path = $PSCommandPath
    $text = Get-Content -LiteralPath $path -Raw
    $pattern = "(?m)^(\s*" + [regex]::Escape($name) + "\s*=\s*')[0-9A-Fa-f]{6}(')"
    if ($text -notmatch $pattern) { Write-Host "Could not find entry $SetSlot in the list to update."; exit 1 }
    $updated = [regex]::Replace($text, $pattern, ('${1}' + $hex + '${2}'))
    # validate before committing, so a bad write cannot break the tool
    $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($updated, [ref]$null, [ref]$err)
    if ($err -and $err.Count) { Write-Host "Refusing to write: that edit would break the script."; exit 1 }
    Set-Content -LiteralPath $path -Value $updated -NoNewline
    Write-Host "color $SetSlot is now #$hex  [permanent]"
    Write-Host "Run 'bgcolor $SetSlot' to apply it."
    exit 0
}

# ---- resolve what the user asked for ----
$newColor = $null
if ($Pick -match '^\d+$' -and [int]$Pick -ge 1 -and [int]$Pick -le $names.Count) {
    $newColor = HexToColor $Colors[$names[[int]$Pick - 1]]
} elseif ($Colors.Contains($Pick.ToLower())) {
    $newColor = HexToColor $Colors[$Pick.ToLower()]
} elseif ($Pick -match '^#?([0-9A-Fa-f]{6})$') {
    $newColor = HexToColor $Matches[1]
} else {
    Write-Host "Unrecognised argument: $Pick"
    Write-Host "Try:  bgcolor          (show the list)"
    Write-Host "      bgcolor 12       (a number from the list)"
    Write-Host "      bgcolor 336699   (hex, NO leading #)"
    exit 1
}

# conhost path: repaint by rewriting the palette slot the background uses.
$info.ColorTable[$bgIdx] = $newColor
# Known SetConsoleScreenBufferInfoEx quirk: window shrinks by one row/col
# unless the rect is re-inflated before the call.
$info.srWindow.R++; $info.srWindow.B++
[BgPal]::SetConsoleScreenBufferInfoEx($h, [ref]$info) | Out-Null

# Windows Terminal path: OSC 11 (ignored harmlessly where unsupported).
$hexOut = (Rgb $newColor)
Write-Host -NoNewline "$([char]27)]11;$hexOut$([char]7)"
Write-Host "background -> $hexOut"
