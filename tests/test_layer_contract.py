import json
from pathlib import Path
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
        self.assertIn("chocolatey-lifecycle", contract["build"]["requiredProofs"])
        self.assertIn("synchro-x64-side-effect", contract["build"]["requiredProofs"])
        self.assertEqual(contract["ownership"]["profileLoader"], "cfw-runtime-artifact")
        self.assertTrue(contract["constraints"]["consumerMustVerifyRuntimeManifest"])
        self.assertFalse(contract["constraints"]["chocolateyInProcessPowerShellHost"])

    def test_runtime_builder_has_strict_proofs(self) -> None:
        source = (ROOT / "compat" / "build-runtime.sh").read_text(encoding="utf-8")
        inputs = json.loads((ROOT / "compat" / "runtime-inputs.json").read_text(encoding="utf-8"))

        self.assertIn("winepath_to_windows", source)
        self.assertIn("winepath-${label}.log", source)
        self.assertIn("Wine path conversion failed", source)
        self.assertIn('cfw_cache_win="$(winepath_to_windows cfw-cache "$work")"', source)
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
        self.assertIn("feature disable --name=powershellHost", source)
        self.assertIn("pwsh-probe.log", source)
        self.assertIn("synchro-x64.txt", source)
        self.assertIn("synchro-x86.txt", source)
        self.assertIn("cfw-runtime-prefix", source)
        self.assertIn("cfw.runtime-build/v2", source)

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
        self.assertIn("CFW_RUNTIME_INPUTS_SHA256", source)
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
        self.assertIn("values = [int(value) for value in sys.argv[2:19]]", source)
        self.assertIn("markers = [Path(value) for value in sys.argv[19:]]", source)

    def test_runtime_workflow_resolves_image_digest_and_publishes_tagged_assets(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "build-container-runtime.yml").read_text(encoding="utf-8")

        self.assertIn("docker image inspect", workflow)
        self.assertIn("CFW_WINE_IMAGE", workflow)
        self.assertIn("cfw-runtime-v*", workflow)
        self.assertIn("gh release create", workflow)
        self.assertIn("cfw-runtime-manifest-wine-", workflow)
        self.assertIn("emit failure evidence", workflow)
        self.assertIn("winepath-cfw-cache", workflow)
        self.assertIn("winepath-cfw-installer", workflow)
        self.assertIn("CFW runtime build failed", workflow)
        self.assertIn("hashlib.sha256", workflow)
        self.assertIn("GITHUB_SHA", workflow)
        self.assertIn("release already exists", workflow)
        self.assertNotIn("--clobber", workflow)

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
