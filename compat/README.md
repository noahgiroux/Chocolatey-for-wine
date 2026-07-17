# CFW prepared runtime

`compat/` publishes the deterministic compatibility boundary for
Chocolatey-for-Wine (CFW). A released CFW runtime is a complete, verified
**prepared Wine prefix**. Consumers such as Cage select a compatible Wine image,
verify the released CFW artifact, seed it into an empty prefix, then perform
application-specific package orchestration.

The contract is [`contract.json`](contract.json). Producer inputs are locked in
[`runtime-inputs.json`](runtime-inputs.json).

## Consumer boundary

CFW owns the prepared prefix’s Windows compatibility state:

- .NET, CLR, registry policy, and Wine compatibility state;
- PowerShell 7, the Windows PowerShell/Synchro x64 and x86 shims;
- the root PowerShell loader, CFW profile fragments, and compatibility adapters;
- canonical Chocolatey bootstrap, external-host policy, and package execution
  surface.

A consumer owns only:

- selecting a compatible **digest-pinned** Wine image;
- verifying the detached CFW manifest, evidence, and prefix archive hashes;
- replacing a fresh prefix with the verified prepared prefix before application
  modules run;
- its application recipes, package selection, package lifecycle checks, and
  final OCI/bundle artifact.

Consumers must not reconstruct WMF, GAC, CLR, Synchro, registry, or CFW profile
state. They must not merge the archive into a mutated prefix or replace CFW’s
root `profile.ps1`.

## Runtime artifact and evidence

`compat/build-runtime.sh` produces these files for each proven Wine image:

```text
cfw-runtime-prefix-wine-<version>.tar.gz
cfw-runtime-prefix-wine-<version>.tar.gz.sha256
cfw-runtime-evidence-wine-<version>.json
cfw-runtime-manifest-wine-<version>.json
logs/
```

The detached manifest binds the archive to:

- the CFW source revision and `runtime-inputs.json` digest;
- the exact Wine OCI image digest and observed Wine version;
- the `runtime.json` hash and runtime proof status;
- profile-loader and application-extension paths.

The runtime build is valid only when all behavioral proofs pass:

1. the fresh win64 prefix initializes and the CFW installer completes;
2. `pwsh.exe` creates a filesystem sentinel;
3. both Synchro wrappers create independent x64/x86 filesystem sentinels;
4. Chocolatey’s in-process `powershellHost` is disabled and its disabled status
   is verified;
5. canonical Chocolatey reports its version;
6. a CFW-controlled local package installs and uninstalls, creating both
   lifecycle sentinels;
7. Wine settles after every critical execution boundary.

A tagged `cfw-runtime-v*` GitHub Actions run publishes only the assets produced
by successful matrix jobs. Short-lived CI artifacts remain diagnostics only;
they are not the consumer interface.

## Profile composition

The prepared runtime owns:

```text
C:\Program Files\PowerShell\7\profile.ps1
C:\ProgramData\Chocolatey-for-wine\profile.d\20-chocolatey.ps1
C:\ProgramData\Chocolatey-for-wine\profile.d\30-cfw-winetricks.ps1
C:\ProgramData\Chocolatey-for-wine\profile.d\40-cfw-command-adapters.ps1
```

The loader preserves the installer-generated legacy profile, then loads CFW
fragments lexically. A consumer may add application-specific fragments only to:

```text
C:\ProgramData\Chocolatey-for-wine\application-profile.d
```

That directory is optional. It is an extension point, not permission to replace
the CFW loader or fragments.

## Container finalizer

[`container-finalizer.c`](container-finalizer.c) remains a bounded internal
Chocolatey promotion/recovery utility. It validates an already-provided external
layer and atomically promotes canonical Chocolatey state. It does not define the
prepared-runtime interface and must not be used by consumers as a substitute for
the released prefix artifact.

## Legacy desktop installer

The historical interactive installer remains supported for existing users. Its
layout and implementation details are not the contract for deterministic
consumers. CFW may refactor its legacy implementation internally without
expanding Cage’s Windows compatibility surface.
