[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ProjectRoot)

$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectRoot 'tools\relay_port_common.ps1')

$preferred = Find-Tpf2mpFreeLoopbackPortPair -PreferredPort 29742
if (-not (Test-Tpf2mpLoopbackPortPairAvailable -Port $preferred)) {
    throw 'The preferred relay port pair was not actually bindable.'
}

$listeners = New-Object 'System.Collections.Generic.List[System.Net.Sockets.TcpListener]'
try {
    foreach ($port in @($preferred, ($preferred + 1))) {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
        [void]($listener.Server.ExclusiveAddressUse = $true)
        $listener.Start()
        [void]$listeners.Add($listener)
    }
    if (Test-Tpf2mpLoopbackPortPairAvailable -Port $preferred) {
        throw 'An occupied relay port pair was reported as available.'
    }
    $remapped = Find-Tpf2mpFreeLoopbackPortPair -PreferredPort $preferred
    if ($remapped -eq $preferred -or $remapped -lt 1 -or $remapped -gt 65534 `
            -or -not (Test-Tpf2mpLoopbackPortPairAvailable -Port $remapped)) {
        throw 'Relay Join did not remap an occupied local port pair safely.'
    }
}
finally {
    foreach ($listener in $listeners) {
        try { $listener.Stop() } catch { }
    }
}

if ((Find-Tpf2mpFreeLoopbackPortPair -PreferredPort $preferred) -ne $preferred) {
    throw 'Relay port selection did not return to the preferred pair after release.'
}

Write-Host 'PASS relay Join remaps occupied host loopback ports to a free adjacent pair'
