#!/usr/bin/env python3
"""Exercise scripts/testflight with a fake xcodebuild in a throwaway repo."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("testflight")


STUB_XCODEBUILD = r'''#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys

repo = Path(os.environ["TEST_REPO"])
log = Path(os.environ["TEST_XCODEBUILD_LOG"])
cwd = Path.cwd()
if not (cwd / "Footplate.xcodeproj/project.pbxproj").is_file():
    sys.exit("xcodebuild did not run from the exported project")
if (cwd / "landed-during-archive").exists():
    sys.exit("xcodebuild saw a commit that landed after the snapshot")
with log.open("a") as output:
    output.write(str(cwd) + "\n")

if sys.argv[1] == "archive":
    if os.environ.get("TEST_FAIL_ARCHIVE") == "1":
        sys.exit(42)
    if os.environ.get("TEST_LAND_DURING_ARCHIVE") == "1":
        (repo / "landed-during-archive").write_text("later commit\n")
        subprocess.run(["git", "-C", str(repo), "add", "landed-during-archive"], check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-m", "landing"], check=True)
elif sys.argv[1] == "-exportArchive":
    export_path = Path(sys.argv[sys.argv.index("-exportPath") + 1])
    export_path.mkdir(parents=True, exist_ok=True)
    (export_path / "fixture.ipa").write_text("exported\n")
else:
    sys.exit("unexpected xcodebuild arguments")
'''


class TestFlightSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.home = self.root / "home"
        key = self.home / ".appstoreconnect/private_keys/AuthKey_fixture.p8"
        key.parent.mkdir(parents=True)
        key.write_text("fixture only\n")
        self.tmpdir = self.root / "tmp"
        self.tmpdir.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        xcodebuild = self.bin / "xcodebuild"
        xcodebuild.write_text(STUB_XCODEBUILD)
        xcodebuild.chmod(0o755)
        self.log = self.root / "xcodebuild-cwds"

        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Test Flight")
        self.git("config", "user.email", "testflight@example.invalid")
        (self.repo / "Footplate.xcodeproj").mkdir()
        (self.repo / "Footplate.xcodeproj/project.pbxproj").write_text("fixture project\n")
        (self.repo / "source-marker").write_text("starting commit\n")
        (self.repo / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.repo / "scripts/testflight")
        self.git("add", ".")
        self.git("commit", "-qm", "starting snapshot")
        self.start = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            check=True,
            text=True,
            capture_output=True,
        )

    def run_testflight(self, **extra_env):
        env = os.environ.copy()
        env.update(
            {
                "ASC_KEY_ID": "fixture",
                "ASC_ISSUER_ID": "fixture-issuer",
                "HOME": str(self.home),
                "PATH": str(self.bin) + os.pathsep + env["PATH"],
                "TMPDIR": str(self.tmpdir),
                "TEST_REPO": str(self.repo),
                "TEST_XCODEBUILD_LOG": str(self.log),
            }
        )
        env.update(extra_env)
        return subprocess.run(
            ["sh", str(self.repo / "scripts/testflight"), "--no-upload"],
            cwd=self.repo,
            env=env,
            text=True,
            capture_output=True,
        )

    def test_landing_during_archive_keeps_the_starting_snapshot(self):
        result = self.run_testflight(TEST_LAND_DURING_ARCHIVE="1")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"build 1 ({self.start})", result.stdout)
        self.assertIn("(not uploaded)", result.stdout)
        self.assertEqual(self.git("rev-list", "--count", "main").stdout.strip(), "2")
        self.assertTrue((self.repo / "landed-during-archive").is_file())

        snapshot = Path(self.log.read_text().splitlines()[0])
        self.assertFalse(snapshot.exists(), "snapshot directory should be removed on success")
        self.assertEqual(len(self.log.read_text().splitlines()), 2)
        export = Path(result.stdout.strip().split(" exported to ", 1)[1].split(" ", 1)[0])
        self.assertTrue((export / "fixture.ipa").is_file(), "--no-upload should retain the export")

    def test_failed_archive_removes_the_snapshot(self):
        result = self.run_testflight(TEST_FAIL_ARCHIVE="1")

        self.assertNotEqual(result.returncode, 0)
        snapshot = Path(self.log.read_text().splitlines()[0])
        self.assertFalse(snapshot.exists(), "snapshot directory should be removed on failure")


if __name__ == "__main__":
    unittest.main()
