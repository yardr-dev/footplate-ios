#!/usr/bin/env python3
"""Exercise .yardr/test's failure diagnosis with fake xcodebuild and xcrun."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parent.parent / ".yardr" / "test"


STUB_XCODEBUILD = r'''#!/usr/bin/env python3
import os
import sys
from pathlib import Path

Path(os.environ["TEST_ARGV_LOG"]).write_text("\n".join(sys.argv[1:]) + "\n")
bundle = sys.argv[sys.argv.index("-resultBundlePath") + 1]
mode = os.environ.get("TEST_GATE_MODE", "pass")
if mode != "nobundle-fail":
    Path(bundle).mkdir(parents=True)
if mode == "pass":
    print("Executed 417 tests, with 0 failures (0 unexpected)")
    print("** TEST SUCCEEDED **")
elif mode == "empty-pass":
    print("** TEST SUCCEEDED **")
elif mode == "mute-fail" or mode == "nobundle-fail":
    print("Testing failed:")
    print("** TEST FAILED **")
    sys.exit(65)
elif mode == "named-fail":
    print("Test Case '-[FootplateTests.FooTests testBar]' failed (0.001 seconds).")
    print("Testing failed:")
    print("** TEST FAILED **")
    sys.exit(65)
else:
    sys.exit("unexpected TEST_GATE_MODE")
'''


STUB_XCRUN = r'''#!/usr/bin/env python3
import os
import sys
from pathlib import Path

if "bootstatus" in sys.argv:
    sys.exit(0)
if sys.argv[1] == "xcresulttool":
    with Path(os.environ["TEST_XCRUN_LOG"]).open("a") as output:
        output.write("\n".join(sys.argv[1:]) + "\n")
    if os.environ.get("TEST_SUMMARY_MODE") == "unreadable":
        print("{}")
    else:
        print(os.environ["TEST_SUMMARY"])
    sys.exit(0)
sys.exit("unexpected xcrun arguments")
'''


STUB_FLOCK = r'''#!/usr/bin/env python3
import os
import sys

args = sys.argv[1:]
while args and args[0].startswith("-"):
    args.pop(0)
os.execvp(args[1], args[1:])
'''


# Shaped like the real 21:23:54 killed-host summary (footplate-ios-ara3): the
# run failed, the crashed test counts failed in the bundle, and the bundle
# names the kill its stdout never did.
CANNED_SUMMARY = """{
  "failedTests" : 1,
  "passedTests" : 11,
  "result" : "Failed",
  "skippedTests" : 0,
  "testFailures" : [
    {
      "failureText" : "Test crashed with signal kill.",
      "targetName" : "FootplateTests",
      "testName" : "testCrewScreensRender()"
    }
  ]
}
"""


class GateDiagnosisTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        shutil.copy2(SCRIPT, self.repo / "test")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name, text in [
            ("xcodebuild", STUB_XCODEBUILD),
            ("xcrun", STUB_XCRUN),
            ("flock", STUB_FLOCK),
        ]:
            stub = self.bin / name
            stub.write_text(text)
            stub.chmod(0o755)
        self.argv_log = self.root / "xcodebuild-argv"
        self.xcrun_log = self.root / "xcrun-calls"

    def run_gate(self, *args, **extra_env):
        env = os.environ.copy()
        env.update(
            {
                "PATH": str(self.bin) + os.pathsep + env["PATH"],
                "TEST_ARGV_LOG": str(self.argv_log),
                "TEST_XCRUN_LOG": str(self.xcrun_log),
                "TEST_SUMMARY": CANNED_SUMMARY,
            }
        )
        env.update(extra_env)
        return subprocess.run(
            ["sh", str(self.repo / "test"), *args],
            cwd=self.repo,
            env=env,
            text=True,
            capture_output=True,
        )

    def bundle_path(self):
        argv = self.argv_log.read_text().splitlines()
        return Path(argv[argv.index("-resultBundlePath") + 1])

    def test_mute_failure_prints_summary_and_keeps_bundle(self):
        result = self.run_gate(TEST_GATE_MODE="mute-fail")

        self.assertEqual(result.returncode, 65, result.stderr)
        bundle = self.bundle_path()
        self.assertIn(f"bundle: {bundle}", result.stderr)
        self.assertTrue(bundle.is_dir(), "a failed run should keep its bundle")
        self.assertIn("xcresulttool", self.xcrun_log.read_text())
        self.assertIn('"result" : "Failed"', result.stderr)
        self.assertIn('"failureText" : "Test crashed with signal kill."', result.stderr)
        self.assertIn('"testName" : "testCrewScreensRender()"', result.stderr)

    def test_named_failure_prints_path_only(self):
        result = self.run_gate(TEST_GATE_MODE="named-fail")

        self.assertEqual(result.returncode, 65, result.stderr)
        bundle = self.bundle_path()
        self.assertIn(f"bundle: {bundle}", result.stderr)
        self.assertTrue(bundle.is_dir(), "a failed run should keep its bundle")
        self.assertFalse(self.xcrun_log.exists(), "xcresulttool should not run")
        self.assertNotIn('"result"', result.stderr)

    def test_success_removes_temp_dir(self):
        result = self.run_gate(TEST_GATE_MODE="pass")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.bundle_path().exists(), "a pass should remove its bundle")
        self.assertFalse(self.xcrun_log.exists(), "xcresulttool should not run")

    def test_failure_without_bundle_says_so(self):
        result = self.run_gate(TEST_GATE_MODE="nobundle-fail")

        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn("no result bundle was written", result.stderr)
        self.assertFalse(self.xcrun_log.exists(), "xcresulttool should not run")

    def test_unreadable_summary_says_so(self):
        result = self.run_gate(TEST_GATE_MODE="mute-fail", TEST_SUMMARY_MODE="unreadable")

        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn("summary is unreadable", result.stderr)

    def test_named_run_threads_the_suite_and_counts(self):
        result = self.run_gate("PushRegisterTests", TEST_GATE_MODE="pass")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-only-testing:FootplateTests/PushRegisterTests", self.argv_log.read_text())

    def test_named_run_without_executed_line_fails(self):
        result = self.run_gate("PushRegisterTests", TEST_GATE_MODE="empty-pass")

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("no tests ran", result.stderr)
        self.assertFalse(self.bundle_path().exists())


if __name__ == "__main__":
    unittest.main()
