#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_root="${1:-$repo_root/dist/cfw-runtime}"
wine_prefix="${WINEPREFIX:-$output_root/prefix}"
work="${CFW_BUILD_CACHE:-$output_root/cache}"
payload_cache="$work/choc_install_files"
release_root="$work/release"
release_dir="$release_root/Chocolatey-for-wine"
logs="$output_root/logs"
metadata="$output_root/runtime.json"
stage="setup"

mkdir -p "$output_root" "$payload_cache" "$release_root" "$logs"
export WINEPREFIX="$wine_prefix"
export WINEARCH=win64
unset CFW_CONTAINER_BUILDER
unset WINEDLLOVERRIDES

on_error() {
  rc="$?"
  printf '[cfw] ERROR stage=%s rc=%s\n' "$stage" "$rc" | tee -a "$logs/build-stages.log" >&2
  exit "$rc"
}
trap on_error ERR

mark_stage() {
  stage="$1"
  printf '[cfw] stage=%s\n' "$stage" | tee -a "$logs/build-stages.log"
}

CFW_RELEASE_URL='https://github.com/noahgiroux/Chocolatey-for-wine/releases/download/v0.5c.755-noah.6/Chocolatey-for-wine.7z'
CFW_RELEASE_SHA256='25c2e3cd544c7f83e9c196a5b8b0f98e020b4f5e24f19de30ea6ceec585d0792'
CHOCOLATEY_URL='https://community.chocolatey.org/api/v2/package/chocolatey/2.6.0'
CHOCOLATEY_SHA256='f13a2af9cd4ec2c9b58d81861bc95ad7151e3a871d8f758dffa72a996a3792d8'
POWERSHELL_URL='https://github.com/PowerShell/PowerShell/releases/download/v7.5.5/PowerShell-7.5.5-win-x64.msi'
POWERSHELL_SHA256='b2ac56b7639e2b259bb78bab077555d76f2a5eec6c516690d63de36bc1d6ca25'
DOTNET_URL='https://download.visualstudio.microsoft.com/download/pr/7afca223-55d2-470a-8edc-6a1739ae3252/abd170b4b0ec15ad0222a809b761a036/ndp48-x86-x64-allos-enu.exe'
DOTNET_SHA256='95889d6de3f2070c07790ad6cf2000d33d9a1bdfc6a381725ab82ab1c314fd53'
MSCOREE_URL='https://catalog.s.download.windowsupdate.com/msdownload/update/software/crup/2010/06/windows6.1-kb958488-v6001-x64_a137e4f328f01146dfa75d7b5a576090dee948dc.msu'
MSCOREE_SHA256='a5f4243ce8b07c9222284fd8ff6f7e742d934c57c89de9cab5d88c74402264e3'
D3D64_URL='https://github.com/mozilla/fxc2/raw/master/dll/d3dcompiler_47.dll'
D3D64_SHA256='4432bbd1a390874f3f0a503d45cc48d346abc3a8c0213c289f4b615bf0ee84f3'
D3D32_URL='https://github.com/mozilla/fxc2/raw/master/dll/d3dcompiler_47_32.dll'
D3D32_SHA256='2ad0d4987fc4624566b190e747c9d95038443956ed816abfd1e2d389b5ec0851'
CONEMU_URL='https://github.com/Maximus5/ConEmu/releases/download/v23.07.24/ConEmuPack.230724.7z'
CONEMU_SHA256='2a9b98ebecaede62665ef427b05b3a5ccdac7bd3202414fc0f4c10825b4f4ea2'
SEVENZIP_EXTRACTOR_URL='https://globalcdn.nuget.org/packages/sevenzipextractor.1.0.19.nupkg'
SEVENZIP_EXTRACTOR_SHA256='c660063da7a343115272de59591597d8cc12d320957b1636a210524d6a67b95b'
WINDOWS_POWERSHELL_URL='https://catalog.s.download.windowsupdate.com/msdownload/update/software/updt/2009/11/windowsserver2003-kb968930-x64-eng_8ba702aa016e4c5aed581814647f4d55635eff5c.exe'
WINDOWS_POWERSHELL_SHA256='9f5d24517f860837daaac062e5bf7e6978ceb94e4e9e8567798df6777b56e4c8'
SYNCHRO_BASE_URL='https://codeberg.org/Synchro/powershell-wrapper-for-wine/releases/download/v4.2.0'
SYNCHRO64_SHA256='b1d594bd44abc01007b9dd2adea5248f09906fa8d4c6cea7f36a4279e2de91e0'
SYNCHRO32_SHA256='ca76d774273ffa37053545f8e4ad63c8914461828f1d1eef7a1915c9656fed4c'

fetch_verified() {
  local url="$1" expected="$2" destination="$3"
  mkdir -p "$(dirname "$destination")"
  if [[ -f "$destination" ]] && [[ "$(sha256sum "$destination" | awk '{print $1}')" == "$expected" ]]; then
    return 0
  fi
  rm -f "$destination" "$destination.part"
  curl -fL --retry 4 --connect-timeout 30 --max-time 1800 -o "$destination.part" "$url"
  local actual
  actual="$(sha256sum "$destination.part" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'checksum mismatch for %s\nexpected=%s\nactual=%s\n' "$url" "$expected" "$actual" >&2
    return 69
  fi
  mv -f "$destination.part" "$destination"
}

