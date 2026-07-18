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
compat_contract="$repo_root/compat/contract.json"
compiled_installer="${CFW_COMPILED_INSTALLER:-$repo_root/compat/ChoCinstaller-under-test.exe}"
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
[[ -f "$compat_contract" ]] || {
  echo "[cfw] compatibility contract is missing: $compat_contract" >&2
  exit 65
}
[[ -s "$compiled_installer" ]] || {
  echo "[cfw] compiled installer under test is missing: $compiled_installer" >&2
  exit 65
}

mkdir -p "$output_root" "$payload_cache" "$release_root" "$logs"
export WINEPREFIX="$wine_prefix"
export WINEARCH=win64
unset CFW_CONTAINER_BUILDER
unset WINEDLLOVERRIDES

CFW_RUNTIME_INPUTS_SHA256="$(sha256sum "$runtime_inputs" | awk '{print $1}')"
CFW_CONTRACT_SHA256="$(sha256sum "$compat_contract" | awk '{print $1}')"
CFW_INSTALLER_SHA256="$(sha256sum "$compiled_installer" | awk '{print $1}')"
CFW_SOURCE_REVISION="${CFW_SOURCE_REVISION:?CFW_SOURCE_REVISION must be the exact source commit}"
CFW_WINE_IMAGE="${CFW_WINE_IMAGE:?CFW_WINE_IMAGE must be the digest-pinned Wine producer image}"
CFW_EXPECTED_WINE_VERSION="${CFW_EXPECTED_WINE_VERSION:?CFW_EXPECTED_WINE_VERSION must bind the Wine artifact identity}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:?SOURCE_DATE_EPOCH must identify the exact source revision time}"
if [[ ! "$CFW_SOURCE_REVISION" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]]; then
  echo "[cfw] CFW_SOURCE_REVISION must be a full lowercase Git commit SHA" >&2
  exit 64
fi
if [[ ! "$CFW_WINE_IMAGE" =~ ^ghcr\.io/pelagians/cage-wine@sha256:[0-9a-f]{64}$ ]]; then
  echo "[cfw] CFW_WINE_IMAGE must be a ghcr.io/pelagians/cage-wine digest" >&2
  exit 64
fi
if [[ ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]]; then
  echo "[cfw] SOURCE_DATE_EPOCH must be a non-negative integer" >&2
  exit 64
fi
export CFW_RUNTIME_INPUTS_SHA256 CFW_CONTRACT_SHA256 CFW_INSTALLER_SHA256 CFW_SOURCE_REVISION CFW_WINE_IMAGE SOURCE_DATE_EPOCH

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

normalize_log() {
  local path="$1" normalized="${1}.normalized"
  tr -d '\r' < "$path" > "$normalized"
  mv -f "$normalized" "$path"
}

