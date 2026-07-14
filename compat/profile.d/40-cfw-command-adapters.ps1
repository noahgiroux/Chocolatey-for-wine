# Load optional Chocolatey-for-Wine command adapters without replacing the
# orchestrator-owned PowerShell profile or Synchro wrapper layer.

$adapterRoot = Join-Path $env:ProgramData 'Chocolatey-for-wine\command-adapters'
if (Test-Path -LiteralPath $adapterRoot -PathType Container) {
    Get-ChildItem -LiteralPath $adapterRoot -Filter '*.ps1' -File |
        Sort-Object -Property Name |
        ForEach-Object {
            . $_.FullName
        }
}

Remove-Variable adapterRoot -ErrorAction SilentlyContinue
