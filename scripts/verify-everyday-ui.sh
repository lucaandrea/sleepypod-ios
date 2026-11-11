#!/bin/bash
set -euo pipefail

# Keep the same phone/tablet scenarios in bounded groups on the hosted runner.
mode="${1:?Choose build, test or list}"
suite="${2:?Choose recording, guidance or wake}"
case "$suite" in
  recording)
    selectors=(SleepypodUITests/RecordingReadinessUITests SleepypodUITests/WatchRecordingUITests)
    ;;
  guidance)
    selectors=(SleepypodUITests/LearningJourneyUITests SleepypodUITests/TonightUITests SleepypodUITests/BedCareUITests)
    ;;
  wake)
    selectors=(
      SleepypodUITests/AlarmParityUITests/testAlarmCreateSmartWakeSnoozePauseAndDelete
      SleepypodUITests/AlarmParityUITests/testAlarmEditorAtCurrentDeviceTextSize
      SleepypodUITests/AlarmParityUITests/testAlarmEditorAtAccessibilityTextSize
      SleepypodUITests/NextAlarmUITests
    )
    ;;
  *) printf 'Unknown suite: %s\n' "$suite" >&2; exit 2 ;;
esac
if [[ "$mode" == list ]]; then
  printf '%s\n' "${selectors[@]}"
  exit 0
fi
case "$mode" in
  build) action=build-for-testing; extras=() ;;
  test)
    action=test-without-building
    extras=(-resultBundlePath "${RUNNER_TEMP:?}/Recording.xcresult" -collect-test-diagnostics never -parallel-testing-enabled NO)
    ;;
  *) printf 'Unknown mode: %s\n' "$mode" >&2; exit 2 ;;
esac
arguments=()
for selector in "${selectors[@]}"; do arguments+=("-only-testing:$selector"); done
xcodebuild "$action" -project Sleepypod.xcodeproj -scheme Sleepypod \
  -destination "platform=iOS Simulator,id=${RECORDING_SIM_ID:?}" \
  -derivedDataPath "${RUNNER_TEMP:?}/RecordingBuild" \
  "${arguments[@]}" "${extras[@]}" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
