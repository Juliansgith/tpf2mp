[CmdletBinding()]
param(
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [string]$GameExecutable = 'F:\SteamLibrary\steamapps\common\Transport Fever 2\TransportFever2.exe',
    [string]$BuildDirectory
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $projectRoot 'native'
$build = if ($BuildDirectory) {
    [IO.Path]::GetFullPath($BuildDirectory)
} else {
    Join-Path $projectRoot 'runtime\native-build'
}
$game = [IO.Path]::GetFullPath($GameExecutable)

if (-not (Test-Path -LiteralPath $game -PathType Leaf)) {
    throw "Transport Fever 2 executable not found: $game"
}

& cmake -S $source -B $build -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) { throw "Native CMake configure failed with exit code $LASTEXITCODE" }
& cmake --build $build --config $Configuration --parallel
if ($LASTEXITCODE -ne 0) { throw "Native build failed with exit code $LASTEXITCODE" }
& ctest --test-dir $build -C $Configuration --output-on-failure
if ($LASTEXITCODE -ne 0) { throw "Native CTest failed with exit code $LASTEXITCODE" }

$bin = Join-Path $build $Configuration
$profileTest = Join-Path $bin 'tpf2mp_native_tests.exe'
$injector = Join-Path $bin 'tpf2mp_injector.exe'
$dll = Join-Path $bin 'tpf2mp_hook_build35924.dll'
foreach ($path in @($profileTest, $injector, $dll)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Expected native artifact is missing: $path" }
}

& $profileTest $game
if ($LASTEXITCODE -ne 0) { throw "Pinned binary/signature test failed with exit code $LASTEXITCODE" }
& $injector --verify $game
if ($LASTEXITCODE -ne 0) { throw "Injector build gate failed with exit code $LASTEXITCODE" }

[pscustomobject]@{
    Configuration = $Configuration
    GameExecutable = $game
    Injector = $injector
    HookDll = $dll
    Profile = 'Build 35924 / SHA-256 782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c'
} | Format-List
