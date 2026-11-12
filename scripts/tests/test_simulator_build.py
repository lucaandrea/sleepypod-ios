"""Exercise the real shell entry points without compiling or dropping test selectors."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class SimulatorBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="simulator build ")
        self.addCleanup(self.temporary.cleanup)
        self.directory = pathlib.Path(self.temporary.name)
        self.environment = dict(os.environ, RUNNER_TEMP=str(self.directory),
                                PATH=f"{self.directory}:{os.environ['PATH']}")
        self.write_command("uname", '#!/bin/bash\nprintf "%s\\n" "$TEST_ARCHITECTURE"\n')
        self.write_command("xcodebuild", f"#!{sys.executable}\nimport json, os, sys\n"
                           "print(json.dumps(sys.argv[1:]))\n"
                           "sys.exit(int(os.environ.get('TEST_BUILD_EXIT', '0')))\n")

    def write_command(self, name, contents):
        command = self.directory / name
        command.write_text(contents)
        command.chmod(0o755)

    def run_script(self, script, *arguments, architecture="x86_64", build_exit="0"):
        environment = dict(self.environment, TEST_ARCHITECTURE=architecture,
                           TEST_BUILD_EXIT=build_exit)
        return subprocess.run(["bash", str(ROOT / "scripts" / script), *arguments],
                              cwd=ROOT, env=environment, capture_output=True, text=True)

    def test_shared_builds_select_only_runner_architecture_and_preserve_suites(self):
        expected = {
            "verify-practice-ui.sh": ["ControlPracticeUITests", "HouseholdPreparationUITests"],
            "verify-recordings-ui.sh": ["PersonalHistoryUITests", "PersonalLearningUITests",
                                       "PersonalLearningRemovalUITests", "PersonalJournalUITests",
                                       "PersonalJournalPatternsUITests"],
        }
        for script, suites in expected.items():
            for architecture in ["arm64", "x86_64"]:
                with self.subTest(script=script, architecture=architecture):
                    result = self.run_script(script, "build", "all", architecture=architecture)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    arguments = json.loads(result.stdout)
                    self.assertEqual(arguments[0], "build-for-testing")
                    self.assertEqual(arguments[arguments.index("-destination") + 1],
                                     "generic/platform=iOS Simulator")
                    self.assertEqual([item for item in arguments if item.startswith("ARCHS=")],
                                     [f"ARCHS={architecture}"])
                    self.assertIn("CODE_SIGNING_ALLOWED=YES", arguments)
                    self.assertIn("CODE_SIGN_IDENTITY=-", arguments)
                    self.assertTrue(arguments[arguments.index("-derivedDataPath") + 1]
                                    .startswith(str(self.directory)))
                    self.assertEqual([item for item in arguments if item.startswith("-only-testing:")],
                                     [f"-only-testing:SleepypodUITests/{suite}" for suite in suites])

    def test_unknown_architecture_stops_before_xcodebuild(self):
        result = self.run_script("verify-practice-ui.sh", "build", "all", architecture="unknown")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("Unsupported simulator runner architecture", result.stderr)

    def test_build_failure_is_not_hidden(self):
        result = self.run_script("verify-practice-ui.sh", "build", "all", build_exit="65")
        self.assertEqual(result.returncode, 65)

    def test_execution_keeps_shared_bundle_and_selected_scenarios(self):
        bundle = self.directory / "Practice.xctestrun"
        bundle.touch()
        self.environment.update(PRACTICE_TEST_RUN=str(bundle), PRACTICE_SIM_ID="simulator-id")
        result = self.run_script("verify-practice-ui.sh", "test", "invitations")
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments = json.loads(result.stdout)
        self.assertEqual(arguments[0], "test-without-building")
        self.assertEqual(arguments[arguments.index("-xctestrun") + 1], str(bundle))
        self.assertEqual(arguments[arguments.index("-destination") + 1],
                         "platform=iOS Simulator,id=simulator-id")
        selectors = self.run_script("verify-practice-ui.sh", "list", "invitations").stdout.splitlines()
        self.assertEqual([item for item in arguments if item.startswith("-only-testing:")],
                         [f"-only-testing:{selector}" for selector in selectors])
        self.assertFalse(any(item.startswith("ARCHS=") for item in arguments))


if __name__ == "__main__":
    unittest.main()
