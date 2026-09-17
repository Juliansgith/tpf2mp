[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$GameExecutable,
    [Parameter(Mandatory = $true)][string]$HookDll,
    [string]$Python
)

# Proves the optional terrain fast paths against the pinned executable: each
# script in tests\native_terrain_fast maps TransportFever2.exe at its preferred
# base inside the test process, runs the stock routine as original machine
# code beside the hook DLL's replacement, and compares complete output buffers.
# Nothing is launched or installed. Needs numpy, capstone and pefile.

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$game = [IO.Path]::GetFullPath($GameExecutable)
$dll = [IO.Path]::GetFullPath($HookDll)
foreach ($path in @($game, $dll)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Terrain fast-path proof input is missing: $path" }
}

if (-not $Python) {
    if ($env:TPF2MP_PYTHON -and (Test-Path -LiteralPath $env:TPF2MP_PYTHON -PathType Leaf)) {
        $Python = $env:TPF2MP_PYTHON
    } else {
        $command = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { throw 'Python was not found; set TPF2MP_PYTHON or pass -Python' }
        $Python = $command.Source
    }
}
& $Python -c 'import numpy, capstone, pefile' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "The terrain fast-path proof needs numpy, capstone and pefile in $Python (pip install numpy capstone pefile), or pass -SkipTerrainFastProof to build_native_hook.ps1"
}

$proofs = @('align_proof.py', 'refine_proof.py', 'minmax_proof.py', 'material_proof.py')
foreach ($proof in $proofs) {
    $script = Join-Path $projectRoot "tests\native_terrain_fast\$proof"
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw "Proof script is missing: $script" }
    Write-Host "== $proof"
    & $Python $script --exe $game --dll $dll
    if ($LASTEXITCODE -ne 0) { throw "Terrain fast-path proof failed: $proof (exit code $LASTEXITCODE)" }
}
Write-Host "PASS terrain fast paths are bit-identical to the pinned executable's original code ($($proofs.Count) proofs)"
