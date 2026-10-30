#!/usr/bin/env python3
"""Verify the app compiles Sleepypod presentation and not the retired app shell."""
from pathlib import Path
import argparse
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--derived-data', type=Path, default=Path('/tmp/SleepypodUnifiedDerived'))
options = parser.parse_args()
root = Path(__file__).resolve().parent.parent
# The owner explicitly requested web parity after build 7. Keep the original native
# Cards controls alongside Stage, while rejecting all retired Free Sleep presentation.
temperature = (root / 'Sleepypod/Views/Temp/TempScreen.swift').read_text()
for component in ['TemperatureDialView()', 'TempSliderView(', 'TempStepperView(', 'BothSidesView(', 'TemperatureStageScreen()']:
    assert component in temperature, f'Native temperature layout removed: {component}'
app = (root / 'Sleepypod/SleepypodApp.swift').read_text()
for retired in ['RootView()', 'TonightScreen(', 'HomeScreen(']:
    assert re.search(r'\b' + re.escape(retired), app) is None, f'Retired navigation restored: {retired}'
file_lists = list(options.derived_data.glob('Build/Intermediates.noindex/Sleepypod.build/Debug-iphonesimulator/FreeSleepKit.build/Objects-normal/*/FreeSleepKit.SwiftFileList'))
assert file_lists, 'Build the simulator app before checking compiled sources'
for file in file_lists:
    sources = file.read_text()
    for retired in ['/FreeSleepKit/Features/', '/FreeSleepKit/Design/', '/FreeSleepKit/App/RootView.swift', '/FreeSleepKit/App/FreeSleepApp.swift']:
        assert retired not in sources, f'Retired UI still compiled: {retired}'
    assert '/SleepypodFeatures/PodFeatureScreen.swift' in sources
    assert '/SleepypodUI/SleepypodComponents.swift' in sources
project = (root / 'project.yml').read_text()
assert 'FreeSleepKit/Resources/Assets.xcassets' not in project, 'Retired colors still bundled'
print('Verified: original native Cards controls plus Stage; Sleepypod shared components; no retired app shell, UI components or asset catalog in the build.')
