"""Require the CI split to cover every original practice scenario exactly once."""
import pathlib
import re
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class PracticeGroupsTests(unittest.TestCase):
    def test_all_scenarios_are_selected_once(self):
        expected = set()
        for suite in ["ControlPracticeUITests", "HouseholdPreparationUITests"]:
            text = (ROOT / "SleepypodUITests" / f"{suite}.swift").read_text()
            for name in re.findall(r"func (test\w+)\(", text):
                expected.add(f"SleepypodUITests/{suite}/{name}")
        actual = []
        for group in ["journey", "accessibility", "invitations"]:
            output = subprocess.check_output(["bash", str(ROOT / "scripts/verify-practice-ui.sh"),
                                              "list", group], text=True)
            selectors = output.splitlines()
            self.assertGreater(len(selectors), 0)
            self.assertLessEqual(len(selectors), 3)
            actual.extend(selectors)
        self.assertEqual(len(actual), len(set(actual)), "A scenario runs in multiple groups")
        self.assertEqual(set(actual), expected)


if __name__ == "__main__":
    unittest.main()
