import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / ".github" / "scripts" / "check-upstream-drift.sh"


class UpstreamWatchTests(unittest.TestCase):
    def run_check(self, repository: Path, upstream: str = "canonical-upstream/main") -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(SCRIPT), "HEAD", upstream],
            cwd=repository,
            env={**os.environ, "GITHUB_STEP_SUMMARY": str(repository / "summary.md")},
            text=True,
            capture_output=True,
            check=False,
        )

    def create_repository(self) -> tuple[Path, str]:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        repository = Path(directory.name)
        subprocess.run(["git", "init", "-q", "-b", "main"], cwd=repository, check=True)
        subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repository, check=True)
        subprocess.run(["git", "config", "user.name", "Test"], cwd=repository, check=True)
        (repository / "tracked.txt").write_text("base\n", encoding="utf-8")
        subprocess.run(["git", "add", "tracked.txt"], cwd=repository, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "base"], cwd=repository, check=True)
        base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
        subprocess.run(["git", "branch", "canonical-upstream/main"], cwd=repository, check=True)
        return repository, base

    def commit(self, repository: Path, message: str, content: str) -> None:
        (repository / "tracked.txt").write_text(content, encoding="utf-8")
        subprocess.run(["git", "add", "tracked.txt"], cwd=repository, check=True)
        subprocess.run(["git", "commit", "-q", "-m", message], cwd=repository, check=True)

    def test_no_unseen_commits_succeeds(self) -> None:
        repository, _ = self.create_repository()
        result = self.run_check(repository)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("No unseen canonical upstream commits.", result.stdout)

    def test_tree_identical_unseen_commit_succeeds(self) -> None:
        repository, base = self.create_repository()
        subprocess.run(["git", "commit", "--allow-empty", "-q", "-m", "metadata-only upstream commit"], cwd=repository, check=True)
        upstream_tip = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True).strip()
        subprocess.run(["git", "reset", "--hard", "-q", base], cwd=repository, check=True)
        subprocess.run(["git", "update-ref", "refs/heads/canonical-upstream/main", upstream_tip], cwd=repository, check=True)
        result = self.run_check(repository)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("identical tree", result.stdout)

    def test_tree_change_in_unseen_commit_fails(self) -> None:
        repository, _ = self.create_repository()
        subprocess.run(["git", "checkout", "-q", "canonical-upstream/main"], cwd=repository, check=True)
        self.commit(repository, "upstream source change", "changed\n")
        subprocess.run(["git", "checkout", "-q", "main"], cwd=repository, check=True)
        result = self.run_check(repository)
        self.assertEqual(result.returncode, 1)
        self.assertIn("need review", result.stderr)


if __name__ == "__main__":
    unittest.main()
