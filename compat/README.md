# Chocolatey-for-Wine compatibility pack

This directory defines the reusable, additive portion of Chocolatey-for-Wine.
It is intended for deterministic consumers such as Cage that assemble a Wine
prefix from separately owned layers.

## Layer contract

1. The orchestrator owns the Wine prefix and PowerShell profile loader.
2. A real `pwsh.exe` installation provides the PowerShell engine.
3. [Synchro/powershell-wrapper-for-wine](https://codeberg.org/Synchro/powershell-wrapper-for-wine)
   owns the Windows PowerShell compatibility executables and command-line
   translation layer.
4. Chocolatey-for-Wine contributes Chocolatey bootstrap behavior and Wine
   compatibility fragments.

The machine-readable contract is in `contract.json`.

## Container finalizer

`container-finalizer.c` is the clean layer-three entrypoint. It does not
install PowerShell, download payloads, invoke package scripts, or install a
competing wrapper. The orchestrator must first:

1. install and prove `pwsh.exe`;
2. install and prove Synchro's x64 and x86 wrappers;
3. verify and extract the Chocolatey nupkg so its payload exists at
   `%ProgramData%\tools\chocolateyInstall`;
4. set `CFW_CONTAINER_BUILDER=1`, `CFW_OFFLINE=1`, and
   `CFW_EXTERNAL_POWERSHELL=1`.

The finalizer validates the external layer, stages Chocolatey under
`%ProgramData%\chocolatey.cfw-stage`, creates canonical `bin\choco.exe`, moves
the completed tree to `%ProgramData%\chocolatey`, and persists the environment.
A rerun resumes an interrupted staging operation or reconciles environment
state around an already valid canonical installation.

## Profile composition

These fragments are designed to be copied into an orchestrator-owned profile
directory and loaded in lexical order:

```text
20-chocolatey.ps1
30-cfw-winetricks.ps1
40-cfw-command-adapters.ps1
```

They must not replace Synchro's profile or the orchestrator's loader. A typical
Cage destination is:

```text
C:\ProgramData\Cage\PowerShell\profile.d
```

The real PowerShell profile should contain only a stable loader that dot-sources
ordered fragments. Upstream profiles should be retained unmodified and invoked
through a fragment owned by the integrating project.

## What this pack does not own

This pack does not own:

- installation or version selection of `pwsh.exe`;
- `System32` or `SysWOW64` Windows PowerShell wrapper executables;
- the root PowerShell profile file;
- orchestration, provenance, or dependency resolution;
- ConEmu or other interactive desktop presentation.

The historical interactive installer may continue to provide those components
for compatibility with existing users. Deterministic container consumers must
not infer that the desktop installer layout is the layer contract.

## Command adapters

`40-cfw-command-adapters.ps1` loads optional adapter fragments from:

```text
C:\ProgramData\Chocolatey-for-wine\command-adapters
```

This is the migration target for replacements such as `setx`, `wmic`, `wusa`,
and `schtasks`. Each adapter should be isolated, versioned, testable, and safe
to omit. The existing monolithic generated profile remains historical behavior
until those functions are extracted.
