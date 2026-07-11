# Chocolatey-for-Wine integration fork

This fork adapts the upstream Chocolatey-for-Wine project for deterministic
Wine prefix builders, particularly [Pelagians/Cage](https://github.com/Pelagians/Cage).
It preserves the upstream-derived interactive installer while separating the
reusable compatibility behavior from PowerShell ownership.

## Project direction

Chocolatey-for-Wine is not the Windows PowerShell compatibility provider in the
Cage architecture. The layers are:

1. **Wine runtime and prefix**: selected and owned by the orchestrator.
2. **PowerShell engine**: a verified `pwsh.exe` installation.
3. **Windows PowerShell compatibility**:
   [Synchro/powershell-wrapper-for-wine](https://codeberg.org/Synchro/powershell-wrapper-for-wine).
4. **Chocolatey**: canonical `choco.exe`, configuration, and package lifecycle.
5. **CFW compatibility pack**: Wine-specific profile fragments, registry policy,
   command adapters, files, and application workarounds.

The machine-readable integration contract and initial additive profile fragments
are under [`compat/`](compat/README.md).

## Deterministic consumers

Cage and similar builders should:

- install and prove the PowerShell engine independently;
- install Synchro's checked 32-bit and 64-bit wrapper assets independently;
- own the root PowerShell profile and load ordered profile fragments;
- provide all installer inputs from a verified cache;
- use CFW for Chocolatey bootstrap and additive compatibility data;
- validate `choco.exe` with real package install and uninstall tests;
- never treat file presence or installer exit code alone as readiness.

CFW profile fragments must not overwrite Synchro's profile or an
orchestrator-owned loader. The intended composition is lexical and additive:

```text
00-orchestrator-prelude.ps1
10-synchro.ps1
20-chocolatey.ps1
30-cfw-winetricks.ps1
40-cfw-command-adapters.ps1
80-application.ps1
90-user.ps1
```

## Container builder mode

The fork supports these environment variables:

- `CFW_CACHE`: Windows-form path containing `choc_install_files`.
- `CFW_OFFLINE=1`: prohibit installer download fallbacks.
- `CFW_CONTAINER_BUILDER=1`: use the bounded native Chocolatey promotion path
  instead of trusting the desktop PowerShell finalizer as the success boundary.

Container mode is deliberately narrower than the interactive desktop install.
It establishes canonical Chocolatey state. It does not imply that the full
historical monolithic profile, ConEmu environment, command adapters, or every
application workaround has been installed.

## Interactive desktop installer

For the upstream-style desktop environment:

1. Start from a fresh 64-bit Wine prefix.
2. Download and extract a release archive.
3. Run the included installer:

```bash
wine ChoCinstaller_0.5c.755.exe
```

Optional arguments:

```text
/s    retain downloaded installation files in the cache
/q    do not open the interactive PowerShell window after installation
```

The desktop path retains substantial upstream behavior, including .NET,
PowerShell, ConEmu, generated profiles, DLL policy, and compatibility helpers.
It should not be used as the specification for deterministic container builds.

## PowerShell wrappers

`mainv1.c` and the generated `powershell32.exe` / `powershell64.exe` remain for
compatibility with the historical desktop installer. They are not the canonical
layer-two implementation for Cage.

New deterministic integrations must use Synchro's current wrapper. The legacy
wrapper is still tested to ensure child process creation, wait failures, and
child exit codes are propagated rather than reported as success.

## Compatibility pack

The initial pack contains:

- `compat/contract.json`: requirements, ownership, and contribution metadata;
- `compat/profile.d/20-chocolatey.ps1`: Chocolatey profile module import;
- `compat/profile.d/30-cfw-winetricks.ps1`: optional CFW winetricks entrypoint;
- `compat/profile.d/40-cfw-command-adapters.ps1`: ordered adapter loader.

The remaining monolithic functions in `choc_install.ps1` should be migrated into
small, named assets over time. Likely groups include:

```text
compat/registry/
compat/profile.d/
compat/command-adapters/
compat/files/
compat/app-fixes/
```

Each extracted component should be independently optional, hashable, and tested.

## Upstream functionality

The inherited project installs Chocolatey in Wine and includes compatibility
workarounds, a PowerShell-based winetricks implementation, .NET support, and
special handling for software that exposes Wine bugs. These features remain
available through the interactive path while the deterministic interface is
split into explicit layers.

Chocolatey normally installs the newest package version. New application
versions can expose new Wine regressions, so recipes should pin tested package
versions when reproducibility matters.

## Constraints

- Use a fresh prefix for the interactive installer.
- `WINEARCH=win32` is not supported by the inherited installer.
- Do not combine the inherited .NET installation with unrelated winetricks
  `.NET` verbs in the same prefix without proving the result.
- In-place upgrades from older CFW layouts are not yet a supported contract.
- A successful installer exit is not sufficient evidence for production use.

## Development

The layer contract tests run with:

```bash
python -m unittest tests.test_layer_contract
```

The wrapper source is syntax-checked for both architectures in GitHub Actions
using MinGW.

The upstream-derived C sources include their original build instructions. A
release archive must contain the compiled installer and the data files expected
by that installer, including `choc_install.ps1`, `c_drive.7z`, `7z.exe`, and
`7z.dll`.

## Origin

This repository is derived from:

- `PietJankbal/Chocolatey-for-wine`
- `Twig6943/Chocolatey-for-wine`

The fork-specific changes focus on deterministic inputs, error propagation,
container-safe Chocolatey promotion, and separation from the canonical Synchro
PowerShell compatibility layer.
