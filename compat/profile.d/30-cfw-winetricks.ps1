# Optional Chocolatey-for-Wine winetricks entrypoint.
# The implementation remains an independently versioned asset.

function Invoke-CfwWinetricks {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [object[]] $ArgumentList
    )

    $scriptPath = Join-Path $env:ProgramData 'Chocolatey-for-wine\winetricks.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Chocolatey-for-Wine winetricks script is missing: $scriptPath"
    }

    & $scriptPath @ArgumentList
}

Set-Alias -Name winetricks -Value Invoke-CfwWinetricks -Scope Global -Force
