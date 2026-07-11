# Chocolatey profile integration for an orchestrator-owned profile loader.
# This fragment intentionally does not install PowerShell or replace $PROFILE.

$chocolateyRoot = if ($env:ChocolateyInstall) {
    $env:ChocolateyInstall
}
else {
    Join-Path $env:ProgramData 'chocolatey'
}

$chocolateyProfile = Join-Path $chocolateyRoot 'helpers\chocolateyProfile.psm1'
if (Test-Path -LiteralPath $chocolateyProfile -PathType Leaf) {
    Import-Module -Name $chocolateyProfile -Force -ErrorAction Stop
}

Remove-Variable chocolateyRoot, chocolateyProfile -ErrorAction SilentlyContinue
