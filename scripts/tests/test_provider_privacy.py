"""Exercise the actual build script while Xcode-like readers inspect the bundle."""
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "apply-provider-privacy.sh"


class ProviderPrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="provider privacy ")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.source = self.root / "FreeSleepKit/Resources/PrivacyInfo.xcprivacy"
        self.target = self.root / "Products/Sleepypod.app/AIProxy_AIProxy.bundle/PrivacyInfo.xcprivacy"
        self.source.parent.mkdir(parents=True)
        self.target.parent.mkdir(parents=True)
        self.expected = {"NSPrivacyTracking": False, "NSPrivacyCollectedDataTypes": []}
        self.original = {"Original": True}
        self.source.write_bytes(plistlib.dumps(self.expected))
        self.target.write_bytes(plistlib.dumps(self.original))
        self.environment = dict(os.environ, SRCROOT=str(self.root),
                                TARGET_BUILD_DIR=str(self.root / "Products"),
                                UNLOCALIZED_RESOURCES_FOLDER_PATH="Sleepypod.app")

    def run_script(self):
        return subprocess.run(["/bin/sh", str(SCRIPT)], env=self.environment,
                              capture_output=True, text=True, check=False)

    def test_concurrent_reader_always_sees_complete_plist(self):
        # Hold the copy halfway through, reproducing the old in-place truncation.
        helpers = self.root / "helpers"
        helpers.mkdir()
        copy = helpers / "cp"
        copy.write_text(f"#!{sys.executable}\n" + """
import os, pathlib, sys, time
source, destination = map(pathlib.Path, sys.argv[1:])
payload = source.read_bytes()
with destination.open('wb') as stream:
    stream.write(payload[:20]); stream.flush()
    pathlib.Path(os.environ['COPY_READY']).touch()
    while not pathlib.Path(os.environ['COPY_CONTINUE']).exists():
        time.sleep(0.01)
    stream.write(payload[20:])
""")
        copy.chmod(0o755)
        ready, resume = self.root / "ready", self.root / "resume"
        self.environment.update(PATH=str(helpers) + os.pathsep + os.environ["PATH"],
                                COPY_READY=str(ready), COPY_CONTINUE=str(resume))
        process = subprocess.Popen(["/bin/sh", str(SCRIPT)], env=self.environment,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(ready.exists(), "Copy did not reach the controlled interruption")
            self.assertEqual(plistlib.loads(self.target.read_bytes()), self.original)
            resume.touch()
            deadline = time.monotonic() + 5
            while process.poll() is None and time.monotonic() < deadline:
                self.assertIn(plistlib.loads(self.target.read_bytes()), [self.original, self.expected])
            _, errors = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 0, errors.decode())
            self.assertEqual(plistlib.loads(self.target.read_bytes()), self.expected)
            self.assertEqual(list(self.target.parent.glob("PrivacyInfo.xcprivacy.*")), [])
        finally:
            resume.touch()
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

    def test_invalid_source_preserves_original(self):
        self.source.write_text("not a property list")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(plistlib.loads(self.target.read_bytes()), self.original)

    def test_repeated_build_keeps_expected_manifest_readable(self):
        for _ in range(2):
            result = self.run_script()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(plistlib.loads(self.target.read_bytes()), self.expected)
            self.assertEqual(self.target.stat().st_mode & 0o777, 0o644)

    def test_absent_sdk_bundle_is_not_created(self):
        self.target.unlink()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.target.exists())


if __name__ == "__main__":
    unittest.main()
