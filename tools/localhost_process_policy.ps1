Set-StrictMode -Version Latest

function Get-Tpf2mpLocalhostAffinityMask([ValidateSet('player1', 'player2')][string]$Peer) {
    $logical = [Environment]::ProcessorCount
    if ($logical -lt 4 -or $logical -gt 63) { return $null }
    $processor = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $amdSmt = $processor -and [string]$processor.Manufacturer -match 'AMD' `
        -and [int]$processor.NumberOfLogicalProcessors -eq 2 * [int]$processor.NumberOfCores
    $indices = [Collections.Generic.List[int]]::new()
    if ($amdSmt) {
        # Ryzen desktop numbering is contiguous by CCD on the supported lab
        # machines. Give each renderer a private cache/CCD instead of letting
        # Windows bounce both main simulation threads through the same cache.
        $split = [Math]::Floor($logical / 2)
        $begin = if ($Peer -eq 'player1') { 0 } else { $split }
        $end = if ($Peer -eq 'player1') { $split } else { $logical }
        for ($index = $begin; $index -lt $end; $index++) { $indices.Add($index) }
    }
    else {
        # Generic SMT-friendly fallback: keep sibling logical processors
        # together and alternate physical-core pairs between the two games.
        for ($index = 0; $index -lt $logical; $index++) {
            $pair = [Math]::Floor($index / 2)
            if (($pair % 2 -eq 0) -eq ($Peer -eq 'player1')) { $indices.Add($index) }
        }
    }
    [uint64]$mask = 0
    foreach ($index in $indices) { $mask = $mask -bor ([uint64]1 -shl $index) }
    return $mask
}

function Set-Tpf2mpLocalhostProcessPolicy(
    [Diagnostics.Process]$Process,
    [ValidateSet('player1', 'player2')][string]$Peer,
    [ValidateSet('Balanced', 'Native')][string]$Profile = 'Balanced'
) {
    if (-not $Process -or $Profile -eq 'Native') { return $null }
    $Process.Refresh()
    if ($Process.HasExited) { throw "$Peer process exited before its localhost policy was applied." }
    $mask = Get-Tpf2mpLocalhostAffinityMask $Peer
    if ($null -ne $mask -and $mask -ne 0) {
        $Process.ProcessorAffinity = [intptr][int64]$mask
    }
    $Process.PriorityClass = [Diagnostics.ProcessPriorityClass]::Normal
    return [pscustomobject]@{
        peer = $Peer
        pid = $Process.Id
        profile = $Profile
        logicalProcessors = [Environment]::ProcessorCount
        affinityMask = if ($null -ne $mask) { '0x{0:x}' -f $mask } else { $null }
        priority = [string]$Process.PriorityClass
    }
}

function Set-Tpf2mpLocalhostWindowLayout(
    [Diagnostics.Process]$Player1,
    [Diagnostics.Process]$Player2,
    [ValidateSet('Balanced', 'Native')][string]$Profile = 'Balanced'
) {
    if ($Profile -eq 'Native' -or -not $Player1 -or -not $Player2) { return $null }
    if (-not ('Tpf2mpLocalhostWindowNative' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Tpf2mpLocalhostWindowNative {
  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, out Rect value, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
}
'@
    }
    $Player1.Refresh(); $Player2.Refresh()
    if ($Player1.MainWindowHandle -eq 0 -or $Player2.MainWindowHandle -eq 0) { return $null }
    $work = [Tpf2mpLocalhostWindowNative+Rect]::new()
    if (-not [Tpf2mpLocalhostWindowNative]::SystemParametersInfo(48, 0, [ref]$work, 0)) {
        return $null
    }
    $width = [Math]::Max(960, [Math]::Floor(($work.Right - $work.Left) / 2))
    $height = [Math]::Max(720, $work.Bottom - $work.Top)
    $flags = 0x0010 -bor 0x0040 # SWP_NOACTIVATE | SWP_SHOWWINDOW
    [void][Tpf2mpLocalhostWindowNative]::ShowWindow($Player1.MainWindowHandle, 9)
    [void][Tpf2mpLocalhostWindowNative]::ShowWindow($Player2.MainWindowHandle, 9)
    [void][Tpf2mpLocalhostWindowNative]::SetWindowPos(
        $Player1.MainWindowHandle, [intptr]::Zero, $work.Left, $work.Top, $width, $height, $flags)
    [void][Tpf2mpLocalhostWindowNative]::SetWindowPos(
        $Player2.MainWindowHandle, [intptr]::Zero, $work.Left + $width, $work.Top,
        $work.Right - ($work.Left + $width), $height, $flags)
    return [pscustomobject]@{ width = $width; height = $height; workArea = $work }
}
