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
        self.assertFalse(contract["constraints"]["chocolateyInProcessPowerShellHost"])

    def test_runtime_builder_has_strict_proofs(self) -> None:
        source = (ROOT / "compat" / "build-runtime.sh").read_text(encoding="utf-8")

        self.assertIn("CFW_OFFLINE=1", source)
        self.assertIn("unset CFW_CONTAINER_BUILDER", source)
        self.assertIn("PowerShell-7.5.5-win-x64.msi", source)
        self.assertIn("powershell-wrapper-for-wine/releases/download/v4.2.0", source)
        self.assertIn("b1d594bd44abc01007b9dd2adea5248f09906fa8d4c6cea7f36a4279e2de91e0", source)
        self.assertIn("ca76d774273ffa37053545f8e4ad63c8914461828f1d1eef7a1915c9656fed4c", source)
        self.assertIn("feature disable --name=powershellHost", source)
        self.assertIn("pwsh-probe.log", source)
        self.assertIn("synchro-x64-ok", source)
        self.assertIn("synchro-x86-ok", source)
        self.assertIn("cfw-runtime-prefix.tar.gz", source)
        self.assertIn("cfw.runtime-build/v1", source)

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