read_single_observed_line() {
  local label="$1" path="$2"
  local -a lines
  mapfile -t lines <"$path"
  if [[ "${#lines[@]}" -ne 1 || -z "${lines[0]}" ]]; then
    printf '[cfw] %s must emit exactly one non-empty normalized line\n' "$label" >&2
    return 65
  fi
  printf '%s\n' "${lines[0]}"
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

runtime_value() {
  local field="$1"
  python3 - "$runtime_inputs" "$field" <<'PY2'
import json
import re
import sys

path, field = sys.argv[1:]
try:
    value = json.load(open(path, encoding="utf-8"))[field]
except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid runtime input {field}: {exc}")
if not isinstance(value, str) or not value:
    raise SystemExit(f"invalid runtime input {field}")
if field == "runtimeId" and not re.fullmatch(r"[A-Za-z0-9._-]+", value):
    raise SystemExit("invalid runtimeId")
print(value)
PY2
}

runtime_version() {
  local component="$1"
  python3 - "$runtime_inputs" "$component" <<'PY2'
import json
import re
import sys

path, component = sys.argv[1:]
try:
    value = json.load(open(path, encoding="utf-8"))["versions"][component]
except (OSError, KeyError, TypeError, json.JSONDecodeError) as exc:
    raise SystemExit(f"invalid runtime version {component}: {exc}")
if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", value):
    raise SystemExit(f"invalid runtime version {component}")
print(value)
PY2
}

CFW_RUNTIME_ID="$(runtime_value runtimeId)"
mapfile -t contract_identity < <(python3 - "$compat_contract" <<'PY2'
import json
import re
import sys
contract = json.load(open(sys.argv[1], encoding="utf-8"))
if contract.get("schemaVersion") != "cfw.compatibility-contract/v3":
    raise SystemExit("invalid compatibility contract schema")
candidates = contract["build"]["wineCandidates"]
if not isinstance(candidates, list) or len(candidates) != 1:
    raise SystemExit("Phase 1 compatibility contract must declare exactly one Wine candidate")
value = candidates[0]
if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", value):
    raise SystemExit("invalid compatibility contract Wine candidate")
print(contract["schemaVersion"])
print(value)
PY2
)
CFW_CONTRACT_SCHEMA="${contract_identity[0]:?missing compatibility contract schema}"
CFW_CONTRACT_WINE_VERSION="${contract_identity[1]:?missing compatibility contract Wine candidate}"
if [[ "$CFW_EXPECTED_WINE_VERSION" != "wine-$CFW_CONTRACT_WINE_VERSION" ]]; then
  printf '[cfw] Wine selection does not match compatibility contract: expected=wine-%s selected=%s\n' \
    "$CFW_CONTRACT_WINE_VERSION" "$CFW_EXPECTED_WINE_VERSION" >&2
  exit 64
fi
CFW_EXPECTED_POWERSHELL_VERSION="$(runtime_version powershell)"
CFW_EXPECTED_CHOCOLATEY_VERSION="$(runtime_version chocolatey)"
CFW_EXPECTED_SYNCHRO_VERSION="$(runtime_version synchro)"
export CFW_RUNTIME_ID CFW_CONTRACT_SCHEMA CFW_EXPECTED_WINE_VERSION CFW_EXPECTED_POWERSHELL_VERSION CFW_EXPECTED_CHOCOLATEY_VERSION CFW_EXPECTED_SYNCHRO_VERSION

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

winepath_to_windows() {
  local label="$1" host_path="$2" log settle_log status converted rc settle_rc
  local -a converted_lines
  log="$logs/winepath-${label}.log"
  settle_log="$logs/winepath-${label}-settle.log"
  status="$logs/winepath-${label}.status"
  rm -f "$log" "$settle_log" "$status"
  set +e
  timeout --kill-after=10s 60s winepath -w "$host_path" >"$log" 2>&1
  rc="$?"
  timeout --kill-after=10s 60s wineserver -w >"$settle_log" 2>&1
  settle_rc="$?"
  set -e
  printf '%s %s\n' "$rc" "$settle_rc" >"$status"
  if [[ "$rc" -ne 0 || "$settle_rc" -ne 0 ]]; then
    printf '[cfw] Wine path conversion failed: label=%s process=%s settle=%s host_path=%s prefix=%s dll_overrides=%s\n' \
      "$label" "$rc" "$settle_rc" "$host_path" "$WINEPREFIX" "${WINEDLLOVERRIDES:-<unset>}" >&2
    cat "$log" >&2 || true
    cat "$settle_log" >&2 || true
    return 70
  fi
  normalize_log "$log"
  mapfile -t converted_lines <"$log"
  if [[ "${#converted_lines[@]}" -ne 1 || -z "${converted_lines[0]}" ]]; then
    printf '[cfw] Wine path conversion failed: label=%s process=0 settle=0 non-canonical-output host_path=%s prefix=%s\n' \
      "$label" "$host_path" "$WINEPREFIX" >&2
    return 65
  fi
  converted="${converted_lines[0]}"
  printf '%s\n' "$converted"
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
cp -f "$compiled_installer" "$release_dir/ChoCinstaller_0.5c.755.exe"
printf '%s  %s\n' "$CFW_INSTALLER_SHA256" "$compiled_installer" >"$logs/installer-under-test.sha256"
verify_checkout_source choc_install.ps1 "$repo_root/choc_install.ps1"
cp -f "$repo_root/choc_install.ps1" "$release_dir/choc_install.ps1"

for input_name in chocolatey powershell dotnet mscoree d3d64 d3d32 conemu sevenZipExtractor windowsPowerShell; do
  fetch_input "$input_name" "$payload_cache/$(input_value "$input_name" filename)"
done

mark_stage prove-wine-identity
set +e
timeout --kill-after=10s 60s wine --version >"$logs/wine-version.log" 2>&1
wine_version_rc="$?"
timeout --kill-after=10s 60s wineserver -w >"$logs/wine-version-settle.log" 2>&1
wine_version_settle_rc="$?"
set -e
normalize_log "$logs/wine-version.log"
CFW_OBSERVED_WINE_VERSION="$(read_single_observed_line wine-version "$logs/wine-version.log")"
if [[ "$wine_version_rc" -ne 0 || "$wine_version_settle_rc" -ne 0 || "$CFW_OBSERVED_WINE_VERSION" != "$CFW_EXPECTED_WINE_VERSION" ]]; then
  printf '[cfw] Wine identity proof failed: expected=%s observed=%s process=%s settle=%s image=%s\n' \
    "$CFW_EXPECTED_WINE_VERSION" "$CFW_OBSERVED_WINE_VERSION" "$wine_version_rc" "$wine_version_settle_rc" "$CFW_WINE_IMAGE" >&2
  exit 70
fi
export CFW_OBSERVED_WINE_VERSION

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
# suppression into installer, CLR, or external PowerShell execution.
export WINEDLLOVERRIDES=""

mark_stage install-cfw
cfw_cache_win="$(winepath_to_windows cfw-cache "$work")"
export CFW_CACHE="$cfw_cache_win"
export CFW_OFFLINE=1
export CFW_CONTAINER_BUILDER=1
export CFW_EXTERNAL_POWERSHELL=1
installer_win="$(winepath_to_windows cfw-installer "$release_dir/ChoCinstaller_0.5c.755.exe")"
set +e
timeout --kill-after=30s "${CFW_INSTALL_TIMEOUT:-7200s}" wine "$installer_win" /s /q >"$logs/installer.log" 2>&1
installer_rc="$?"
timeout --kill-after=15s 300s wineserver -w >>"$logs/installer.log" 2>&1
installer_settle_rc="$?"
set -e

pwsh="$wine_prefix/drive_c/Program Files/PowerShell/7/pwsh.exe"
choco="$wine_prefix/drive_c/ProgramData/chocolatey/bin/choco.exe"

if [[ "$installer_rc" -ne 0 || "$installer_settle_rc" -ne 0 ]]; then
  printf 'CFW installer failed: installer=%s settle=%s\n' "$installer_rc" "$installer_settle_rc" >&2
  tail -160 "$logs/installer.log" >&2 || true
  exit 70
fi
[[ -s "$pwsh" && -s "$choco" ]] || {
  printf 'CFW output incomplete: pwsh=%s choco=%s\n' "$pwsh" "$choco" >&2
  exit 70
}

mark_stage apply-pre-pwsh-policy
pwsh_policy="$repo_root/compat/pwsh-policy.reg"
pwsh_policy_win="$(winepath_to_windows pwsh-policy "$pwsh_policy")"
pwsh_policy_key='HKCU\Software\Wine\AppDefaults\pwsh.exe\DllOverrides'
: >"$logs/pwsh-policy.log"
set +e
timeout --kill-after=10s 60s winecfg /v win10 >>"$logs/pwsh-policy.log" 2>&1
pwsh_winecfg_rc="$?"
timeout --kill-after=10s 60s wineserver -w >>"$logs/pwsh-policy.log" 2>&1
pwsh_winecfg_settle_rc="$?"
timeout --kill-after=10s 60s wine regedit /S "$pwsh_policy_win" >>"$logs/pwsh-policy.log" 2>&1
pwsh_regedit_rc="$?"
timeout --kill-after=10s 60s wineserver -w >>"$logs/pwsh-policy.log" 2>&1
pwsh_regedit_settle_rc="$?"
timeout --kill-after=10s 60s wine reg query "$pwsh_policy_key" >>"$logs/pwsh-policy.log" 2>&1
pwsh_query_rc="$?"
timeout --kill-after=10s 60s wineserver -w >>"$logs/pwsh-policy.log" 2>&1
pwsh_query_settle_rc="$?"
normalize_log "$logs/pwsh-policy.log"
grep -Eq 'amsi[[:space:]]+REG_SZ[[:space:]]*$' "$logs/pwsh-policy.log"
pwsh_amsi_rc="$?"
grep -Eq 'dwmapi[[:space:]]+REG_SZ[[:space:]]*$' "$logs/pwsh-policy.log"
pwsh_dwmapi_rc="$?"
grep -Eq 'rpcrt4[[:space:]]+REG_SZ[[:space:]]+native,builtin[[:space:]]*$' "$logs/pwsh-policy.log"
pwsh_rpcrt4_rc="$?"
set -e
if [[ "$pwsh_winecfg_rc" -ne 0 || "$pwsh_winecfg_settle_rc" -ne 0 || \
      "$pwsh_regedit_rc" -ne 0 || "$pwsh_regedit_settle_rc" -ne 0 || \
      "$pwsh_query_rc" -ne 0 || "$pwsh_query_settle_rc" -ne 0 || \
      "$pwsh_amsi_rc" -ne 0 || "$pwsh_dwmapi_rc" -ne 0 || "$pwsh_rpcrt4_rc" -ne 0 ]]; then
  printf '[cfw] pre-PowerShell policy failed: winecfg=%s/%s regedit=%s/%s query=%s/%s amsi=%s dwmapi=%s rpcrt4=%s\n' \
    "$pwsh_winecfg_rc" "$pwsh_winecfg_settle_rc" "$pwsh_regedit_rc" "$pwsh_regedit_settle_rc" \
    "$pwsh_query_rc" "$pwsh_query_settle_rc" "$pwsh_amsi_rc" "$pwsh_dwmapi_rc" "$pwsh_rpcrt4_rc" >&2
  exit 70
fi

mark_stage prove-pwsh
probe_dir="$wine_prefix/drive_c/ProgramData/CFW/RuntimeProbe"
pwsh_marker="$probe_dir/pwsh.txt"
pwsh_probe_script="$probe_dir/pwsh-probe.ps1"
mkdir -p "$probe_dir"
rm -f "$pwsh_marker"
cat > "$pwsh_probe_script" <<'PS1'
param(
    [Parameter(Mandatory = $true)][string]$MarkerPath,
    [Parameter(Mandatory = $true)][string]$ExpectedVersion
)
$ErrorActionPreference = 'Stop'
[Console]::Out.WriteLine('[cfw] pwsh-script-entry')
$version = $PSVersionTable.PSVersion.ToString()
[Console]::Out.WriteLine('[cfw] pwsh=' + $version)
if ($version -cne $ExpectedVersion) {
    throw "PowerShell version mismatch: expected=$ExpectedVersion observed=$version"
}
[IO.File]::WriteAllText($MarkerPath, $version)
PS1
pwsh_win="$(winepath_to_windows pwsh-executable "$pwsh")"
pwsh_probe_script_win="$(winepath_to_windows pwsh-probe-script "$pwsh_probe_script")"
pwsh_marker_win="$(winepath_to_windows pwsh-marker "$pwsh_marker")"
set +e
timeout --kill-after=15s 300s wine "$pwsh_win" -NoLogo -NoProfile -NonInteractive \
  -File "$pwsh_probe_script_win" "$pwsh_marker_win" "$CFW_EXPECTED_POWERSHELL_VERSION" \
  >"$logs/pwsh-probe.log" 2>&1
pwsh_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/pwsh-probe.log" 2>&1
pwsh_settle_rc="$?"
normalize_log "$logs/pwsh-probe.log"
if grep -Fqx '[cfw] pwsh-script-entry' "$logs/pwsh-probe.log"; then
  pwsh_entry_rc=0
else
  pwsh_entry_rc="$?"
fi
if grep -Fqx "[cfw] pwsh=$CFW_EXPECTED_POWERSHELL_VERSION" "$logs/pwsh-probe.log" && \
   [[ "$(tr -d '\r\n' < "$pwsh_marker")" == "$CFW_EXPECTED_POWERSHELL_VERSION" ]]; then
  pwsh_version_rc=0
else
  pwsh_version_rc=1
fi
set -e
if [[ "$pwsh_rc" -ne 0 || "$pwsh_settle_rc" -ne 0 || "$pwsh_entry_rc" -ne 0 || "$pwsh_version_rc" -ne 0 || ! -s "$pwsh_marker" ]]; then
  if [[ -s "$pwsh_marker" ]]; then marker_status=present; else marker_status=missing; fi
  printf 'PowerShell runtime proof failed: process=%s settle=%s entry=%s version=%s marker=%s path=%s\n' \
    "$pwsh_rc" "$pwsh_settle_rc" "$pwsh_entry_rc" "$pwsh_version_rc" "$marker_status" "$pwsh_win" \
    | tee "$logs/pwsh-proof-summary.log" >&2
  cat "$logs/pwsh-probe.log" >&2 || true
  set +e
  WINEDEBUG=+process,+loaddll,+seh timeout --kill-after=15s 90s \
    wine "$pwsh_win" -NoLogo -NoProfile -NonInteractive \
    -File "$pwsh_probe_script_win" "$pwsh_marker_win" "$CFW_EXPECTED_POWERSHELL_VERSION" \
    >"$logs/pwsh-failure-trace.log" 2>&1
  trace_rc="$?"
  timeout --kill-after=10s 60s wineserver -w >>"$logs/pwsh-failure-trace.log" 2>&1
  trace_settle_rc="$?"
  set -e
  printf 'failure-trace process=%s settle=%s\n' "$trace_rc" "$trace_settle_rc" \
    | tee -a "$logs/pwsh-proof-summary.log" >&2
  exit 70
fi

mark_stage finalize-prepared-runtime
prepared_finalizer="$repo_root/compat/finalize-runtime.ps1"
prepared_finalizer_win="$(winepath_to_windows prepared-finalizer "$prepared_finalizer")"
profile_fragments_win="$(winepath_to_windows profile-fragments "$repo_root/compat/profile.d")"
prepared_finalizer_marker="$probe_dir/prepared-finalizer.txt"
prepared_finalizer_marker_win="$(winepath_to_windows prepared-finalizer-marker "$prepared_finalizer_marker")"
rm -f "$prepared_finalizer_marker"
set +e
timeout --kill-after=15s 300s wine "$pwsh_win" -NoLogo -NoProfile -NonInteractive \
  -File "$prepared_finalizer_win" -FragmentSource "$profile_fragments_win" -MarkerPath "$prepared_finalizer_marker_win" \
  >"$logs/prepared-finalizer.log" 2>&1
prepared_finalizer_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/prepared-finalizer.log" 2>&1
prepared_finalizer_settle_rc="$?"
normalize_log "$logs/prepared-finalizer.log"
set -e
if [[ "$prepared_finalizer_rc" -ne 0 || "$prepared_finalizer_settle_rc" -ne 0 || ! -s "$prepared_finalizer_marker" ]] || \
   ! grep -Fqx '[cfw] stage=prepared-finalizer-script-entry' "$logs/prepared-finalizer.log" || \
   ! grep -Fqx '[cfw] stage=prepared-finalizer-complete' "$logs/prepared-finalizer.log"; then
  printf 'Prepared runtime finalizer failed: process=%s settle=%s marker=%s\n' \
    "$prepared_finalizer_rc" "$prepared_finalizer_settle_rc" "$prepared_finalizer_marker" >&2
  cat "$logs/prepared-finalizer.log" >&2 || true
  exit 70
fi

wrapper64="$wine_prefix/drive_c/windows/system32/WindowsPowerShell/v1.0/powershell.exe"
wrapper32="$wine_prefix/drive_c/windows/syswow64/WindowsPowerShell/v1.0/powershell.exe"
mark_stage install-synchro
synchro_cache="$work/synchro-v$CFW_EXPECTED_SYNCHRO_VERSION"
fetch_input synchro64 "$synchro_cache/powershell64.exe"
fetch_input synchro32 "$synchro_cache/powershell32.exe"
mkdir -p "$(dirname "$wrapper64")" "$(dirname "$wrapper32")"
cp -f "$synchro_cache/powershell64.exe" "$wrapper64"
cp -f "$synchro_cache/powershell32.exe" "$wrapper32"
test -s "$wrapper64" && test -s "$wrapper32"

mark_stage prove-runtime
export ChocolateyInstall='C:\ProgramData\chocolatey'
export ChocolateyToolsLocation='C:\tools'
choco_win='C:\ProgramData\chocolatey\bin\choco.exe'
synchro64_marker="$probe_dir/synchro-x64.txt"
synchro32_marker="$probe_dir/synchro-x86.txt"
smoke_install_marker="$probe_dir/chocolatey-install.txt"
smoke_uninstall_marker="$probe_dir/chocolatey-uninstall.txt"
rm -f "$synchro64_marker" "$synchro32_marker" "$smoke_install_marker" "$smoke_uninstall_marker"
synchro64_marker_win="$(winepath_to_windows synchro-x64-marker "$synchro64_marker")"
synchro32_marker_win="$(winepath_to_windows synchro-x86-marker "$synchro32_marker")"
smoke_feed="$work/smoke-feed"
build_smoke_package "$smoke_feed"
smoke_feed_win="$(winepath_to_windows smoke-feed "$smoke_feed")"

set +e
timeout --kill-after=15s 300s wine "$choco_win" feature list --limit-output >"$logs/choco-feature-status.log" 2>&1
feature_status_command_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/choco-feature-status.log" 2>&1
feature_status_settle_rc="$?"
set -e
normalize_log "$logs/choco-feature-status.log"
set +e
grep -Eiq '^powershellHost\|(disabled|false)$' "$logs/choco-feature-status.log"
feature_status_rc="$?"
timeout --kill-after=15s 300s wine "$choco_win" --version >"$logs/choco-version.log" 2>&1
choco_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/choco-version.log" 2>&1
choco_settle_rc="$?"
set -e
normalize_log "$logs/choco-version.log"
CFW_OBSERVED_CHOCOLATEY_VERSION="$(read_single_observed_line chocolatey-version "$logs/choco-version.log")"
set +e
[[ "$CFW_OBSERVED_CHOCOLATEY_VERSION" == "$CFW_EXPECTED_CHOCOLATEY_VERSION" ]]
choco_version_rc="$?"
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
export CFW_OBSERVED_CHOCOLATEY_VERSION

python3 - "$metadata" \
  "$installer_rc" "$installer_settle_rc" "$pwsh_rc" "$pwsh_settle_rc" \
  "$prepared_finalizer_rc" "$prepared_finalizer_settle_rc" \
  "$feature_status_command_rc" "$feature_status_settle_rc" "$feature_status_rc" \
  "$choco_rc" "$choco_settle_rc" "$choco_version_rc" \
  "$synchro64_rc" "$synchro64_settle_rc" "$synchro32_rc" "$synchro32_settle_rc" \
  "$smoke_install_rc" "$smoke_install_settle_rc" "$smoke_uninstall_rc" "$smoke_uninstall_settle_rc" \
  "$wine_version_rc" "$wine_version_settle_rc" \
  "$pwsh_winecfg_rc" "$pwsh_winecfg_settle_rc" "$pwsh_regedit_rc" "$pwsh_regedit_settle_rc" \
  "$pwsh_query_rc" "$pwsh_query_settle_rc" "$pwsh_amsi_rc" "$pwsh_dwmapi_rc" "$pwsh_rpcrt4_rc" \
  "$logs" "$pwsh_marker" "$prepared_finalizer_marker" "$synchro64_marker" "$synchro32_marker" "$smoke_install_marker" "$smoke_uninstall_marker" <<'PY2'
import hashlib
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
values = [int(value) for value in sys.argv[2:33]]
logs_path = Path(sys.argv[33])
markers = [Path(value) for value in sys.argv[34:]]
keys = [
    "installer", "installerSettle", "pwsh", "pwshSettle", "preparedFinalizer",
    "preparedFinalizerSettle", "featurePolicyStatusCommand", "featurePolicyStatusSettle",
    "featurePolicyStatus", "chocolateyVersionCommand", "chocolateyVersionSettle",
    "chocolateyVersion", "synchroX64", "synchroX64Settle", "synchroX86",
    "synchroX86Settle", "smokeInstall", "smokeInstallSettle", "smokeUninstall",
    "smokeUninstallSettle", "wineVersionCommand", "wineVersionSettle",
    "prePwshWinecfg", "prePwshWinecfgSettle", "prePwshRegedit", "prePwshRegeditSettle",
    "prePwshQuery", "prePwshQuerySettle", "prePwshAmsi", "prePwshDwmapi", "prePwshRpcrt4",
]
return_codes = dict(zip(keys, values))
winepath_labels = (
    "cfw-cache", "cfw-installer", "pwsh-policy", "pwsh-executable",
    "pwsh-probe-script", "pwsh-marker", "prepared-finalizer",
    "profile-fragments", "prepared-finalizer-marker", "synchro-x64-marker",
    "synchro-x86-marker", "smoke-feed",
)
winepath_return_codes = {}
for label in winepath_labels:
    status = logs_path / f"winepath-{label}.status"
    parts = status.read_text(encoding="utf-8").split()
    if len(parts) != 2:
        raise SystemExit(f"invalid Wine path status: {label}")
    winepath_return_codes[label] = {"command": int(parts[0]), "settle": int(parts[1])}
marker_hashes = {
    marker.name: hashlib.sha256(marker.read_bytes()).hexdigest()
    for marker in markers
    if marker.is_file() and marker.stat().st_size > 0
}
observed_powershell = markers[0].read_text(encoding="utf-8").strip()
checks = {
    "wineIdentity": values[20] == 0 and values[21] == 0 and os.environ["CFW_OBSERVED_WINE_VERSION"] == os.environ["CFW_EXPECTED_WINE_VERSION"],
    "installer": values[0] == 0 and values[1] == 0,
    "prePwshPolicy": all(value == 0 for value in values[22:31]),
    "pathConversions": all(
        codes["command"] == 0 and codes["settle"] == 0
        for codes in winepath_return_codes.values()
    ),
    "pwsh": values[2] == 0 and values[3] == 0 and observed_powershell == os.environ["CFW_EXPECTED_POWERSHELL_VERSION"] and "pwsh.txt" in marker_hashes,
    "preparedFinalizer": values[4] == 0 and values[5] == 0 and "prepared-finalizer.txt" in marker_hashes,
    "featurePolicy": values[6] == 0 and values[7] == 0 and values[8] == 0,
    "chocolatey": values[9] == 0 and values[10] == 0 and values[11] == 0 and os.environ["CFW_OBSERVED_CHOCOLATEY_VERSION"] == os.environ["CFW_EXPECTED_CHOCOLATEY_VERSION"],
    "synchroX64": values[12] == 0 and values[13] == 0 and "synchro-x64.txt" in marker_hashes,
    "synchroX86": values[14] == 0 and values[15] == 0 and "synchro-x86.txt" in marker_hashes,
    "chocolateyLifecycle": values[16] == 0 and values[17] == 0 and values[18] == 0 and values[19] == 0 and "chocolatey-install.txt" in marker_hashes and "chocolatey-uninstall.txt" in marker_hashes,
}
record = {
    "schemaVersion": "cfw.runtime-build/v2",
    "provider": "cfw-chocolatey-runtime",
    "contract": os.environ["CFW_CONTRACT_SCHEMA"],
    "contractSha256": os.environ["CFW_CONTRACT_SHA256"],
    "runtimeId": os.environ["CFW_RUNTIME_ID"],
    "status": "passed" if all(checks.values()) else "failed",
    "wine": {"image": os.environ["CFW_WINE_IMAGE"], "version": os.environ["CFW_OBSERVED_WINE_VERSION"], "architecture": "win64"},
    "sourceRevision": os.environ["CFW_SOURCE_REVISION"],
    "installerSha256": os.environ["CFW_INSTALLER_SHA256"],
    "runtimeInputsSha256": os.environ["CFW_RUNTIME_INPUTS_SHA256"],
    "profileLoader": {"path": "C:\\Program Files\\PowerShell\\7\\profile.ps1", "applicationExtensionPath": "C:\\ProgramData\\Chocolatey-for-wine\\application-profile.d"},
    "powershell": observed_powershell,
    "synchro": "v" + os.environ["CFW_EXPECTED_SYNCHRO_VERSION"],
    "chocolatey": os.environ["CFW_OBSERVED_CHOCOLATEY_VERSION"],
    "checks": checks,
    "returnCodes": return_codes,
    "winepathReturnCodes": winepath_return_codes,
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
"$repo_root/compat/package-runtime.sh" "$wine_prefix" "$archive"
archive_sha256="$(sha256sum "$archive" | awk '{print $1}')"
printf '%s  %s\n' "$archive_sha256" "$(basename "$archive")" > "$archive.sha256"

python3 - "$metadata" "$manifest" "$archive" "$archive_sha256" "$compat_contract" <<'PY2'
import hashlib
import json
import os
import sys
from pathlib import Path

evidence_path = Path(sys.argv[1])
manifest_path = Path(sys.argv[2])
archive_path = Path(sys.argv[3])
archive_sha256 = sys.argv[4]
contract_path = Path(sys.argv[5])
evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
contract = json.loads(contract_path.read_text(encoding="utf-8"))
required_proofs = contract["build"]["requiredProofs"]
if not isinstance(required_proofs, list) or not required_proofs or len(required_proofs) != len(set(required_proofs)):
    raise SystemExit("invalid authoritative proof inventory")
if set(evidence["checks"]) != set(required_proofs):
    raise SystemExit("runtime evidence proof inventory does not match compatibility contract")
if any(evidence["checks"][proof] is not True for proof in required_proofs):
    raise SystemExit("runtime evidence contains an unproven contract requirement")
if evidence.get("contract") != contract.get("schemaVersion"):
    raise SystemExit("runtime evidence compatibility contract mismatch")
if evidence.get("contractSha256") != hashlib.sha256(contract_path.read_bytes()).hexdigest():
    raise SystemExit("runtime evidence compatibility contract digest mismatch")
manifest = {
    "schemaVersion": "cfw.prepared-runtime-manifest/v1",
    "runtimeId": evidence["runtimeId"],
    "contract": evidence["contract"],
    "contractSha256": evidence["contractSha256"],
    "archive": {"filename": archive_path.name, "sha256": archive_sha256, "bytes": archive_path.stat().st_size},
    "runtimeEvidence": {"filename": evidence_path.name, "sha256": hashlib.sha256(evidence_path.read_bytes()).hexdigest()},
    "sourceRevision": evidence["sourceRevision"],
    "installerSha256": evidence["installerSha256"],
    "runtimeInputsSha256": evidence["runtimeInputsSha256"],
    "wine": evidence["wine"],
    "requiredProofs": required_proofs,
    "interfaces": contract["artifact"]["interfaces"],
    "status": evidence["status"],
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY2
mark_stage complete
printf '[cfw] runtime artifact ready: %s\n' "$archive"