mark_stage fetch-inputs
release_archive="$work/Chocolatey-for-wine.7z"
fetch_verified "$CFW_RELEASE_URL" "$CFW_RELEASE_SHA256" "$release_archive"
rm -rf "$release_root"
mkdir -p "$release_root"
7z x -y "$release_archive" "-o$release_root" >"$logs/release-extract.log"
[[ -f "$release_dir/ChoCinstaller_0.5c.755.exe" ]]
cp -f "$repo_root/choc_install.ps1" "$release_dir/choc_install.ps1"
cp -f "$repo_root/winetricks.ps1" "$work/winetricks.ps1"

fetch_verified "$CHOCOLATEY_URL" "$CHOCOLATEY_SHA256" "$payload_cache/chocolatey.2.6.0.nupkg"
fetch_verified "$POWERSHELL_URL" "$POWERSHELL_SHA256" "$payload_cache/PowerShell-7.5.5-win-x64.msi"
fetch_verified "$DOTNET_URL" "$DOTNET_SHA256" "$payload_cache/ndp48-x86-x64-allos-enu.exe"
fetch_verified "$MSCOREE_URL" "$MSCOREE_SHA256" "$payload_cache/windows6.1-kb958488-v6001-x64_a137e4f328f01146dfa75d7b5a576090dee948dc.msu"
fetch_verified "$D3D64_URL" "$D3D64_SHA256" "$payload_cache/d3dcompiler_47.dll"
fetch_verified "$D3D32_URL" "$D3D32_SHA256" "$payload_cache/d3dcompiler_47_32.dll"
fetch_verified "$CONEMU_URL" "$CONEMU_SHA256" "$payload_cache/ConEmuPack.230724.7z"
fetch_verified "$SEVENZIP_EXTRACTOR_URL" "$SEVENZIP_EXTRACTOR_SHA256" "$payload_cache/sevenzipextractor.1.0.19.nupkg"
fetch_verified "$WINDOWS_POWERSHELL_URL" "$WINDOWS_POWERSHELL_SHA256" "$payload_cache/windowsserver2003-kb968930-x64-eng_8ba702aa016e4c5aed581814647f4d55635eff5c.exe"

mark_stage initialize-prefix
rm -rf "$wine_prefix"
mkdir -p "$wine_prefix"
set +e
timeout --kill-after=15s 300s wine wineboot --init >"$logs/wineboot.log" 2>&1
wineboot_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/wineboot.log" 2>&1
wineboot_settle_rc="$?"
set -e
if [[ "$wineboot_rc" -ne 0 || "$wineboot_settle_rc" -ne 0 || ! -d "$wine_prefix/drive_c" ]]; then
  printf 'Wine prefix initialization failed: process=%s settle=%s\n' "$wineboot_rc" "$wineboot_settle_rc" >&2
  cat "$logs/wineboot.log" >&2 || true
  exit 70
fi

mark_stage install-cfw
export CFW_CACHE="$(winepath -w "$work")"
export CFW_OFFLINE=1
installer_win="$(winepath -w "$release_dir/ChoCinstaller_0.5c.755.exe")"
set +e
timeout --kill-after=30s "${CFW_INSTALL_TIMEOUT:-7200s}" wine "$installer_win" /s /q >"$logs/installer.log" 2>&1
installer_rc="$?"
timeout --kill-after=15s 300s wineserver -w >>"$logs/installer.log" 2>&1
settle_rc="$?"
set -e

pwsh="$wine_prefix/drive_c/Program Files/PowerShell/7/pwsh.exe"
choco="$wine_prefix/drive_c/ProgramData/chocolatey/bin/choco.exe"
wrapper64="$wine_prefix/drive_c/windows/system32/WindowsPowerShell/v1.0/powershell.exe"
wrapper32="$wine_prefix/drive_c/windows/syswow64/WindowsPowerShell/v1.0/powershell.exe"

if [[ "$installer_rc" -ne 0 || "$settle_rc" -ne 0 ]]; then
  printf 'CFW installer failed: installer=%s settle=%s\n' "$installer_rc" "$settle_rc" >&2
  tail -160 "$logs/installer.log" >&2 || true
  exit 70
fi
[[ -s "$pwsh" && -s "$choco" ]] || {
  printf 'CFW output incomplete: pwsh=%s choco=%s\n' "$pwsh" "$choco" >&2
  exit 70
}

mark_stage prove-pwsh
probe_dir="$wine_prefix/drive_c/ProgramData/CFW/RuntimeProbe"
probe_marker="$probe_dir/pwsh.txt"
mkdir -p "$probe_dir"
rm -f "$probe_marker"
probe_marker_win="$(winepath -w "$probe_marker")"
set +e
timeout --kill-after=15s 300s wine "$pwsh" -NoLogo -NoProfile -NonInteractive -Command \
  "[IO.File]::WriteAllText('$probe_marker_win',\$PSVersionTable.PSVersion.ToString()); [Console]::Out.WriteLine('[cfw] pwsh=' + \$PSVersionTable.PSVersion.ToString())" \
  >"$logs/pwsh-probe.log" 2>&1
