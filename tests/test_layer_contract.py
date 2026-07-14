import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LayerContractTests(unittest.TestCase):
    def test_contract_requires_synchro_wrapper(self) -> None:
        contract = json.loads((ROOT / "compat" / "contract.json").read_text(encoding="utf-8"))

        self.assertEqual(contract["mode"], "additive-compatibility-pack")
        self.assertEqual(
            contract["requires"]["powershell.winps-shim"]["provider"],
            "synchro/powershell-wrapper-for-wine",
        )
        self.assertEqual(contract["ownership"]["windowsPowerShellShim"], "synchro")
        self.assertFalse(contract["constraints"]["overwritePowerShellProfile"])
        self.assertFalse(contract["constraints"]["installCompetingPowerShellShim"])
        self.assertEqual(
            contract["tools"]["containerFinalizer"]["requiredEnvironment"],
            ["CFW_CONTAINER_BUILDER", "CFW_OFFLINE", "CFW_EXTERNAL_POWERSHELL"],
        )

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

    def test_container_finalizer_requires_external_layer(self) -> None:
        source = (ROOT / "compat" / "container-finalizer.c").read_text(encoding="utf-8")

        for variable in (
            "CFW_CONTAINER_BUILDER",
            "CFW_OFFLINE",
            "CFW_EXTERNAL_POWERSHELL",
        ):
            self.assertIn(variable, source)
        self.assertIn("%ProgramFiles%\\\\PowerShell\\\\7\\\\pwsh.exe", source)
        self.assertIn("System32\\\\WindowsPowerShell", source)
        self.assertIn("SysWOW64\\\\WindowsPowerShell", source)
        self.assertIn("stage=stage-resume", source)
        self.assertIn("stage=canonical-reconcile", source)
        self.assertIn("chocolatey.cfw-stage", source)
        self.assertNotIn("msiexec", source.lower())
        self.assertNotIn("URLDownloadToFile", source)
        self.assertNotIn("CreateProcessW", source)

    def test_legacy_wrapper_propagates_process_creation_failure(self) -> None:
        source = (ROOT / "mainv1.c").read_text(encoding="utf-8")

        self.assertIn("si.cb = sizeof(si);", source)
        self.assertIn("if (!CreateProcessW(", source)
        self.assertIn("return GetLastError();", source)
        self.assertIn("wait_result = WaitForSingleObject", source)
        self.assertIn("if (!GetExitCodeProcess", source)
        self.assertIn("CloseHandle(pi.hProcess);", source)
        self.assertIn("CloseHandle(pi.hThread);", source)
        self.assertNotIn(
            "CreateProcessW(0, cl, 0, 0, 0, 0, 0, 0, &si, &pi);\n"
            "    WaitForSingleObject(pi.hProcess, INFINITE);",
            source,
        )


if __name__ == "__main__":
    unittest.main()
