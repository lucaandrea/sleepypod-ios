import pathlib
import re
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/verify-recordings-ui.sh'


class RecordingsGroupsTests(unittest.TestCase):
    def test_every_original_suite_runs_exactly_once_per_form(self):
        expected = {
            'PersonalHistoryUITests', 'PersonalLearningUITests',
            'PersonalLearningRemovalUITests', 'PersonalJournalUITests',
            'PersonalJournalPatternsUITests',
        }
        selected = []
        for group in ['history', 'learning', 'removal', 'journal', 'patterns']:
            result = subprocess.run(['bash', str(SCRIPT), 'list', group], check=True,
                                    capture_output=True, text=True)
            selected.extend(line.removeprefix('SleepypodUITests/') for line in result.stdout.splitlines())
        self.assertEqual(set(selected), expected)
        self.assertEqual(len(selected), len(expected))
        methods = sum(len(re.findall(r'func (test\w+)\(', (ROOT / 'SleepypodUITests' / f'{name}.swift').read_text()))
                      for name in selected)
        self.assertEqual(methods, 25)
        workflow = (ROOT / '.github/workflows/personal-history-ui.yml').read_text()
        self.assertIn('form: [iPhone, iPad]', workflow)
        self.assertIn('suite: [history, learning, removal, journal, patterns]', workflow)

    def test_unknown_group_cannot_silently_run_no_tests(self):
        result = subprocess.run(['bash', str(SCRIPT), 'list', 'unknown'], capture_output=True)
        self.assertNotEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
