#!/usr/bin/env sh
set -eu

# Complete the reusable Chocolatey-for-Wine container runtime after
# ChoCinstaller has run with CFW_CONTAINER_BUILDER=1.
#
# CFW owns this compatibility boundary. Consumers provide a fresh Wine prefix,
# the verified installer payload cache, and a location for evidence. The script
# deliberately does not install desktop-only ConEmu behavior or overwrite a
# consumer-owned interactive PowerShell profile.

: "${WINEPREFIX:?WINEPREFIX is required}"
: "${CFW_PAYLOAD_CACHE_POSIX:?CFW_PAYLOAD_CACHE_POSIX is required}"

wine_prefix="$WINEPREFIX"
payload_cache="$CFW_PAYLOAD_CACHE_POSIX"
evidence_root="${CFW_EVIDENCE_ROOT:-$wine_prefix/.cfw-evidence}"
logs="$evidence_root/logs"
metadata="$evidence_root/container-runtime.json"
choco_root="$wine_prefix/drive_c/ProgramData/chocolatey"
choco_exe="$choco_root/bin/choco.exe"
legacy_ps_package="$payload_cache/windowsserver2003-kb968930-x64-eng_8ba702aa016e4c5aed581814647f4d55635eff5c.exe"
mscoree_update="$payload_cache/windows6.1-kb958488-v6001-x64_a137e4f328f01146dfa75d7b5a576090dee948dc.msu"

mkdir -p "$logs" "$(dirname "$metadata")"
: > "$logs/container-runtime.log"

log() {
  printf '%s\n' "$*" | tee -a "$logs/container-runtime.log"
}

