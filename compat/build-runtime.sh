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
evidence_name="${CFW_RUNTIME_EVIDENCE_NAME:-runtime.json}"
manifest_name="${CFW_RUNTIME_MANIFEST_NAME:-cfw-runtime-manifest.json}"
metadata="$output_root/$evidence_name"
manifest="$output_root/$manifest_name"
runtime_inputs="$repo_root/compat/runtime-inputs.json"
artifact_name="${CFW_RUNTIME_ARTIFACT_NAME:-cfw-runtime-prefix}"
stage="setup"

for output_name in "$artifact_name" "$evidence_name" "$manifest_name"; do
  case "$output_name" in
    *[!A-Za-z0-9._-]* | '')
      echo "[cfw] invalid runtime output name: $output_name" >&2
      exit 64
      ;;
  esac
done

[[ -f "$runtime_inputs" ]] || {
  echo "[cfw] runtime inputs file is missing: $runtime_inputs" >&2
  exit 65
}

mkdir -p "$output_root" "$payload_cache" "$release_root" "$logs"
export WINEPREFIX="$wine_prefix"
export WINEARCH=win64
unset CFW_CONTAINER_BUILDER
unset WINEDLLOVERRIDES

CFW_RUNTIME_INPUTS_SHA256="$(sha256sum "$runtime_inputs" | awk '{print $1}')"
CFW_SOURCE_REVISION="${CFW_SOURCE_REVISION:?CFW_SOURCE_REVISION must be the exact source commit}"
CFW_WINE_IMAGE="${CFW_WINE_IMAGE:?CFW_WINE_IMAGE must be the digest-pinned Wine producer image}"
if [[ ! "$CFW_SOURCE_REVISION" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
  echo "[cfw] CFW_SOURCE_REVISION must be a full lowercase Git commit SHA" >&2
  exit 64
fi
if [[ ! "$CFW_WINE_IMAGE" =~ ^ghcr\.io/pelagians/cage-wine@sha256:[0-9a-f]{64}$ ]]; then
  echo "[cfw] CFW_WINE_IMAGE must be a ghcr.io/pelagians/cage-wine digest" >&2
  exit 64
fi
export CFW_RUNTIME_INPUTS_SHA256 CFW_SOURCE_REVISION CFW_WINE_IMAGE

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

input_value() {
  local section="$1" field="$2"
  python3 - "$runtime_inputs" "$section" "$field" <<'PY2'
import json
import re
import sys

path, section, field = sys.argv[1:]
try:
    value = json.load(open(path, encoding="utf-8"))["downloads"][section][field]
except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid runtime input {section}.{field}: {exc}")
if not isinstance(value, str) or not value:
    raise SystemExit(f"invalid runtime input {section}.{field}")
if field == "sha256" and not re.fullmatch(r"[0-9a-f]{64}", value):
    raise SystemExit(f"invalid runtime input digest {section}.{field}")
print(value)
PY2
}

checkout_source_sha256() {
  local source_name="$1"
  python3 - "$runtime_inputs" "$source_name" <<'PY2'
import json
import re
import sys

path, source_name = sys.argv[1:]
try:
    value = json.load(open(path, encoding="utf-8"))["checkoutSources"][source_name]["sha256"]
except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid checkout source {source_name}: {exc}")
if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
    raise SystemExit(f"invalid checkout source digest {source_name}")
print(value)
PY2
}

verify_checkout_source() {
  local source_name="$1" source_path="$2" expected actual
  expected="$(checkout_source_sha256 "$source_name")"
  actual="$(sha256sum "$source_path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    printf '[cfw] checkout source checksum mismatch: %s\nexpected=%s\nactual=%s\n' \
      "$source_name" "$expected" "$actual" >&2
    return 69
  fi
}

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

fetch_input() {
  local input_name="$1" destination="$2"
  fetch_verified "$(input_value "$input_name" url)" "$(input_value "$input_name" sha256)" "$destination"
}

write_cfw_profile_loader() {
  local pwsh_dir="$1" fragment_root legacy_profile profile
  fragment_root="$wine_prefix/drive_c/ProgramData/Chocolatey-for-wine/profile.d"
  legacy_profile="$pwsh_dir/cfw-legacy-profile.ps1"
  profile="$pwsh_dir/profile.ps1"
  mkdir -p "$fragment_root"
  cp -f "$repo_root"/compat/profile.d/*.ps1 "$fragment_root/"
  if [[ -f "$profile" && ! -f "$legacy_profile" ]]; then
    mv "$profile" "$legacy_profile"
  fi
  cat > "$profile" <<'PS1'
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
PS1
  test -s "$profile"
  test -f "$fragment_root/20-chocolatey.ps1"
  test -f "$fragment_root/30-cfw-winetricks.ps1"
  test -f "$fragment_root/40-cfw-command-adapters.ps1"
}

build_smoke_package() {
  local smoke_feed="$1" smoke_package="$smoke_feed/cfw-runtime-smoke.0.1.0.nupkg"
  mkdir -p "$smoke_feed"
  python3 - "$smoke_package" <<'PY2'
from pathlib import Path
import sys
import zipfile

archive = Path(sys.argv[1])
install = r'''$marker = Join-Path $env:ProgramData 'CFW\RuntimeProbe\chocolatey-install.txt'
[IO.Directory]::CreateDirectory((Split-Path -Parent $marker)) | Out-Null
[IO.File]::WriteAllText($marker, 'installed')
'''
uninstall = r'''$marker = Join-Path $env:ProgramData 'CFW\RuntimeProbe\chocolatey-uninstall.txt'
[IO.Directory]::CreateDirectory((Split-Path -Parent $marker)) | Out-Null
[IO.File]::WriteAllText($marker, 'uninstalled')
'''
nuspec = '''<?xml version="1.0"?>
<package><metadata><id>cfw-runtime-smoke</id><version>0.1.0</version><title>CFW runtime smoke</title><authors>CFW</authors><description>Deterministic CFW runtime lifecycle proof.</description></metadata></package>
'''
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as package:
    package.writestr("cfw-runtime-smoke.nuspec", nuspec)
    package.writestr("tools/chocolateyinstall.ps1", install)
    package.writestr("tools/chocolateyuninstall.ps1", uninstall)
PY2
  test -s "$smoke_package"
}

mark_stage fetch-inputs
release_archive="$work/$(input_value cfwRelease filename)"
fetch_input cfwRelease "$release_archive"
rm -rf "$release_root"
mkdir -p "$release_root"
7z x -y "$release_archive" "-o$release_root" >"$logs/release-extract.log"
[[ -f "$release_dir/ChoCinstaller_0.5c.755.exe" ]]
verify_checkout_source choc_install.ps1 "$repo_root/choc_install.ps1"
cp -f "$repo_root/choc_install.ps1" "$release_dir/choc_install.ps1"

for input_name in chocolatey powershell dotnet mscoree d3d64 d3d32 conemu sevenZipExtractor windowsPowerShell; do
  fetch_input "$input_name" "$payload_cache/$(input_value "$input_name" filename)"
done

mark_stage initialize-prefix
# Cage Wine initializes fresh prefixes with these overrides to prevent Mono/HTML
# first-run setup from blocking wineboot. Clear them immediately afterwards so
# CFW's .NET, CLR, and PowerShell work uses its own compatibility policy.
export WINEDLLOVERRIDES="mscoree,mshtml="
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

# CFW owns the post-bootstrap compatibility policy. Do not carry the Wineboot
# suppression into installer, CLR, Synchro, or external PowerShell execution.
export WINEDLLOVERRIDES=""

mark_stage install-cfw
export CFW_CACHE="$(winepath -w "$work")"
export CFW_OFFLINE=1
installer_win="$(winepath -w "$release_dir/ChoCinstaller_0.5c.755.exe")"
set +e
timeout --kill-after=30s "${CFW_INSTALL_TIMEOUT:-7200s}" wine "$installer_win" /s /q >"$logs/installer.log" 2>&1
installer_rc="$?"
timeout --kill-after=15s 300s wineserver -w >>"$logs/installer.log" 2>&1
installer_settle_rc="$?"
set -e

pwsh="$wine_prefix/drive_c/Program Files/PowerShell/7/pwsh.exe"
choco="$wine_prefix/drive_c/ProgramData/chocolatey/bin/choco.exe"
wrapper64="$wine_prefix/drive_c/windows/system32/WindowsPowerShell/v1.0/powershell.exe"
wrapper32="$wine_prefix/drive_c/windows/syswow64/WindowsPowerShell/v1.0/powershell.exe"

if [[ "$installer_rc" -ne 0 || "$installer_settle_rc" -ne 0 ]]; then
  printf 'CFW installer failed: installer=%s settle=%s\n' "$installer_rc" "$installer_settle_rc" >&2
  tail -160 "$logs/installer.log" >&2 || true
  exit 70
fi
[[ -s "$pwsh" && -s "$choco" ]] || {
  printf 'CFW output incomplete: pwsh=%s choco=%s\n' "$pwsh" "$choco" >&2
  exit 70
}

mark_stage prove-pwsh
probe_dir="$wine_prefix/drive_c/ProgramData/CFW/RuntimeProbe"
pwsh_marker="$probe_dir/pwsh.txt"
mkdir -p "$probe_dir"
rm -f "$pwsh_marker"
pwsh_marker_win="$(winepath -w "$pwsh_marker")"
set +e
timeout --kill-after=15s 300s wine "$pwsh" -NoLogo -NoProfile -NonInteractive -Command \
  "[IO.File]::WriteAllText('$pwsh_marker_win',\$PSVersionTable.PSVersion.ToString()); [Console]::Out.WriteLine('[cfw] pwsh=' + \$PSVersionTable.PSVersion.ToString())" \
  >"$logs/pwsh-probe.log" 2>&1
pwsh_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/pwsh-probe.log" 2>&1
pwsh_settle_rc="$?"
set -e
if [[ "$pwsh_rc" -ne 0 || "$pwsh_settle_rc" -ne 0 || ! -s "$pwsh_marker" ]]; then
  printf 'PowerShell runtime proof failed: process=%s settle=%s marker=%s\n' "$pwsh_rc" "$pwsh_settle_rc" "$pwsh_marker" >&2
  cat "$logs/pwsh-probe.log" >&2 || true
  exit 70
fi

mark_stage install-synchro
synchro_cache="$work/synchro-v4.2.0"
fetch_input synchro64 "$synchro_cache/powershell64.exe"
fetch_input synchro32 "$synchro_cache/powershell32.exe"
mkdir -p "$(dirname "$wrapper64")" "$(dirname "$wrapper32")"
cp -f "$synchro_cache/powershell64.exe" "$wrapper64"
cp -f "$synchro_cache/powershell32.exe" "$wrapper32"
write_cfw_profile_loader "$(dirname "$pwsh")"

mark_stage prove-runtime
choco_win='C:\ProgramData\chocolatey\bin\choco.exe'
synchro64_marker="$probe_dir/synchro-x64.txt"
synchro32_marker="$probe_dir/synchro-x86.txt"
smoke_install_marker="$probe_dir/chocolatey-install.txt"
smoke_uninstall_marker="$probe_dir/chocolatey-uninstall.txt"
rm -f "$synchro64_marker" "$synchro32_marker" "$smoke_install_marker" "$smoke_uninstall_marker"
synchro64_marker_win="$(winepath -w "$synchro64_marker")"
synchro32_marker_win="$(winepath -w "$synchro32_marker")"
smoke_feed="$work/smoke-feed"
build_smoke_package "$smoke_feed"
smoke_feed_win="$(winepath -w "$smoke_feed")"

set +e
timeout --kill-after=15s 300s wine "$choco_win" feature disable --name=powershellHost >"$logs/choco-feature-policy.log" 2>&1
feature_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/choco-feature-policy.log" 2>&1
feature_settle_rc="$?"
timeout --kill-after=15s 300s wine "$choco_win" feature list --limit-output >"$logs/choco-feature-status.log" 2>&1
feature_status_command_rc="$?"
grep -Eiq '^powershellHost\|(disabled|false)$' "$logs/choco-feature-status.log"
feature_status_rc="$?"
timeout --kill-after=15s 300s wine "$choco_win" --version >"$logs/choco-version.log" 2>&1
choco_rc="$?"
timeout --kill-after=15s 300s wine "$wrapper64" -NoLogo -NoProfile -NonInteractive -Command "[IO.File]::WriteAllText('$synchro64_marker_win', 'synchro-x64')" >"$logs/synchro-x64.log" 2>&1
synchro64_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/synchro-x64.log" 2>&1
synchro64_settle_rc="$?"
timeout --kill-after=15s 300s wine "$wrapper32" -NoLogo -NoProfile -NonInteractive -Command "[IO.File]::WriteAllText('$synchro32_marker_win', 'synchro-x86')" >"$logs/synchro-x86.log" 2>&1
synchro32_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/synchro-x86.log" 2>&1
synchro32_settle_rc="$?"
timeout --kill-after=30s 600s wine "$choco_win" install cfw-runtime-smoke -y --source "$smoke_feed_win" >"$logs/choco-smoke-install.log" 2>&1
smoke_install_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/choco-smoke-install.log" 2>&1
smoke_install_settle_rc="$?"
timeout --kill-after=30s 600s wine "$choco_win" uninstall cfw-runtime-smoke -y >"$logs/choco-smoke-uninstall.log" 2>&1
smoke_uninstall_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/choco-smoke-uninstall.log" 2>&1
smoke_uninstall_settle_rc="$?"
set -e

python3 - "$metadata" \
  "$installer_rc" "$installer_settle_rc" "$pwsh_rc" "$pwsh_settle_rc" \
  "$feature_rc" "$feature_settle_rc" "$feature_status_command_rc" "$feature_status_rc" "$choco_rc" \
  "$synchro64_rc" "$synchro64_settle_rc" "$synchro32_rc" "$synchro32_settle_rc" \
  "$smoke_install_rc" "$smoke_install_settle_rc" "$smoke_uninstall_rc" "$smoke_uninstall_settle_rc" \
  "$pwsh_marker" "$synchro64_marker" "$synchro32_marker" "$smoke_install_marker" "$smoke_uninstall_marker" <<'PY2'
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

path = Path(sys.argv[1])
values = [int(value) for value in sys.argv[2:19]]
markers = [Path(value) for value in sys.argv[19:]]
keys = [
    "installer", "installerSettle", "pwsh", "pwshSettle", "featurePolicy",
    "featurePolicySettle", "featurePolicyStatusCommand", "featurePolicyStatus",
    "chocolateyVersion", "synchroX64", "synchroX64Settle", "synchroX86",
    "synchroX86Settle", "smokeInstall", "smokeInstallSettle", "smokeUninstall",
    "smokeUninstallSettle",
]
return_codes = dict(zip(keys, values))
marker_hashes = {
    marker.name: hashlib.sha256(marker.read_bytes()).hexdigest()
    for marker in markers
    if marker.is_file() and marker.stat().st_size > 0
}
checks = {
    "installer": values[0] == 0 and values[1] == 0,
    "pwsh": values[2] == 0 and values[3] == 0 and "pwsh.txt" in marker_hashes,
    "featurePolicy": values[4] == 0 and values[5] == 0 and values[6] == 0 and values[7] == 0,
    "chocolatey": values[8] == 0,
    "synchroX64": values[9] == 0 and values[10] == 0 and "synchro-x64.txt" in marker_hashes,
    "synchroX86": values[11] == 0 and values[12] == 0 and "synchro-x86.txt" in marker_hashes,
    "chocolateyLifecycle": values[13] == 0 and values[14] == 0 and values[15] == 0 and values[16] == 0 and "chocolatey-install.txt" in marker_hashes and "chocolatey-uninstall.txt" in marker_hashes,
}
record = {
    "schemaVersion": "cfw.runtime-build/v2",
    "provider": "cfw-chocolatey-runtime",
    "runtimeId": "cfw-chocolatey-2.6.0-powershell-7.5.5-synchro-4.2.0",
    "status": "passed" if all(checks.values()) else "failed",
    "wine": {"image": os.environ["CFW_WINE_IMAGE"], "version": subprocess.run(["wine", "--version"], text=True, capture_output=True).stdout.strip(), "architecture": "win64"},
    "sourceRevision": os.environ["CFW_SOURCE_REVISION"],
    "runtimeInputsSha256": os.environ["CFW_RUNTIME_INPUTS_SHA256"],
    "profileLoader": {"path": "C:\\Program Files\\PowerShell\\7\\profile.ps1", "applicationExtensionPath": "C:\\ProgramData\\Chocolatey-for-wine\\application-profile.d"},
    "powershell": "7.5.5",
    "synchro": "v4.2.0",
    "chocolatey": "2.6.0",
    "checks": checks,
    "returnCodes": return_codes,
    "markerSha256": marker_hashes,
}
path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
if record["status"] != "passed":
    raise SystemExit(70)
PY2

mark_stage package-runtime
mkdir -p "$wine_prefix/.cfw"
cp -f "$metadata" "$wine_prefix/.cfw/runtime.json"
archive="$output_root/$artifact_name.tar.gz"
tar -C "$wine_prefix" -czf "$archive.part" .
mv -f "$archive.part" "$archive"
archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
printf '%s  %s\n' "$archive_sha256" "$(basename "$archive")" > "$archive.sha256"

python3 - "$metadata" "$manifest" "$archive" "$archive_sha256" <<'PY2'
import hashlib
import json
import os
import sys
from pathlib import Path

evidence_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
archive_path = Path(sys.argv[3])
archive_sha256 = sys.argv[4]
evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
manifest = {
    "schemaVersion": "cfw.prepared-runtime-manifest/v1",
    "runtimeId": evidence["runtimeId"],
    "contract": "cfw.compatibility-contract/v3",
    "archive": {"filename": archive_path.name, "sha256": archive_sha256, "bytes": archive_path.stat().st_size},
    "runtimeEvidence": {"filename": evidence_path.name, "sha256": hashlib.sha256(evidence_path.read_bytes()).hexdigest()},
    "sourceRevision": evidence["sourceRevision"],
    "runtimeInputsSha256": evidence["runtimeInputsSha256"],
    "wine": evidence["wine"],
    "profileLoader": evidence["profileLoader"],
    "status": evidence["status"],
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY2
mark_stage complete
printf '[cfw] runtime artifact ready: %s\n' "$archive"