pwsh_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/pwsh-probe.log" 2>&1
pwsh_settle_rc="$?"
set -e
if [[ "$pwsh_rc" -ne 0 || "$pwsh_settle_rc" -ne 0 || ! -s "$probe_marker" ]]; then
  printf 'PowerShell runtime proof failed: process=%s settle=%s marker=%s\n' "$pwsh_rc" "$pwsh_settle_rc" "$probe_marker" >&2
  cat "$logs/pwsh-probe.log" >&2 || true
  exit 70
fi

mark_stage install-synchro
synchro_cache="$work/synchro-v4.2.0"
fetch_verified "$SYNCHRO_BASE_URL/powershell64.exe" "$SYNCHRO64_SHA256" "$synchro_cache/powershell64.exe"
fetch_verified "$SYNCHRO_BASE_URL/powershell32.exe" "$SYNCHRO32_SHA256" "$synchro_cache/powershell32.exe"
mkdir -p "$(dirname "$wrapper64")" "$(dirname "$wrapper32")"
cp -f "$synchro_cache/powershell64.exe" "$wrapper64"
cp -f "$synchro_cache/powershell32.exe" "$wrapper32"

mark_stage prove-runtime
choco_win='C:\ProgramData\chocolatey\bin\choco.exe'
set +e
timeout --kill-after=15s 300s wine "$choco_win" feature disable --name=powershellHost >"$logs/choco-feature-policy.log" 2>&1
feature_rc="$?"
timeout --kill-after=15s 300s wine "$choco_win" --version >"$logs/choco-version.log" 2>&1
choco_rc="$?"
timeout --kill-after=15s 300s wine "$wrapper64" -NoLogo -NonInteractive -Command 'Write-Output "[cfw] synchro-x64-ok"' >"$logs/synchro-x64.log" 2>&1
synchro64_rc="$?"
timeout --kill-after=15s 300s wine "$wrapper32" -NoLogo -NonInteractive -Command 'Write-Output "[cfw] synchro-x86-ok"' >"$logs/synchro-x86.log" 2>&1
synchro32_rc="$?"
timeout --kill-after=10s 120s wineserver -w >"$logs/final-settle.log" 2>&1
final_settle_rc="$?"
set -e

set +e
tr -d '\r' <"$logs/synchro-x64.log" | grep -Fqx '[cfw] synchro-x64-ok'
synchro64_marker_rc="$?"
tr -d '\r' <"$logs/synchro-x86.log" | grep -Fqx '[cfw] synchro-x86-ok'
synchro32_marker_rc="$?"
set -e

python3 - "$metadata" "$installer_rc" "$settle_rc" "$pwsh_rc" "$pwsh_settle_rc" "$feature_rc" "$choco_rc" "$synchro64_rc" "$synchro32_rc" "$synchro64_marker_rc" "$synchro32_marker_rc" "$final_settle_rc" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

path = Path(sys.argv[1])
values = [int(value) for value in sys.argv[2:]]
keys = [
    "installer", "installerSettle", "pwsh", "pwshSettle", "featurePolicy",
    "chocolateyVersion", "synchroX64", "synchroX86", "synchroX64Marker",
    "synchroX86Marker", "finalSettle",
]
return_codes = dict(zip(keys, values))
checks = {
    "installer": values[0] == 0 and values[1] == 0,
    "pwsh": values[2] == 0 and values[3] == 0,
    "chocolatey": values[5] == 0,
    "synchroX64": values[6] == 0 and values[8] == 0,
    "synchroX86": values[7] == 0 and values[9] == 0,
    "finalSettle": values[10] == 0,
}
record = {
    "schemaVersion": "cfw.runtime-build/v1",
    "provider": "cfw-chocolatey-runtime",
    "runtimeId": "cfw-chocolatey-2.6.0-powershell-7.5.5-synchro-4.2.0",
    "status": "passed" if all(checks.values()) else "failed",
    "wineVersion": subprocess.run(["wine", "--version"], text=True, capture_output=True).stdout.strip(),
    "powershell": "7.5.5",
    "synchro": "v4.2.0",
    "chocolatey": "2.6.0",
    "checks": checks,
    "returnCodes": return_codes,
}
path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
if record["status"] != "passed":
    raise SystemExit(70)
PY

mark_stage package-runtime
mkdir -p "$wine_prefix/.cfw"
cp -f "$metadata" "$wine_prefix/.cfw/runtime.json"
archive="$output_root/cfw-runtime-prefix.tar.gz"
tar -C "$wine_prefix" -czf "$archive.part" .
mv -f "$archive.part" "$archive"
sha256sum "$archive" >"$archive.sha256"
mark_stage complete
printf '[cfw] runtime artifact ready: %s\n' "$archive"