find_7z() {
  for candidate in 7z 7zz 7za; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

sevenzip="$(find_7z)" || {
  log "[cfw] ERROR: 7z/7zz/7za is required"
  exit 69
}

[ -s "$choco_exe" ] || {
  log "[cfw] ERROR: canonical Chocolatey is missing: $choco_exe"
  exit 68
}
[ -s "$legacy_ps_package" ] || {
  log "[cfw] ERROR: verified Windows PowerShell assembly package is missing"
  exit 68
}
[ -s "$mscoree_update" ] || {
  log "[cfw] ERROR: verified native MSCoree update is missing"
  exit 68
}

log "[cfw] stage=container-runtime-start"

# Chocolatey's in-process host loads the Windows PowerShell assemblies from its
# application directory. This is the same upstream-derived payload the desktop
# finalizer installs, without requiring a separate PS5.1 operating environment.
rm -rf "$choco_root/.cfw-ps-assembly-stage"
mkdir -p "$choco_root/.cfw-ps-assembly-stage"
"$sevenzip" e -y \
  -x'!*resources.dll' \
  "$legacy_ps_package" \
  'Microsoft.Powershell*.dll' \
  'Microsoft.WSman*.dll' \
  'system.management.automation.dll' \
  "-o$choco_root/.cfw-ps-assembly-stage" \
  >"$logs/powershell-assemblies.log" 2>&1

assembly_count="$(find "$choco_root/.cfw-ps-assembly-stage" -maxdepth 1 -type f -iname '*.dll' | wc -l | tr -d ' ')"
[ "$assembly_count" -gt 0 ] || {
  log "[cfw] ERROR: no Windows PowerShell assemblies were extracted"
  exit 69
}
find "$choco_root/.cfw-ps-assembly-stage" -maxdepth 1 -type f -iname '*.dll' -exec cp -f {} "$choco_root/" \;
rm -rf "$choco_root/.cfw-ps-assembly-stage"

# Restore the native .NET loader policy used by the upstream finalizer. WUSA may
# report that the update is already applied; the concrete loader check below is
# the success boundary.
mscoree_win="$(winepath -w "$mscoree_update")"
set +e
timeout --kill-after=15s "${CFW_MSCOREE_TIMEOUT:-600s}" wine wusa.exe "$mscoree_win" /quiet /norestart \
  >"$logs/mscoree-update.log" 2>&1
mscoree_rc="$?"
timeout --kill-after=10s 120s wineserver -w >>"$logs/mscoree-update.log" 2>&1
settle_rc="$?"
set -e

wine reg add 'HKCU\Software\Wine\DllOverrides' /v mscoree /d native /f \
  >"$logs/dotnet-policy.log" 2>&1
wine reg add 'HKCU\Software\Wine\DllOverrides' /v mscorsvc /d '' /f \
  >>"$logs/dotnet-policy.log" 2>&1
wine reg add 'HKLM\Software\Microsoft\.NETFramework' /v OnlyUseLatestCLR /t REG_DWORD /d 1 /f \
  >>"$logs/dotnet-policy.log" 2>&1

mscoree64="$wine_prefix/drive_c/windows/system32/mscoree.dll"
clr64="$wine_prefix/drive_c/windows/Microsoft.NET/Framework64/v4.0.30319/clr.dll"
[ -s "$mscoree64" ] || {
  log "[cfw] ERROR: native mscoree.dll is missing after update (rc=$mscoree_rc)"
  exit 69
}
[ -s "$clr64" ] || {
  log "[cfw] ERROR: CLR v4 loader is missing after update (rc=$mscoree_rc)"
  exit 69
}

# Keep Chocolatey's internal host enabled. This is the package-execution host;
# Synchro remains optional for interactive powershell.exe compatibility.
choco_win='C:\ProgramData\chocolatey\bin\choco.exe'
set +e
timeout "${CFW_CHOCO_TIMEOUT:-180s}" wine "$choco_win" feature enable --name=powershellHost \
  >"$logs/feature-policy.log" 2>&1
feature_enable_rc="$?"
timeout "${CFW_CHOCO_TIMEOUT:-180s}" wine "$choco_win" feature list --limit-output \
  >"$logs/feature-list.log" 2>&1
feature_list_rc="$?"
timeout "${CFW_CHOCO_TIMEOUT:-180s}" wine "$choco_win" --version \
  >"$logs/choco-version.log" 2>&1
version_rc="$?"
set -e

tr -d '\r' < "$logs/feature-list.log" > "$logs/feature-list.normalized.log"
if grep -Eiq '^powershellHost\|(enabled|true)(\||$)' "$logs/feature-list.normalized.log"; then
  feature_state_rc=0
else
  feature_state_rc=1
fi

python3 - "$metadata" "$assembly_count" "$mscoree_rc" "$settle_rc" "$feature_enable_rc" "$feature_list_rc" "$feature_state_rc" "$version_rc" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
assembly_count = int(sys.argv[2])
values = [int(value) for value in sys.argv[3:]]
checks = {
    "powershellAssemblies": assembly_count > 0,
    "wineserverSettle": values[1] == 0,
    "featureEnable": values[2] in {0, 2},
    "featureList": values[3] == 0,
    "powershellHostEnabled": values[4] == 0,
    "chocolateyVersion": values[5] == 0,
}
record = {
    "schemaVersion": "cfw.container-runtime/v1",
    "provider": "cfw-integrated-chocolatey-runtime",
    "packageExecutionHost": "chocolatey-in-process-powershell",
    "interactiveWindowsPowerShell": "optional-synchro",
    "status": "passed" if all(checks.values()) else "failed",
    "checks": checks,
    "assemblyCount": assembly_count,
    "returnCodes": {
        "mscoreeUpdate": values[0],
        "wineserverSettle": values[1],
        "featureEnable": values[2],
        "featureList": values[3],
        "featureState": values[4],
        "chocolateyVersion": values[5],
    },
    "logs": {
        "runtime": "logs/container-runtime.log",
        "powershellAssemblies": "logs/powershell-assemblies.log",
        "mscoreeUpdate": "logs/mscoree-update.log",
        "dotnetPolicy": "logs/dotnet-policy.log",
        "featurePolicy": "logs/feature-policy.log",
        "featureList": "logs/feature-list.log",
        "chocolateyVersion": "logs/choco-version.log",
    },
}
temporary = path.with_suffix(path.suffix + ".part")
temporary.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
temporary.replace(path)
if record["status"] != "passed":
    raise SystemExit(70)
PY

log "[cfw] stage=container-runtime-complete"
