[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$GameProcessId,
    [Parameter(Mandatory = $true)][ValidateSet('start', 'load', 'quit', 'free-game', 'maximize', 'click-client', 'click-ui', 'inspect', 'accept', 'accept-down', 'accept-up', 'escape', 'resume', 'replace-ui-text', 'custom', 'custom-active', 'custom-stay', 'custom-active-stay', 'custom-stage', 'custom-active-stage', 'toggle-console', 'toggle-console-down', 'toggle-console-up')][string]$Action,
    [string]$Command,
    [string]$SavePath,
    [int]$DelayMilliseconds = 2500,
    [int]$ScreenX = 1437,
    [int]$ScreenY = 870,
    [int]$ConsoleInputX = 1350,
    [int]$ConsoleInputY = 814,
    [int]$ClientX = -1,
    [int]$ClientY = -1,
    [int]$UiWidth = -1,
    [int]$UiHeight = -1,
    [switch]$PhysicalPixels,
    [switch]$SkipConsoleClick,
    [string]$ResultPath,
    [string]$ScreenshotPath
)

$ErrorActionPreference = 'Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Tpf2ConsoleInput {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x; public int y; }
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h, int command);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetActiveWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT point);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT rect);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr value);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int left; public int top; public int right; public int bottom; }
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    [DllImport("user32.dll", SetLastError=true)] private static extern uint SendInput(uint count, INPUT[] inputs, int size);

    [StructLayout(LayoutKind.Sequential)] private struct INPUT { public uint type; public INPUTUNION data; }
    [StructLayout(LayoutKind.Explicit)] private struct INPUTUNION {
        [FieldOffset(0)] public MOUSEINPUT mouse;
        [FieldOffset(0)] public KEYBDINPUT keyboard;
        [FieldOffset(0)] public HARDWAREINPUT hardware;
    }
    [StructLayout(LayoutKind.Sequential)] private struct MOUSEINPUT {
        public int dx; public int dy; public uint mouseData; public uint flags; public uint time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)] private struct KEYBDINPUT {
        public ushort virtualKey; public ushort scanCode; public uint flags; public uint time; public UIntPtr extra;
    }
    [StructLayout(LayoutKind.Sequential)] private struct HARDWAREINPUT {
        public uint message; public ushort low; public ushort high;
    }

    private static void SendKeyboard(ushort virtualKey, ushort scanCode, uint flags) {
        INPUT input = new INPUT();
        input.type = 1;
        input.data.keyboard.virtualKey = virtualKey;
        input.data.keyboard.scanCode = scanCode;
        input.data.keyboard.flags = flags;
        if (SendInput(1, new INPUT[] { input }, Marshal.SizeOf(typeof(INPUT))) != 1)
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public static void PressScanCode(ushort scanCode) {
        SendKeyboard(0, scanCode, 0x0008);
        System.Threading.Thread.Sleep(90);
        SendKeyboard(0, scanCode, 0x0008 | 0x0002);
    }
    public static void ScanCodeDown(ushort scanCode) { SendKeyboard(0, scanCode, 0x0008); }
    public static void ScanCodeUp(ushort scanCode) { SendKeyboard(0, scanCode, 0x0008 | 0x0002); }
    public static void TypeUnicode(string value) {
        foreach (char character in value) {
            SendKeyboard(0, character, 0x0004);
            SendKeyboard(0, character, 0x0004 | 0x0002);
        }
    }
}
'@

if ($PhysicalPixels) {
    # Opt in for screenshot-derived coordinates on mixed-DPI desktops.  Keep
    # this explicit because older launcher receipts intentionally use the
    # virtualised coordinate system captured by their fixtures.
    [void][Tpf2ConsoleInput]::SetThreadDpiAwarenessContext([IntPtr](-4))
}

