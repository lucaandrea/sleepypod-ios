#!/bin/bash
set -euo pipefail

# Use the same signed bundle for every form while bounding each independent suite.
mode="${1:?Choose build, test or list}"
suite="${2:?Choose history, learning, removal, journal, patterns or all}"
case "$suite" in
  all)
    [[ "$mode" == build ]] || exit 2
    selectors=(SleepypodUITests/PersonalHistoryUITests SleepypodUITests/PersonalLearningUITests
      SleepypodUITests/PersonalLearningRemovalUITests SleepypodUITests/PersonalJournalUITests
      SleepypodUITests/PersonalJournalPatternsUITests)
    ;;
  history) selectors=(SleepypodUITests/PersonalHistoryUITests) ;;
  learning) selectors=(SleepypodUITests/PersonalLearningUITests) ;;
  removal) selectors=(SleepypodUITests/PersonalLearningRemovalUITests) ;;
  journal) selectors=(SleepypodUITests/PersonalJournalUITests) ;;
  patterns) selectors=(SleepypodUITests/PersonalJournalPatternsUITests) ;;
  *) printf 'Unknown suite: %s\n' "$suite" >&2; exit 2 ;;
esac
if [[ "$mode" == list ]]; then
  printf '%s\n' "${selectors[@]}"
  exit 0
fi
arguments=()
for selector in "${selectors[@]}"; do arguments+=("-only-testing:$selector"); done
case "$mode" in
  build)
    bash "$(dirname "$0")/build-simulator-ui.sh" -project Sleepypod.xcodeproj -scheme Sleepypod \
      -derivedDataPath "${RUNNER_TEMP:?}/RecordingsBuild" \
      "${arguments[@]}" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
    ;;
  test)
    [[ -f "${RECORDINGS_TEST_RUN:?}" ]] || { printf 'Shared UI test bundle is missing.\n' >&2; exit 2; }
    xcodebuild test-without-building -xctestrun "$RECORDINGS_TEST_RUN" \
      -destination "platform=iOS Simulator,id=${RECORDINGS_SIM_ID:?}" \
      "${arguments[@]}" -resultBundlePath "${RUNNER_TEMP:?}/Recordings-${suite}.xcresult" \
      -collect-test-diagnostics never -parallel-testing-enabled NO \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
    ;;
  *) printf 'Unknown mode: %s\n' "$mode" >&2; exit 2 ;;
esac
