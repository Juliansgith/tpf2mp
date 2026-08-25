Set-StrictMode -Version Latest

function Test-Tpf2mpLoopbackPortPairAvailable {
    param([Parameter(Mandatory = $true)][ValidateRange(1, 65534)][int]$Port)

    $listeners = New-Object 'System.Collections.Generic.List[System.Net.Sockets.TcpListener]'
    try {
        foreach ($candidate in @($Port, ($Port + 1))) {
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $candidate)
            [void]($listener.Server.ExclusiveAddressUse = $true)
            $listener.Start()
            [void]$listeners.Add($listener)
        }
        return $true
    }
    catch { return $false }
    finally {
        foreach ($listener in $listeners) {
            try { $listener.Stop() } catch { }
        }
    }
}

function Find-Tpf2mpFreeLoopbackPortPair {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 65534)][int]$PreferredPort,
        [ValidateRange(1, 512)][int]$SearchPairs = 128
    )

    for ($offset = 0; $offset -lt $SearchPairs; $offset++) {
        $candidate = $PreferredPort + (2 * $offset)
        if ($candidate -gt 65534) { $candidate = 20000 + (2 * ($offset - 1)) }
        if (Test-Tpf2mpLoopbackPortPairAvailable -Port $candidate) { return $candidate }
    }
    throw "No free adjacent loopback TCP port pair was found near $PreferredPort."
}
