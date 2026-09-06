function Get-Tpf2mpLuaSchemaConstant {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $source = [IO.File]::ReadAllText([IO.Path]::GetFullPath($Path))
    $pattern = '(?m)^[ \t]*' + [regex]::Escape($Name) + '[ \t]*=[ \t]*(?<value>[^\r\n]*)'
    $declarations = [regex]::Matches($source, $pattern)
    if ($declarations.Count -ne 1) {
        throw "Expected exactly one literal $Name declaration in $Path."
    }
    $literal = [regex]::Match($declarations[0].Groups['value'].Value,
        '^(?<number>[0-9]+)[ \t]*,?[ \t]*(?:--.*)?$')
    $number = 0
    if (-not $literal.Success -or
            -not [int]::TryParse($literal.Groups['number'].Value, [ref]$number) -or $number -lt 1) {
        throw "Expected a positive integer literal for $Name in $Path."
    }
    return $number
}
