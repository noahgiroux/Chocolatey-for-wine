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

    def test_offline_mode_blocks_download_fallbacks_and_uses_cached_dotnet(self):
        download = INSTALLER[INSTALLER.index("static DWORD download_file") : INSTALLER.index("static DWORD validate_canonical_choco")]
        self.assertIn('_wgetenv(L"CFW_OFFLINE")', download)
        self.assertLess(download.index('_wgetenv(L"CFW_OFFLINE")'), download.index("URLDownloadToFileW"))
        self.assertIn("cached_dotnet", MAIN)
        self.assertIn("CopyFileW(cached_dotnet", MAIN)

    def test_container_builder_uses_native_canonical_promotion(self):
        pscore = INSTALLER[INSTALLER.index("DWORD WINAPI pscore_install") : INSTALLER.index("DWORD WINAPI cdrive_install")]
        self.assertIn('_wgetenv(L"CFW_CONTAINER_BUILDER")', pscore)
        self.assertIn('_wgetenv(L"CFW_OFFLINE")', pscore)
        self.assertIn("native_finalize_chocolatey()", pscore)
        self.assertIn("pscore_install(&p)", MAIN)
        self.assertLess(MAIN.index("WaitForMultipleObjects"), MAIN.index("pscore_install(&p)"))

        native = INSTALLER[INSTALLER.index("static DWORD native_finalize_chocolatey") : INSTALLER.index("DWORD WINAPI net48_install")]
        self.assertIn('L"%ProgramData%\\\\tools\\\\chocolateyInstall"', native)
        self.assertIn('L"%ProgramData%\\\\chocolatey"', native)
        self.assertIn("MoveFileExW", native)
        self.assertIn("MOVEFILE_COPY_ALLOWED", native)
        self.assertIn("MOVEFILE_REPLACE_EXISTING", native)
        self.assertIn("FILE_ATTRIBUTE_REPARSE_POINT", native)
        self.assertIn("ERROR_ALREADY_EXISTS", native)
        self.assertIn('L"\\\\choco.exe"', native)
        self.assertIn('L"\\\\bin\\\\choco.exe"', native)
        self.assertIn('L".cfw-part"', native)
        self.assertIn("CopyFileW(root_choco, staged_choco, TRUE)", native)
        self.assertIn("GetFileAttributesW(canonical_choco)", native)
        self.assertNotIn("redirects", native)
        self.assertIn("RegSetValueExW(", native)
        self.assertIn('L"ChocolateyInstall"', native)
        self.assertIn('L"Path"', native)
        self.assertIn("RegQueryValueExW", native)
        self.assertIn("ExpandEnvironmentStringsW(", native)
        self.assertIn("machine_path,", native)
        self.assertIn("process_path,", native)
        self.assertIn("SetEnvironmentVariableW", native)
        self.assertIn("configure_container_pwsh_policy()", native)

        policy = INSTALLER[
            INSTALLER.index("static DWORD configure_container_pwsh_policy") :
            INSTALLER.index("static DWORD native_finalize_chocolatey")
        ]
        self.assertIn('L"Software\\\\Wine\\\\AppDefaults\\\\pwsh.exe\\\\DllOverrides"', policy)
        self.assertIn('L"amsi"', policy)
        self.assertIn('L"dwmapi"', policy)
        self.assertIn('L"rpcrt4"', policy)
        self.assertIn('L"native,builtin"', policy)
        self.assertIn("pwsh-policy-complete", policy)

    def test_installer_reports_container_builder_stage_progress(self):
        stages = (
            "bootstrap-start",
            "net48-start",
            "chocolatey-payload-start",
            "cdrive-start",
            "prerequisites-complete",
            "native-finalizer-start",
            "native-finalizer-complete",
            "powershell-start",
            "finalizer-start",
            "finalizer-complete",
            "canonical-check",
            "bootstrap-complete",
        )
        self.assertIn("static void log_stage", INSTALLER)
        for stage in stages:
            self.assertIn(f'log_stage("[cfw] stage={stage}\\n")', INSTALLER)

    def test_success_requires_canonical_chocolatey(self):
        self.assertIn(
            'L"%ProgramData%\\\\chocolatey\\\\bin\\\\choco.exe"',
            INSTALLER,
        )
        self.assertIn("validate_canonical_choco", INSTALLER)

    def test_installer_directory_is_derived_without_trailing_separator(self):
        self.assertIn("module_name = wcsrchr(p.pathW, L'\\\\')", MAIN)
        self.assertIn("p.filenameW = wcsdup(module_name)", MAIN)
        self.assertIn("*module_name = 0", MAIN)
        self.assertIn("module_path_length >= MAX_PATH", MAIN)
        self.assertIn("wcslen(module_name) <= 22", MAIN)
        self.assertLess(MAIN.index("p.filenameW = wcsdup(module_name)"), MAIN.index("*module_name = 0"))
        self.assertNotIn("wcslen(p.pathW) - 26", MAIN)

    def test_powershell_finalizer_command_has_argv0_and_explicit_file_mode(self):
        pscore = INSTALLER[INSTALLER.index("DWORD WINAPI pscore_install") : INSTALLER.index("DWORD WINAPI cdrive_install")]
        self.assertIn("append_wide(", pscore)
        self.assertIn("expanded_path_length", pscore)
        self.assertIn("expanded_path_length > MAX_PATH", pscore)
        self.assertNotIn("swprintf(", pscore)
        self.assertIn('L"\\\" -NoLogo -NonInteractive -File \\\""', pscore)
        self.assertIn('L"\\\\choc_install.ps1\\\" \\\""', pscore)
        self.assertIn("ERROR_INSUFFICIENT_BUFFER", pscore)
        self.assertIn('_wcsicmp(argv[i], L"/s")', MAIN)
        self.assertIn('_wcsicmp(argv[i], L"/q")', MAIN)
        script = (ROOT / "choc_install.ps1").read_text(encoding="utf-8")
        self.assertIn("[cfw] stage=finalizer-script-entry", script[:200])

    def test_powershell_finalizer_fails_on_nonterminating_errors(self):
        script = (ROOT / "choc_install.ps1").read_text(encoding="utf-8")
        self.assertIn("$ErrorActionPreference = 'Stop'", script[:500])

    def test_release_workflow_validates_contracts_on_fix_branches(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        self.assertIn("- 'fix/**'", workflow)
        self.assertIn("python3 -m unittest discover -s tests", workflow)
        self.assertIn('ver="${ver%%-*}"', workflow)
        self.assertIn("contents: write", workflow)
        self.assertIn("gh release create", workflow)
        self.assertIn("--prerelease", workflow)
        self.assertIn("compile-installer.log", workflow)
        self.assertIn("Installer compile failed", workflow)
        self.assertIn('rc="${PIPESTATUS[0]}"', workflow)

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
