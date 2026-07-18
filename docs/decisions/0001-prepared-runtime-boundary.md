# ADR 0001: CFW owns the prepared Wine compatibility runtime

- Status: Accepted
- Date: 2026-07-17
- Owner: Noah Giroux (CTO)
- Reversibility: Medium; artifact schema may evolve before the first successful release
- Source of truth: this record, `compat/contract.json`, and a successful immutable runtime release

## Context

Cage accumulated AIK, DPX, WMF, GAC, CLR, registry, Synchro, and PowerShell implementation details while trying to make Chocolatey reliable under Wine. That duplicated Chocolatey-for-Wine (CFW) behavior in every application build and produced repeated CI patch loops.

The first prepared-runtime implementation added contracts, evidence, and release workflows, but its container mode bypassed CFW's maintained PowerShell finalization path and substituted an incomplete native shortcut. Static contract checks passed while every behavioral runtime build failed. Therefore Phase 1 is not complete until a real runtime artifact passes.

## Decision

CFW is the sole owner of its prepared Wine compatibility runtime:

1. CFW initializes a fresh prefix from digest-pinned Wine and locked inputs.
2. A bounded native bootstrap installs prerequisites that must exist before PowerShell can execute.
3. CFW applies one source-controlled pre-PowerShell Wine policy, including its maintained `pwsh.exe` RPC override; this policy is producer-owned compatibility behavior, not a Cage reconstruction.
4. A behavioral `pwsh.exe` proof must emit an entry token, exact version, and filesystem sentinel.
5. Only after that proof may CFW run its prepared-runtime PowerShell finalizer.
6. CFW installs and proves Synchro x64/x86, canonical Chocolatey policy, and a local package install/uninstall lifecycle.
7. CFW publishes a versioned prefix archive, runtime evidence, detached manifest, and checksum only when all proofs pass.

The prepared-runtime finalizer is authoritative for the prepared-runtime mode. The historical desktop installer may retain its legacy finalizer, but consumers never depend on its internal layout.

Cage owns artifact acquisition, complete manifest/evidence/archive verification, prefix seeding, recipe/package orchestration, application lifecycle verification, and final OCI/bundle production. Cage must not implement CFW's Wine/.NET/PowerShell/Synchro compatibility.

## Required phase boundaries

`wine-identity -> fresh-prefix -> native-bootstrap -> bounded-settled-path-conversions -> isolated-pre-pwsh-policy -> pwsh-proof -> prepared-runtime-finalizer -> synchro/chocolatey proofs -> package -> contract-authoritative release`

A process exit code alone is not proof. Each executable boundary requires observable behavior and Wine settlement. The compatibility contract is authoritative for both the required proof inventory and the Phase 1 Wine candidate matrix.

## Rejected alternatives

- **Keep patching the native shortcut:** rejected because it recreates the skipped finalizer one hidden dependency at a time.
- **Reconstruct Windows compatibility in Cage:** rejected because it violates ownership and makes every application build repeat platform servicing.
- **Freeze the consumer interface before a real artifact exists:** rejected because static schemas have not yet demonstrated a valid runtime.
- **Treat a skipped Cage smoke workflow as success:** rejected because it proves no producer/consumer behavior.

## Acceptance gates

Phase 1 is complete only when:

- at least one supported Wine runtime passes every CFW behavioral proof;
- the immutable release assets exist and independently bind the checked-out contract SHA, source SHA, installer SHA, input lock SHA, producer image digest, detached/archived evidence identity, archive hash and size, and declared executable interfaces;
- a clean Cage build verifies those bindings, seeds the prefix, installs and uninstalls the local smoke package, and does not skip.

Wine 11 is the first target. Wine 9 and 10 are added only after Wine 11 passes.

## Review trigger

Review when PowerShell/Chocolatey versions change, the Wine producer image changes materially, a second consumer appears, or evidence shows prepared prefixes cannot safely survive `wineboot -u` in Cage.