Start-Sleep -Milliseconds $DelayMilliseconds
$game = Get-Process -Id $GameProcessId -ErrorAction Stop
$target = $game.MainWindowHandle
if ($target -eq 0) { throw 'Transport Fever 2 has no main window' }
$receiptDetails = [ordered]@{}

for ($attempt = 0; $attempt -lt 20 -and [Tpf2ConsoleInput]::GetForegroundWindow() -ne $target; $attempt++) {
    $foreground = [Tpf2ConsoleInput]::GetForegroundWindow()
    [uint32]$foregroundOwner = 0
    [uint32]$targetOwner = 0
    $foregroundThread = [Tpf2ConsoleInput]::GetWindowThreadProcessId($foreground, [ref]$foregroundOwner)
    $targetThread = [Tpf2ConsoleInput]::GetWindowThreadProcessId($target, [ref]$targetOwner)
    $currentThread = [Tpf2ConsoleInput]::GetCurrentThreadId()
    [void][Tpf2ConsoleInput]::AttachThreadInput($currentThread, $foregroundThread, $true)
    [void][Tpf2ConsoleInput]::AttachThreadInput($currentThread, $targetThread, $true)
    # SW_RESTORE also changes a maximized window back to its remembered
    # restored rectangle.  That made screenshot-derived client coordinates
    # drift merely by targeting the other local game instance.  Restore only
    # an actually minimized window; otherwise preserve its current state.
    if ([Tpf2ConsoleInput]::IsIconic($target)) {
        [void][Tpf2ConsoleInput]::ShowWindowAsync($target, 9) # SW_RESTORE
    }
    else {
        [void][Tpf2ConsoleInput]::ShowWindowAsync($target, 5) # SW_SHOW
    }
    [Tpf2ConsoleInput]::SwitchToThisWindow($target, $true)
    [void][Tpf2ConsoleInput]::BringWindowToTop($target)
    [void][Tpf2ConsoleInput]::SetForegroundWindow($target)
    [void][Tpf2ConsoleInput]::SetActiveWindow($target)
    [void][Tpf2ConsoleInput]::SetFocus($target)
    [void][Tpf2ConsoleInput]::AttachThreadInput($currentThread, $targetThread, $false)
    [void][Tpf2ConsoleInput]::AttachThreadInput($currentThread, $foregroundThread, $false)
    Start-Sleep -Milliseconds 200
}
if ([Tpf2ConsoleInput]::GetForegroundWindow() -ne $target) { throw 'Could not foreground Transport Fever 2' }

if ($Action -eq 'maximize') {
    # Keep every target control inside the physical desktop before native UI
    # automation.  Transport Fever 2 remembers window positions and sizes that
    # can extend beyond a changed monitor layout; clicks into that off-screen
    # client region are not reliably delivered by Windows.
    if (-not [Tpf2ConsoleInput]::ShowWindowAsync($target, 3)) {
        throw 'Could not maximize the Transport Fever 2 window'
    }
    Start-Sleep -Milliseconds 1200
    $maximizedRect = New-Object Tpf2ConsoleInput+RECT
    if ([Tpf2ConsoleInput]::GetClientRect($target, [ref]$maximizedRect)) {
        $receiptDetails.clientWidth = $maximizedRect.right - $maximizedRect.left
        $receiptDetails.clientHeight = $maximizedRect.bottom - $maximizedRect.top
    }
}
elseif ($Action -eq 'free-game') {
    [void][Tpf2ConsoleInput]::SetCursorPos($ScreenX, $ScreenY)
    Start-Sleep -Milliseconds 200
    [Tpf2ConsoleInput]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [Tpf2ConsoleInput]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}
