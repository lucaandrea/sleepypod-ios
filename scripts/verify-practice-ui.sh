#!/bin/bash
set -euo pipefail

# Preserve every practice scenario while bounding each hosted execution group.
mode="${1:?Choose build, test or list}"
suite="${2:?Choose journey, accessibility, invitations or all}"
case "$suite" in
  all)
    [[ "$mode" == build ]] || exit 2
    selectors=(SleepypodUITests/ControlPracticeUITests SleepypodUITests/HouseholdPreparationUITests)
    ;;
  journey)
    selectors=(
      SleepypodUITests/ControlPracticeUITests/testPersonalJourneyRequestsReviewsStopsAndReturns
      SleepypodUITests/ControlPracticeUITests/testOwnerEntryAndSkippedLessonDoNotBecomeCompletion
      SleepypodUITests/ControlPracticeUITests/testOwnerDarkSheetKeepsInstructionsReadable
    )
    ;;
  accessibility)
    selectors=(
      SleepypodUITests/ControlPracticeUITests/testLargestTextDarkKeepsActionsAndLandscapeReachable
      SleepypodUITests/HouseholdPreparationUITests/testUnassignedMemberSeesOnlyPrivatePreparationAndReachableDraftFields
    )
    ;;
  invitations)
    selectors=(
      SleepypodUITests/ControlPracticeUITests/testInvitationReviewRejectsBadLinkAndClearsWhenBackgrounded
      SleepypodUITests/ControlPracticeUITests/testExpiredInvitationReportsRecoveryWithoutOpeningOwnerControls
    )
    ;;
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
    xcodebuild build-for-testing -project Sleepypod.xcodeproj -scheme Sleepypod \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath "${RUNNER_TEMP:?}/PracticeBuild" \
      "${arguments[@]}" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
    ;;
  test)
    [[ -f "${PRACTICE_TEST_RUN:?}" ]] || { printf 'Shared UI test bundle is missing.\n' >&2; exit 2; }
    xcodebuild test-without-building -xctestrun "$PRACTICE_TEST_RUN" \
      -destination "platform=iOS Simulator,id=${PRACTICE_SIM_ID:?}" \
      "${arguments[@]}" -resultBundlePath "${RUNNER_TEMP:?}/Practice-${suite}.xcresult" \
      -collect-test-diagnostics never -parallel-testing-enabled NO \
      CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
    ;;
  *) printf 'Unknown mode: %s\n' "$mode" >&2; exit 2 ;;
esac
