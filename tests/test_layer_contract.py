import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LayerContractTests(unittest.TestCase):
    def test_contract_defines_prepared_prefix_runtime(self) -> None:
        contract = json.loads((ROOT / "compat" / "contract.json").read_text(encoding="utf-8"))

        self.assertEqual(contract["mode"], "prepared-prefix-runtime")
        self.assertEqual(contract["artifact"]["kind"], "prepared-wine-prefix")
        self.assertEqual(contract["artifact"]["seedSemantics"], "replace-fresh-prefix")
        self.assertTrue(contract["artifact"]["mustPrecedeApplicationModules"])
        self.assertEqual(contract["provides"]["windows-powershell-shim"], "synchro-v4.2.0")
        self.assertEqual(contract["provides"]["package-execution-host"], "external-windows-powershell")
        self.assertEqual(contract["ownership"]["powershellRuntime"], "cfw-runtime-artifact")
        self.assertTrue(contract["constraints"]["consumerMustNotReconstructWmfOrGac"])
        self.assertTrue(contract["constraints"]["consumerMustSeedArtifactBeforeOtherModules"])
        self.assertEqual(contract["artifact"]["manifest"], "cfw-runtime-manifest.json")
        self.assertIn("chocolateyLifecycle", contract["build"]["requiredProofs"])
        self.assertIn("wineIdentity", contract["build"]["requiredProofs"])
        self.assertIn("prePwshPolicy", contract["build"]["requiredProofs"])
        self.assertIn("pathConversions", contract["build"]["requiredProofs"])
        self.assertIn("synchroX64", contract["build"]["requiredProofs"])
        self.assertEqual(
            contract["artifact"]["interfaces"]["chocolatey"]["prefixRelativePath"],
            "drive_c/ProgramData/chocolatey/bin/choco.exe",
        )
        self.assertEqual(
            contract["artifact"]["interfaces"]["environment"],
            {"WINEDLLOVERRIDES": ""},
        )
        self.assertEqual(contract["ownership"]["profileLoader"], "cfw-runtime-artifact")
        self.assertTrue(contract["constraints"]["consumerMustVerifyRuntimeManifest"])
        self.assertFalse(contract["constraints"]["chocolateyInProcessPowerShellHost"])

    def test_runtime_builder_has_strict_proofs(self) -> None:
        source = (ROOT / "compat" / "build-runtime.sh").read_text(encoding="utf-8")
        inputs = json.loads((ROOT / "compat" / "runtime-inputs.json").read_text(encoding="utf-8"))

        self.assertIn("winepath_to_windows", source)
        self.assertIn("winepath-${label}.log", source)
        self.assertIn("Wine path conversion failed", source)
        self.assertIn('pwsh_win="$(winepath_to_windows pwsh-executable "$pwsh")"', source)
        self.assertIn('pwsh_probe_script_win="$(winepath_to_windows pwsh-probe-script "$pwsh_probe_script")"', source)
        self.assertIn('-File "$pwsh_probe_script_win" "$pwsh_marker_win"', source)
        self.assertIn("[cfw] pwsh-script-entry", source)
        self.assertIn("pwsh_entry_rc", source)
        self.assertIn("pwsh_version_rc", source)
        self.assertIn("if grep -Fqx '[cfw] pwsh-script-entry'", source)
        self.assertIn("CFW_EXPECTED_POWERSHELL_VERSION", source)
        self.assertIn('grep -Fqx "[cfw] pwsh=$CFW_EXPECTED_POWERSHELL_VERSION"', source)
        self.assertIn('[[ "$(tr -d \'\\r\\n\' < "$pwsh_marker")" == "$CFW_EXPECTED_POWERSHELL_VERSION" ]]', source)
        self.assertIn("pwsh-proof-summary.log", source)
        self.assertIn("pwsh-failure-trace.log", source)
        self.assertIn("WINEDEBUG=+process,+loaddll,+seh", source)
        self.assertIn("mark_stage apply-pre-pwsh-policy", source)
        self.assertIn("pwsh-policy.log", source)
        self.assertIn("compat/pwsh-policy.reg", source)
        policy = (ROOT / "compat" / "pwsh-policy.reg").read_text(encoding="utf-8")
        self.assertIn('"amsi"=""', policy)
        self.assertIn('"dwmapi"=""', policy)
        self.assertIn('"rpcrt4"="native,builtin"', policy)
        upstream = (ROOT / "choc_install.ps1").read_text(encoding="utf-8")
        self.assertIn('"rpcrt4"="native,builtin"', upstream)
        self.assertIn('export CFW_CONTAINER_BUILDER=1', source)
        self.assertIn('export CFW_EXTERNAL_POWERSHELL=1', source)
        self.assertIn('install-synchro', source)
        self.assertLess(
            source.index('mark_stage apply-pre-pwsh-policy'),
            source.index('mark_stage prove-pwsh'),
        )
        self.assertLess(
            source.index('mark_stage prove-pwsh'),
            source.index('mark_stage install-synchro'),
        )
        self.assertLess(
            source.index('export CFW_CONTAINER_BUILDER=1'),
            source.index('timeout --kill-after=30s "${CFW_INSTALL_TIMEOUT:-7200s}" wine "$installer_win"'),
        )
        self.assertIn('WINEDLLOVERRIDES="mscoree,mshtml="', source)
        self.assertIn('wine wineboot --init', source)
        self.assertIn('export WINEDLLOVERRIDES=""', source)
        self.assertLess(
            source.index('WINEDLLOVERRIDES="mscoree,mshtml="'),
            source.index('wine wineboot --init'),
        )
        self.assertLess(
            source.index('wine wineboot --init'),
            source.index('export WINEDLLOVERRIDES=""'),
        )
        self.assertEqual(inputs["downloads"]["powershell"]["filename"], "PowerShell-7.5.5-win-x64.msi")
        self.assertIn("powershell-wrapper-for-wine/releases/download/v4.2.0", inputs["downloads"]["synchro64"]["url"])
        self.assertEqual(inputs["downloads"]["synchro64"]["sha256"], "b1d594bd44abc01007b9dd2adea5248f09906fa8d4c6cea7f36a4279e2de91e0")
        self.assertEqual(inputs["downloads"]["synchro32"]["sha256"], "ca76d774273ffa37053545f8e4ad63c8914461828f1d1eef7a1915c9656fed4c")
        finalizer = (ROOT / "compat" / "finalize-runtime.ps1").read_text(encoding="utf-8")
        self.assertIn("feature disable --name=powershellHost", finalizer)
        self.assertIn("pwsh-probe.log", source)
        self.assertIn('normalize_log "$logs/pwsh-probe.log"', source)
        self.assertIn('normalize_log "$logs/prepared-finalizer.log"', source)
        self.assertIn('normalize_log "$logs/choco-feature-status.log"', source)
        self.assertIn('normalize_log "$logs/choco-version.log"', source)
        self.assertLess(
            source.index('normalize_log "$logs/choco-feature-status.log"'),
            source.index("grep -Eiq '^powershellHost\\|(disabled|false)$'"),
        )
        self.assertIn("feature_status_settle_rc", source)
        self.assertIn("choco_settle_rc", source)
        self.assertIn("choco_version_rc", source)
        self.assertIn("synchro-x64.txt", source)
        self.assertIn("synchro-x86.txt", source)
        self.assertIn("cfw-runtime-prefix", source)
        self.assertIn("cfw.runtime-build/v2", source)
        self.assertIn('contract = json.loads(contract_path.read_text', source)
        self.assertIn('required_proofs = contract["build"]["requiredProofs"]', source)
        self.assertIn('set(evidence["checks"]) != set(required_proofs)', source)
        self.assertNotIn('"requiredProofs": sorted(evidence["checks"])', source)
        self.assertIn('"requiredProofs": required_proofs', source)
        self.assertIn('"interfaces": contract["artifact"]["interfaces"]', source)

    def test_windows_crlf_feature_status_is_normalized_before_exact_match(self) -> None:
        raw = "powershellHost|disabled\r\n"
        normalized = raw.replace("\r", "")
        self.assertRegex(normalized, re.compile(r"^powershellHost\|(disabled|false)$", re.IGNORECASE | re.MULTILINE))

    def test_locked_versions_bind_runtime_identity_and_observed_evidence(self) -> None:
        inputs = json.loads((ROOT / "compat" / "runtime-inputs.json").read_text(encoding="utf-8"))
        source = (ROOT / "compat" / "build-runtime.sh").read_text(encoding="utf-8")

        self.assertEqual(inputs["versions"]["powershell"], "7.5.5")
        self.assertEqual(inputs["versions"]["chocolatey"], "2.6.0")
        self.assertEqual(inputs["versions"]["synchro"], "4.2.0")
        self.assertIn('CFW_RUNTIME_ID="$(runtime_value runtimeId)"', source)
        self.assertIn('CFW_EXPECTED_POWERSHELL_VERSION="$(runtime_version powershell)"', source)
        self.assertIn('CFW_EXPECTED_CHOCOLATEY_VERSION="$(runtime_version chocolatey)"', source)
        self.assertIn('observed_powershell = markers[0].read_text(encoding="utf-8").strip()', source)
        self.assertIn('"powershell": observed_powershell', source)
        self.assertIn('"runtimeId": os.environ["CFW_RUNTIME_ID"]', source)

    def test_prepared_runtime_finalizer_runs_after_first_pwsh_proof(self) -> None:
        source = (ROOT / "compat" / "build-runtime.sh").read_text(encoding="utf-8")
        finalizer = (ROOT / "compat" / "finalize-runtime.ps1").read_text(encoding="utf-8")

        self.assertIn("[cfw] stage=prepared-finalizer-script-entry", finalizer)
        self.assertIn("$ErrorActionPreference = 'Stop'", finalizer)
        self.assertIn("application-profile.d", finalizer)
        self.assertIn("feature disable --name=powershellHost", finalizer)
        self.assertIn("mark_stage finalize-prepared-runtime", source)
        self.assertIn('-File "$prepared_finalizer_win"', source)
        self.assertLess(
            source.index('mark_stage prove-pwsh'),
            source.index('mark_stage finalize-prepared-runtime'),
        )
        self.assertLess(
            source.index('mark_stage finalize-prepared-runtime'),
            source.index('mark_stage prove-runtime'),
        )
        self.assertNotIn("write_cfw_profile_loader", source)

    def test_runtime_inputs_are_locked_and_checkout_overrides_are_identified(self) -> None:
        inputs_path = ROOT / "compat" / "runtime-inputs.json"
        self.assertTrue(inputs_path.is_file(), "prepared runtime inputs must be versioned")
        inputs = json.loads(inputs_path.read_text(encoding="utf-8"))

        self.assertEqual(inputs["schemaVersion"], "cfw.runtime-inputs/v1")
        for name in (
            "cfwRelease",
            "chocolatey",
            "powershell",
            "dotnet",
            "mscoree",
            "synchro64",
            "synchro32",
        ):
            payload = inputs["downloads"][name]
            self.assertTrue(payload["url"].startswith("https://"), name)
            self.assertRegex(payload["sha256"], r"^[0-9a-f]{64}$", name)
        self.assertEqual(set(inputs["checkoutSources"]), {"choc_install.ps1"})
        self.assertRegex(inputs["checkoutSources"]["choc_install.ps1"]["sha256"], r"^[0-9a-f]{64}$")

        source = (ROOT / "compat" / "build-runtime.sh").read_text(encoding="utf-8")
        self.assertIn("runtime-inputs.json", source)
        self.assertIn("CFW_COMPILED_INSTALLER", source)
        self.assertIn("ChoCinstaller-under-test.exe", source)
        self.assertIn("CFW_RUNTIME_INPUTS_SHA256", source)
        self.assertIn("CFW_INSTALLER_SHA256", source)
        self.assertIn('"installerSha256"', source)
        self.assertIn("verify_checkout_source choc_install.ps1", source)
        self.assertNotIn("verify_checkout_source winetricks.ps1", source)

    def test_runtime_builder_requires_behavioral_proofs_and_manifest(self) -> None:
        source = (ROOT / "compat" / "build-runtime.sh").read_text(encoding="utf-8")

        self.assertIn("synchro-x64.txt", source)
        self.assertIn("synchro-x86.txt", source)
        self.assertIn("chocolatey-install.txt", source)
        self.assertIn("chocolatey-uninstall.txt", source)
        self.assertIn("featurePolicy", source)
        self.assertIn("CFW_WINE_IMAGE", source)
        self.assertIn("CFW_SOURCE_REVISION must be the exact source commit", source)
        self.assertIn("must be a full lowercase Git commit SHA", source)
        self.assertIn("must be a ghcr.io/pelagians/cage-wine digest", source)
        self.assertIn("CFW_RUNTIME_EVIDENCE_NAME", source)
        self.assertIn("CFW_RUNTIME_MANIFEST_NAME", source)
        self.assertIn("values = [int(value) for value in sys.argv[2:33]]", source)
        self.assertIn("logs_path = Path(sys.argv[33])", source)
        self.assertIn("markers = [Path(value) for value in sys.argv[34:]]", source)

    def test_wine_identity_and_pre_pwsh_policy_have_isolated_settlement_evidence(self) -> None:
        source = (ROOT / "compat" / "build-runtime.sh").read_text(encoding="utf-8")

        for token in (
            "CFW_EXPECTED_WINE_VERSION",
            "CFW_OBSERVED_WINE_VERSION",
            "wine_version_rc",
            "wine_version_settle_rc",
            "pwsh_winecfg_rc",
            "pwsh_winecfg_settle_rc",
            "pwsh_regedit_rc",
            "pwsh_regedit_settle_rc",
            "pwsh_query_rc",
            "pwsh_query_settle_rc",
            '"wineIdentity"',
            '"prePwshPolicy"',
        ):
            self.assertIn(token, source)
        self.assertNotIn('subprocess.run(["wine", "--version"]', source)
        self.assertLess(source.index("winecfg /v win10"), source.index('pwsh_winecfg_settle_rc="$?"'))
        self.assertLess(source.index('pwsh_winecfg_settle_rc="$?"'), source.index('wine regedit /S'))
        self.assertLess(source.index('wine regedit /S'), source.index('pwsh_regedit_settle_rc="$?"'))
        self.assertLess(source.index('pwsh_regedit_settle_rc="$?"'), source.index('wine reg query'))
        self.assertLess(source.index('wine reg query'), source.index('pwsh_query_settle_rc="$?"'))

    def test_contract_is_authoritative_for_wine_matrix_and_builder_identity(self) -> None:
        source = (ROOT / "compat" / "build-runtime.sh").read_text(encoding="utf-8")
        workflow = (ROOT / ".github" / "workflows" / "build-container-runtime.yml").read_text(encoding="utf-8")

        self.assertIn('CFW_CONTRACT_WINE_VERSION=', source)
        self.assertIn('contract["build"]["wineCandidates"]', source)
        self.assertIn('"wine-$CFW_CONTRACT_WINE_VERSION"', source)
        self.assertNotIn('CFW_EXPECTED_WINE_VERSION" != "wine-11.0"', source)
        self.assertIn("name: Resolve compatibility contract", workflow)
        self.assertIn("fromJSON(needs.contract.outputs.wines)", workflow)
        self.assertIn('contract["build"]["wineCandidates"]', workflow)
        self.assertNotIn("expected_wines=(11.0)", workflow)
        self.assertIn('assert wine in contract["build"]["wineCandidates"]', workflow)

    def test_every_winepath_boundary_is_bounded_settled_and_evidenced(self) -> None:
        source = (ROOT / "compat" / "build-runtime.sh").read_text(encoding="utf-8")

        helper = source[source.index("winepath_to_windows()") : source.index("build_smoke_package()")]
        self.assertIn('timeout --kill-after=10s 60s winepath -w', helper)
        self.assertIn('timeout --kill-after=10s 60s wineserver -w', helper)
        self.assertIn('status="$logs/winepath-${label}.status"', helper)
        self.assertNotRegex(source, r'(?m)^(?!.*timeout).*\$\(winepath -w')
        for label in ("synchro-x64-marker", "synchro-x86-marker", "smoke-feed"):
            self.assertIn(f'winepath_to_windows {label}', source)
        self.assertIn('"pathConversions"', source)
        self.assertIn('"winepathReturnCodes"', source)

    def test_chocolatey_version_is_one_exact_observed_value(self) -> None:
        source = (ROOT / "compat" / "build-runtime.sh").read_text(encoding="utf-8")

        self.assertIn("read_single_observed_line", source)
        self.assertIn('CFW_OBSERVED_WINE_VERSION="$(read_single_observed_line', source)
        self.assertIn('CFW_OBSERVED_CHOCOLATEY_VERSION=', source)
        self.assertIn('CFW_OBSERVED_CHOCOLATEY_VERSION="$(read_single_observed_line', source)
        self.assertIn('[[ "$CFW_OBSERVED_CHOCOLATEY_VERSION" == "$CFW_EXPECTED_CHOCOLATEY_VERSION" ]]', source)
        self.assertNotIn('grep -Fqx "$CFW_EXPECTED_CHOCOLATEY_VERSION"', source)
        self.assertIn('"chocolatey": os.environ["CFW_OBSERVED_CHOCOLATEY_VERSION"]', source)

        def parse_one(raw: str) -> str:
            lines = raw.replace("\r", "").splitlines()
            if len(lines) != 1 or not lines[0]:
                raise ValueError("non-canonical version output")
            return lines[0]

        self.assertEqual(parse_one("wine-11.0\n"), "wine-11.0")
        self.assertEqual(parse_one("2.6.0\n"), "2.6.0")
        for malformed in ("wine-\n11.0\n", "2.\n6.0\n", "\n2.6.0\n", ""):
            with self.subTest(malformed=malformed):
                with self.assertRaises(ValueError):
                    parse_one(malformed)

    def test_release_validator_reanchors_authoritative_inputs_and_archive_evidence(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "build-container-runtime.yml").read_text(encoding="utf-8")
        for token in (
            'sha256(runtime_inputs_path) == manifest["runtimeInputsSha256"]',
            'sha256(installer_path) == manifest["installerSha256"]',
            'manifest["contractSha256"] == sha256(contract_path)',
            'runtime["contractSha256"] == manifest["contractSha256"]',
            'archive_runtime = tar.extractfile("./.cfw/runtime.json")',
            'archive_runtime.read() == evidence.read_bytes()',
            'choco_interface in archive_names',
        ):
            self.assertIn(token, workflow)

    def test_release_gate_uses_authoritative_contract_and_cross_binds_provenance(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "build-container-runtime.yml").read_text(encoding="utf-8")
        for token in (
            "compat/contract.json",
            'runtime["contract"] == manifest["contract"] == contract["schemaVersion"]',
            'runtime["runtimeId"] == manifest["runtimeId"]',
            'runtime["installerSha256"] == manifest["installerSha256"]',
            'runtime["runtimeInputsSha256"] == manifest["runtimeInputsSha256"]',
            'manifest["requiredProofs"] == contract["build"]["requiredProofs"]',
            'runtime["wine"]["version"] == f"wine-{wine}"',
            'all(value is True for value in runtime["checks"].values())',
        ):
            self.assertIn(token, workflow)

    def test_runtime_archive_packaging_is_byte_reproducible(self) -> None:
        packager = ROOT / "compat" / "package-runtime.sh"
        source = packager.read_text(encoding="utf-8")
        for token in (
            "--sort=name",
            "--format=posix",
            "delete=atime",
            "delete=ctime",
            '--mtime="@${SOURCE_DATE_EPOCH}"',
            "--owner=0",
            "--group=0",
            "--numeric-owner",
            "gzip -n",
        ):
            self.assertIn(token, source)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prefixes = [root / "prefix-a", root / "prefix-b"]
            files = {
                "drive_c/z-last.txt": b"last\n",
                "drive_c/a-first.txt": b"first\n",
                ".cfw/runtime.json": b"{}\n",
            }
            for index, prefix in enumerate(prefixes):
                order = list(files.items()) if index == 0 else list(reversed(files.items()))
                for relative, payload in order:
                    target = prefix / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(payload)
                    os.utime(target, (1_600_000_000 + index, 1_600_000_000 + index))
                dosdevices = prefix / "dosdevices"
                dosdevices.mkdir()
                (dosdevices / "c:").symlink_to("../drive_c")
            archives = [root / "a.tar.gz", root / "b.tar.gz"]
            environment = {**os.environ, "SOURCE_DATE_EPOCH": "1700000000"}
            for prefix, archive in zip(prefixes, archives):
                subprocess.run(
                    ["bash", str(packager), str(prefix), str(archive)],
                    check=True,
                    env=environment,
                )
            self.assertEqual(archives[0].read_bytes(), archives[1].read_bytes())

    def test_runtime_workflow_resolves_image_digest_and_publishes_tagged_assets(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "build-container-runtime.yml").read_text(encoding="utf-8")

        self.assertIn("docker image inspect", workflow)
        self.assertIn("CFW_WINE_IMAGE", workflow)
        self.assertIn('"${{ steps.image.outputs.image }}" \\', workflow)
        self.assertIn("cfw-runtime-v*", workflow)
        self.assertIn("gh release create", workflow)
        self.assertIn("cfw-runtime-manifest-wine-", workflow)
        self.assertIn("emit failure evidence", workflow)
        self.assertIn("winepath-cfw-cache", workflow)
        self.assertIn("winepath-cfw-installer", workflow)
        self.assertIn("pwsh-probe", workflow)
        self.assertIn("pwsh-proof-summary", workflow)
        self.assertIn("pwsh-failure-trace", workflow)
        self.assertIn("pwsh-policy", workflow)
        self.assertIn("returnCodes", workflow)
        self.assertLess(workflow.index("pwsh-probe"), workflow.index("installer stages"))
        self.assertIn('head -c 2600', workflow)
        self.assertIn("CFW runtime build failed", workflow)
        self.assertIn("Compile CFW installer under test", workflow)
        self.assertIn("installer.c", workflow)
        self.assertIn("CFW_COMPILED_INSTALLER=/src/compat/ChoCinstaller-under-test.exe", workflow)
        self.assertIn("hashlib.sha256", workflow)
        self.assertIn("GITHUB_SHA", workflow)
        self.assertIn("SOURCE_DATE_EPOCH", workflow)
        self.assertIn("git show -s --format=%ct", workflow)
        self.assertIn("release already exists", workflow)
        self.assertNotIn("--clobber", workflow)

    def test_runtime_workflow_targets_contract_wine_inventory(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "build-container-runtime.yml").read_text(encoding="utf-8")
        contract = json.loads((ROOT / "compat" / "contract.json").read_text(encoding="utf-8"))
        self.assertEqual(contract["build"]["wineCandidates"], ["11.0"])
        self.assertIn("fromJSON(needs.contract.outputs.wines)", workflow)
        self.assertNotIn("wine: ['11.0']", workflow)

    def test_profile_fragments_are_additive(self) -> None:
        profile_dir = ROOT / "compat" / "profile.d"
        fragments = sorted(profile_dir.glob("*.ps1"))

        self.assertEqual(
            [path.name for path in fragments],
            [
                "20-chocolatey.ps1",
                "30-cfw-winetricks.ps1",
                "40-cfw-command-adapters.ps1",
            ],
        )
        for fragment in fragments:
            text = fragment.read_text(encoding="utf-8")
            self.assertNotIn("New-Item -Path $PROFILE", text)
            self.assertNotIn("Out-File $PROFILE", text)
            self.assertNotIn("WindowsPowerShell\\v1.0\\powershell.exe", text)

    def test_native_finalizer_remains_bounded(self) -> None:
        source = (ROOT / "compat" / "container-finalizer.c").read_text(encoding="utf-8")

        for variable in (
            "CFW_CONTAINER_BUILDER",
            "CFW_OFFLINE",
            "CFW_EXTERNAL_POWERSHELL",
        ):
            self.assertIn(variable, source)
        self.assertIn("stage=stage-resume", source)
        self.assertIn("stage=canonical-reconcile", source)
        self.assertIn("chocolatey.cfw-stage", source)
        self.assertNotIn("URLDownloadToFile", source)

    def test_legacy_wrapper_propagates_process_creation_failure(self) -> None:
        source = (ROOT / "mainv1.c").read_text(encoding="utf-8")

        self.assertIn("si.cb = sizeof(si);", source)
        self.assertIn("if (!CreateProcessW(", source)
        self.assertIn("return GetLastError();", source)
        self.assertIn("wait_result = WaitForSingleObject", source)
        self.assertIn("if (!GetExitCodeProcess", source)
        self.assertIn("CloseHandle(pi.hProcess);", source)
        self.assertIn("CloseHandle(pi.hThread);", source)


if __name__ == "__main__":
    unittest.main()
