param(
    [Parameter(Mandatory = $true)][string] $FragmentSource,
    [Parameter(Mandatory = $true)][string] $MarkerPath
)

$ErrorActionPreference = 'Stop'
[Console]::Out.WriteLine('[cfw] stage=prepared-finalizer-script-entry')

$chocolateyRoot = Join-Path $env:ProgramData 'chocolatey'
$chocolateyBin = Join-Path $chocolateyRoot 'bin'
$choco = Join-Path $chocolateyBin 'choco.exe'
if (-not (Test-Path -LiteralPath $choco -PathType Leaf)) {
    throw "canonical Chocolatey executable is missing: $choco"
}

[Environment]::SetEnvironmentVariable('ChocolateyInstall', $chocolateyRoot, 'Machine')
[Environment]::SetEnvironmentVariable('ChocolateyToolsLocation', 'C:\tools', 'Machine')
$env:ChocolateyInstall = $chocolateyRoot
$env:ChocolateyToolsLocation = 'C:\tools'
if (($env:Path -split ';') -notcontains $chocolateyBin) {
    $env:Path = $env:Path.TrimEnd(';') + ';' + $chocolateyBin
}

$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if (-not $machinePath) { $machinePath = '' }
if (($machinePath -split ';') -notcontains $chocolateyBin) {
    $machinePath = $machinePath.TrimEnd(';') + ';' + $chocolateyBin
    [Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')
}

$profileRoot = Join-Path $env:ProgramData 'Chocolatey-for-wine\profile.d'
$applicationProfileRoot = Join-Path $env:ProgramData 'Chocolatey-for-wine\application-profile.d'
New-Item -ItemType Directory -Force -Path $profileRoot, $applicationProfileRoot | Out-Null

$requiredFragments = @(
    '20-chocolatey.ps1',
    '30-cfw-winetricks.ps1',
    '40-cfw-command-adapters.ps1'
)
foreach ($name in $requiredFragments) {
    $source = Join-Path $FragmentSource $name
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "prepared-runtime profile fragment is missing: $source"
    }
    Copy-Item -LiteralPath $source -Destination (Join-Path $profileRoot $name) -Force
}

$pwshRoot = $PSHOME
$profile = Join-Path $pwshRoot 'profile.ps1'
$legacyProfile = Join-Path $pwshRoot 'cfw-legacy-profile.ps1'
if ((Test-Path -LiteralPath $profile -PathType Leaf) -and
    -not (Test-Path -LiteralPath $legacyProfile -PathType Leaf)) {
    Move-Item -LiteralPath $profile -Destination $legacyProfile
}

@'
$legacyProfile = Join-Path $PSScriptRoot 'cfw-legacy-profile.ps1'
if (Test-Path -LiteralPath $legacyProfile -PathType Leaf) { . $legacyProfile }
$cfwProfileRoot = Join-Path $env:ProgramData 'Chocolatey-for-wine\profile.d'
if (Test-Path -LiteralPath $cfwProfileRoot -PathType Container) {
    Get-ChildItem -LiteralPath $cfwProfileRoot -Filter '*.ps1' -File | Sort-Object -Property Name | ForEach-Object { . $_.FullName }
}
$cfwApplicationProfileRoot = Join-Path $env:ProgramData 'Chocolatey-for-wine\application-profile.d'
if (Test-Path -LiteralPath $cfwApplicationProfileRoot -PathType Container) {
    Get-ChildItem -LiteralPath $cfwApplicationProfileRoot -Filter '*.ps1' -File | Sort-Object -Property Name | ForEach-Object { . $_.FullName }
}
Remove-Variable legacyProfile, cfwProfileRoot, cfwApplicationProfileRoot -ErrorAction SilentlyContinue
'@ | Set-Content -LiteralPath $profile -Encoding utf8

& $choco feature disable --name=powershellHost
if ($LASTEXITCODE -ne 0) {
    throw "failed to disable Chocolatey powershellHost: $LASTEXITCODE"
}

$markerParent = Split-Path -Parent $MarkerPath
New-Item -ItemType Directory -Force -Path $markerParent | Out-Null
[IO.File]::WriteAllText($MarkerPath, 'prepared')
[Console]::Out.WriteLine('[cfw] stage=prepared-finalizer-complete')
