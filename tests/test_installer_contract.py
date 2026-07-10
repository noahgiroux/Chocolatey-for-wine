from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "installer.c").read_text(encoding="utf-8")
MAIN = INSTALLER[INSTALLER.index("int mainCRTStartup") :]


class InstallerOrchestrationContractTests(unittest.TestCase):
    def test_finalizer_runs_only_after_prerequisite_threads_finish(self):
        wait = MAIN.find("WaitForMultipleObjects")
        finalizer = MAIN.find("pscore_install(&p)")

        self.assertGreaterEqual(wait, 0)
        self.assertGreaterEqual(finalizer, 0)
        self.assertLess(wait, finalizer)
        self.assertNotIn("CreateThread(NULL, 0, pscore_install", MAIN)

    def test_prerequisite_thread_failures_are_propagated(self):
        self.assertIn("GetExitCodeThread", MAIN)
        self.assertIn("ExitProcess(exit_code)", MAIN)
        self.assertNotIn("ExitProcess(0);", MAIN)

    def test_child_process_exit_codes_are_checked(self):
        self.assertIn("run_process", INSTALLER)
        self.assertIn("GetExitCodeProcess", INSTALLER)
        self.assertIn("ERROR_SUCCESS_REBOOT_REQUIRED", INSTALLER)

    def test_success_requires_canonical_chocolatey(self):
        self.assertIn(
            'L"%ProgramData%\\\\chocolatey\\\\bin\\\\choco.exe"',
            INSTALLER,
        )
        self.assertIn("validate_canonical_choco", INSTALLER)

    def test_powershell_finalizer_fails_on_nonterminating_errors(self):
        script = (ROOT / "choc_install.ps1").read_text(encoding="utf-8")
        self.assertIn("$ErrorActionPreference = 'Stop'", script[:500])

    def test_release_workflow_validates_contracts_on_fix_branches(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("- 'fix/**'", workflow)
        self.assertIn("python3 -m unittest discover -s tests", workflow)

    def test_canonical_upstream_changes_are_monitored(self):
        workflow_path = ROOT / ".github/workflows/upstream-watch.yml"
        self.assertTrue(workflow_path.is_file())
        workflow = workflow_path.read_text(encoding="utf-8")
        self.assertIn("schedule:", workflow)
        self.assertIn("PietJankbal/Chocolatey-for-wine.git", workflow)
        self.assertIn("HEAD..canonical-upstream/main", workflow)
        self.assertNotIn("git merge", workflow)


if __name__ == "__main__":
    unittest.main()