elseif ($Action -in @('click-client', 'click-ui')) {
    if ($ClientX -lt 0 -or $ClientY -lt 0) { throw "$Action requires non-negative ClientX and ClientY" }
    if ($Action -eq 'click-ui') {
        if ($UiWidth -le 0 -or $UiHeight -le 0) { throw 'click-ui requires positive UiWidth and UiHeight' }
        $clientRect = New-Object Tpf2ConsoleInput+RECT
        if (-not [Tpf2ConsoleInput]::GetClientRect($target, [ref]$clientRect)) {
            throw 'Could not read the game client rectangle'
        }
        $clientWidth = $clientRect.right - $clientRect.left
        $clientHeight = $clientRect.bottom - $clientRect.top
        if ($clientWidth -le 0 -or $clientHeight -le 0) { throw 'The game client rectangle is empty' }
        $ClientX = [Math]::Max(0, [Math]::Min($clientWidth - 1, [Math]::Round($ClientX * $clientWidth / $UiWidth)))
        $ClientY = [Math]::Max(0, [Math]::Min($clientHeight - 1, [Math]::Round($ClientY * $clientHeight / $UiHeight)))
        $receiptDetails.uiWidth = $UiWidth
        $receiptDetails.uiHeight = $UiHeight
        $receiptDetails.clientWidth = $clientWidth
        $receiptDetails.clientHeight = $clientHeight
    }
    $point = New-Object Tpf2ConsoleInput+POINT
    $point.x = $ClientX
    $point.y = $ClientY
    if (-not [Tpf2ConsoleInput]::ClientToScreen($target, [ref]$point)) {
        throw 'Could not translate client coordinates to screen coordinates'
    }
    [void][Tpf2ConsoleInput]::SetCursorPos($point.x, $point.y)
    $receiptDetails.clientX = $ClientX
    $receiptDetails.clientY = $ClientY
    $receiptDetails.screenX = $point.x
    $receiptDetails.screenY = $point.y
    Start-Sleep -Milliseconds 120
    [Tpf2ConsoleInput]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 70
    [Tpf2ConsoleInput]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
}
elseif ($Action -eq 'accept') {
    # One physical pulse is long enough to cross an input frame but releases
    # before Windows key-repeat can invoke a staged console transition twice.
    # Holding Return while app.loadGame() is still tearing down the menu can
    # re-enter UI::CCore::InvokeStoredFunctions and crash Build 35924 with
    # Assertion `!m_isInvoking`.
    [Tpf2ConsoleInput]::PressScanCode(0x1C)
}
elseif ($Action -eq 'accept-down') {
    [Tpf2ConsoleInput]::ScanCodeDown(0x1C)
}
elseif ($Action -eq 'accept-up') {
    [Tpf2ConsoleInput]::ScanCodeUp(0x1C)
}
elseif ($Action -eq 'escape') {
    [Tpf2ConsoleInput]::PressScanCode(0x01)
}
elseif ($Action -eq 'resume') {
    [Tpf2ConsoleInput]::PressScanCode(0x39)
}
elseif ($Action -eq 'replace-ui-text') {
    if ($null -eq $Command) { throw 'replace-ui-text requires -Command' }
    # Operate on the game widget which already owns keyboard focus.  This is
    # intentionally separate from the console path so stock editable labels
    # can be exercised through their real focus/accept callbacks.
    [Tpf2ConsoleInput]::ScanCodeDown(0x1D) # Left Control
    [Tpf2ConsoleInput]::PressScanCode(0x1E) # A
    [Tpf2ConsoleInput]::ScanCodeUp(0x1D)
    Start-Sleep -Milliseconds 120
    [Tpf2ConsoleInput]::TypeUnicode($Command)
}
elseif ($Action -eq 'toggle-console') {
    [Tpf2ConsoleInput]::PressScanCode(0x29)
}
elseif ($Action -eq 'toggle-console-down') {
    [Tpf2ConsoleInput]::ScanCodeDown(0x29)
}
elseif ($Action -eq 'toggle-console-up') {
    [Tpf2ConsoleInput]::ScanCodeUp(0x29)
}
elseif ($Action -in @('custom', 'custom-active', 'custom-stay', 'custom-active-stay', 'custom-stage', 'custom-active-stage')) {
    if ([string]::IsNullOrWhiteSpace($Command)) { throw 'Custom console action requires -Command' }
    if ($Action -in @('custom', 'custom-stay', 'custom-stage')) {
        [Tpf2ConsoleInput]::PressScanCode(0x29)
        Start-Sleep -Milliseconds 600
        # Build 35924 can insert the console-toggle key itself as the first
        # character after opening the overlay. Remove that synthetic grave
        # before staging the requested command; Backspace is harmless when
        # the input is already empty.
        [Tpf2ConsoleInput]::PressScanCode(0x0E)
        Start-Sleep -Milliseconds 120
    }
    if (-not $SkipConsoleClick) {
        [void][Tpf2ConsoleInput]::SetCursorPos($ConsoleInputX, $ConsoleInputY)
        [Tpf2ConsoleInput]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
        [Tpf2ConsoleInput]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 250
    }
    # Build 35924 may leave one or more synthetic grave characters in the
    # console input across repeated automated invocations. Clear that bounded
    # prefix even when the console was already open; Backspace is harmless on
    # an empty input and prevents a valid diagnostic command becoming a quoted
    # or otherwise malformed chunk.
    for ($clear = 0; $clear -lt 4; $clear++) {
        [Tpf2ConsoleInput]::PressScanCode(0x0E)
    }
    [Tpf2ConsoleInput]::TypeUnicode($Command)
    if ($Action -notin @('custom-stage', 'custom-active-stage')) {
        # The console samples the text-accept combo on a later input frame. A
        # normal down/up pulse can fit entirely between frames and be ignored.
        [Tpf2ConsoleInput]::ScanCodeDown(0x1C)
        Start-Sleep -Milliseconds 650
        [Tpf2ConsoleInput]::ScanCodeUp(0x1C)
        Start-Sleep -Milliseconds 1000
        if ($Action -notin @('custom-stay', 'custom-active-stay')) {
            [Tpf2ConsoleInput]::PressScanCode(0x29)
        }
    }
}
elseif ($Action -ne 'inspect') {
    # The console binding is the physical key below Escape. Send its scan code
    # directly so the Dutch/US layout mapping cannot change which key arrives.
    [Tpf2ConsoleInput]::PressScanCode(0x29)
    Start-Sleep -Milliseconds 600
    $command = if ($Action -eq 'start') {
        'app.startGame()'
    }
    elseif ($Action -eq 'load') {
        if ([string]::IsNullOrWhiteSpace($SavePath)) { throw 'Load action requires -SavePath' }
        $resolvedSave = [IO.Path]::GetFullPath($SavePath)
        if (-not (Test-Path -LiteralPath $resolvedSave -PathType Leaf)) {
            throw "Load action save is missing: $resolvedSave"
        }
        if ([IO.Path]::GetExtension($resolvedSave) -ne '.sav') {
            throw 'Load action accepts only a .sav file'
        }
        # Build 35924's console API resolves save names in the userdata/save
        # directory and expects the basename without `.sav`. An absolute path
        # is syntactically accepted but returns false. Keep the filesystem
        # validation above so a typo cannot silently select another save.
        $luaSave = [IO.Path]::GetFileNameWithoutExtension($resolvedSave)
        if ($luaSave.Contains(']]')) { throw 'Load action save name cannot contain ]]' }
        "app.loadGame([[$luaSave]])"
    }
    else { 'app.quit()' }
    [Tpf2ConsoleInput]::TypeUnicode($command)
    # Acceptance is deliberately a later helper invocation. Build 35924 must
    # observe Return held across the console-to-game state transition.
}

if ($ScreenshotPath) {
    Start-Sleep -Milliseconds 1200
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save($ScreenshotPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

if ($ResultPath) {
    [ordered]@{
        action = $Action
        processId = $GameProcessId
        sentAt = (Get-Date).ToString('o')
        foregroundVerified = $true
        details = $receiptDetails
    } | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}
