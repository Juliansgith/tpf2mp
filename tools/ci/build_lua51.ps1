[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [string]$SourceUrl = 'https://www.lua.org/ftp/lua-5.1.5.tar.gz',
    [string]$Tarball,
    [string]$ExpectedSha256 = '2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333'
)

# Builds a stock Lua 5.1.5 interpreter with MSVC for the automated code gate.
# The game embeds Lua 5.1, the test suites are written against it, and hosted
# runners ship no Lua at all. The result is a single static-CRT lua.exe plus
# Lua's COPYRIGHT; nothing here is redistributed in a release.

$ErrorActionPreference = 'Stop'

$output = [IO.Path]::GetFullPath($OutputDirectory)
$work = Join-Path $output 'build'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null

if (-not $Tarball) {
    $Tarball = Join-Path $work 'lua-5.1.5.tar.gz'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $SourceUrl -OutFile $Tarball -UseBasicParsing
}
$actualSha256 = (Get-FileHash -LiteralPath $Tarball -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
    throw "Lua source archive digest mismatch: expected $ExpectedSha256, got $actualSha256"
}

& tar.exe -xzf $Tarball -C $work
if ($LASTEXITCODE -ne 0) { throw "Extracting $Tarball failed with exit code $LASTEXITCODE" }
$sourceRoot = Join-Path $work 'lua-5.1.5'
$source = Join-Path $sourceRoot 'src'
if (-not (Test-Path -LiteralPath (Join-Path $source 'lua.c') -PathType Leaf)) {
    throw "Lua source tree is incomplete under $source"
}

# Prefer a compiler that is already on PATH (a developer prompt or an msvc
# setup action); otherwise locate the newest Visual Studio C++ toolset.
$vcvars = $null
if (-not (Get-Command cl.exe -CommandType Application -ErrorAction SilentlyContinue)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'cl.exe is not on PATH and vswhere.exe is unavailable; install the Visual Studio C++ toolset.'
    }
    $installation = & $vswhere -latest -products * `
        -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $installation) { throw 'No Visual Studio installation with the C++ x64 toolset was found.' }
    $vcvars = Join-Path ([string]$installation) 'VC\Auxiliary\Build\vcvars64.bat'
    if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) { throw "vcvars64.bat is missing: $vcvars" }
}

# Everything except the two front ends (lua.c, luac.c) and luac's print.c
# becomes the static core library; lua.exe links against it.
$coreSources = @(Get-ChildItem -LiteralPath $source -File -Filter '*.c' |
    Where-Object { $_.Name -notin @('lua.c', 'luac.c', 'print.c') } |
    Sort-Object Name | ForEach-Object { $_.Name })
$coreObjects = @($coreSources | ForEach-Object { [IO.Path]::ChangeExtension($_, '.obj') })
$flags = '/nologo /MT /O2 /W3 /D_CRT_SECURE_NO_DEPRECATE'
$lines = @('@echo off')
if ($vcvars) {
    # vcvars64.bat shells out to vswhere.exe by bare name; keep the installer
    # directory on PATH so it resolves instead of printing a harmless error.
    $installer = Split-Path -Parent $vswhere
    $lines += "set `"PATH=$installer;%PATH%`""
    $lines += "call `"$vcvars`" >nul"
    $lines += 'if errorlevel 1 exit /b 1'
}
$lines += @(
    "cd /d `"$source`"",
    "cl $flags /c $($coreSources -join ' ')",
    'if errorlevel 1 exit /b 1',
    "lib /nologo /out:lua51.lib $($coreObjects -join ' ')",
    'if errorlevel 1 exit /b 1',
    "cl $flags /c lua.c",
    'if errorlevel 1 exit /b 1',
    'link /nologo /out:lua.exe lua.obj lua51.lib',
    'if errorlevel 1 exit /b 1'
)
$buildScript = Join-Path $work 'build_lua51.cmd'
[IO.File]::WriteAllLines($buildScript, $lines, [Text.Encoding]::Default)
& cmd.exe /c $buildScript
if ($LASTEXITCODE -ne 0) { throw "Lua 5.1.5 build failed with exit code $LASTEXITCODE" }

$interpreter = Join-Path $output 'lua.exe'
Copy-Item -LiteralPath (Join-Path $source 'lua.exe') -Destination $interpreter -Force
Copy-Item -LiteralPath (Join-Path $sourceRoot 'COPYRIGHT') -Destination (Join-Path $output 'COPYRIGHT') -Force
# Lua 5.1 prints its banner on stderr; merge inside cmd so PowerShell's
# stop-on-error preference never sees a native stderr stream.
$version = [string](& cmd.exe /c "`"$interpreter`" -v 2>&1")
if ($version -notmatch 'Lua 5\.1') { throw "Built interpreter reported an unexpected version: $version" }
Remove-Item -LiteralPath $work -Recurse -Force
Write-Host "Built $interpreter ($version)"
