[CmdletBinding()]
param(
    [Parameter(Mandatory)]$Companion,
    [Parameter(Mandatory)][string]$SaveDirectory,
    [Parameter(Mandatory)][string]$SessionRoot
)

# Other sidecars can affect native Load Game. This is advisory: rejected Lua
# syntax may be valid mod data. Never execute sidecars or move user saves.
$ErrorActionPreference = 'Stop'
try {
    $arguments = @($Companion.Prefix) + @('inspect-save-directory', $SaveDirectory)
    $output = @(& $Companion.FilePath @arguments)
    if ($LASTEXITCODE -ne 0) { throw 'Save-browser metadata inspection failed.' }
    $report = ($output -join "`n") | ConvertFrom-Json
    $reportPath = Join-Path $SessionRoot 'save-browser-preflight.json'
    $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    if (@($report.issues).Count -gt 0 -or -not $report.complete) {
        Write-Warning "Native save-browser inspection found suspect or uninspected metadata. Report: $reportPath. Other saves can affect Load Game even when the selected save is valid. No files were changed; unsupported mod Lua is not necessarily damaged."
    }
}
catch { Write-Warning "Save-browser diagnostic unavailable: $_. Selected-save validation remains enforced." }
