#!/bin/bash
set -euo pipefail

# Keep the same phone/tablet scenarios in bounded groups on the hosted runner.
mode="${1:?Choose build, test or list}"
suite="${2:?Choose reading, temperature, waking, an individual suite or all}"
case "$suite" in
  reading) componentSuites=(recording guidance morning) ;;
  temperature) componentSuites=(cooling night response) ;;
  waking) componentSuites=(wake connection later-wake) ;;
  *) componentSuites=("$suite") ;;
esac
selectors=()
for componentSuite in "${componentSuites[@]}"; do
  case "$componentSuite" in
    all)
      [[ "$mode" == build ]] || { printf 'The all selector is only for building the shared bundle.\n' >&2; exit 2; }
      selectors+=(SleepypodUITests)
      ;;
    recording)
      selectors+=(SleepypodUITests/RecordingReadinessUITests SleepypodUITests/WatchRecordingUITests)
      ;;
    guidance)
      selectors+=(SleepypodUITests/LearningJourneyUITests SleepypodUITests/TonightUITests SleepypodUITests/BedCareUITests SleepypodUITests/BedWidgetUITests)
      ;;
    morning)
      selectors+=(SleepypodUITests/MorningBriefUITests)
      ;;
    cooling)
      selectors+=(SleepypodUITests/TemporaryCoolingUITests)
      ;;
    response)
      selectors+=(SleepypodUITests/TargetResponseUITests SleepypodUITests/PredictiveTargetUITests)
      ;;
    connection)
      selectors+=(SleepypodUITests/OwnerConnectionEnrollmentUITests SleepypodUITests/OwnerRouteSettingsUITests)
      ;;
    night)
      selectors+=(SleepypodUITests/NightExplanationUITests)
      ;;
    later-wake)
      selectors+=(SleepypodUITests/LaterWakeUITests)
      ;;
    wake)
      selectors+=(
        SleepypodUITests/AlarmParityUITests/testAlarmCreateSmartWakeSnoozePauseAndDelete
        SleepypodUITests/AlarmParityUITests/testAlarmEditorAtCurrentDeviceTextSize
        SleepypodUITests/AlarmParityUITests/testAlarmEditorAtAccessibilityTextSize
        SleepypodUITests/NextAlarmUITests
      )
      ;;
    *) printf 'Unknown suite: %s\n' "$componentSuite" >&2; exit 2 ;;
  esac
done
if [[ "$mode" == list ]]; then
  printf '%s\n' "${selectors[@]}"
  exit 0
fi
# macOS ships Bash 3.2, where an empty array expansion fails under nounset.
extras=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)
case "$mode" in
  build) action=build-for-testing ;;
  test)
    action=test-without-building
    extras+=(-resultBundlePath "${RUNNER_TEMP:?}/Recording.xcresult" -collect-test-diagnostics on-failure -parallel-testing-enabled NO)
    ;;
  *) printf 'Unknown mode: %s\n' "$mode" >&2; exit 2 ;;
esac
arguments=()
for selector in "${selectors[@]}"; do arguments+=("-only-testing:$selector"); done
# A workflow-local, same-revision artifact avoids recompiling the app for every screen group.
if [[ "$mode" == test && -n "${EVERYDAY_TEST_RUN:-}" ]]; then
  [[ -f "$EVERYDAY_TEST_RUN" ]] || { printf 'Shared UI test bundle is missing.\n' >&2; exit 2; }
  xcodebuild "$action" -xctestrun "$EVERYDAY_TEST_RUN" \
    -destination "platform=iOS Simulator,id=${RECORDING_SIM_ID:?}" \
    "${arguments[@]}" "${extras[@]}"
  exit
fi
xcodebuild "$action" -project Sleepypod.xcodeproj -scheme Sleepypod \
  -destination "platform=iOS Simulator,id=${RECORDING_SIM_ID:?}" \
  -derivedDataPath "${RUNNER_TEMP:?}/RecordingBuild" \
  "${arguments[@]}" "${extras[@]}"
