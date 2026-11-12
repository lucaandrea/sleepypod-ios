#!/bin/bash
set -euo pipefail

# Keep every attended/recovery scenario, with one bounded test group per runner.
mode="${1:?Choose build, test or list}"
suite="${2:?Choose activation, recovery, status, review or all}"
case "$suite" in
  all)
    [[ "$mode" == build ]] || { printf 'Use all only for the shared build.\n' >&2; exit 2; }
    selectors=(SleepypodUITests)
    ;;
  activation)
    selectors=(
      SleepypodUITests/ArrangementMaintenanceUITests/testApprovedReviewOpensSeparateActivationAndWithdrawsOldEditors
      SleepypodUITests/ArrangementMaintenanceUITests/testLaterApprovedReviewCanStartAfterCompletedCancellation
      SleepypodUITests/ArrangementMaintenanceUITests/testUncertainActivationAndAbsentReceiptOnlyOfferReadRecovery
    )
    ;;
  recovery)
    selectors=(
      SleepypodUITests/ArrangementMaintenanceUITests/testKeepingSoloRequiresDigestReviewBeforeConfirmations
      SleepypodUITests/ArrangementMaintenanceUITests/testRecoveryLargeTextExplicitlyReloadsAssignedAccount
      SleepypodUITests/ArrangementMaintenanceUITests/testRestartRequiresAttendedConfirmationAndSavedReceiptPreventsRepeat
    )
    ;;
  status)
    selectors=(
      SleepypodUITests/ArrangementMaintenanceUITests/testExistingRestartReceiptCannotOfferAnotherRestart
      SleepypodUITests/ArrangementMaintenanceUITests/testUnavailableStatusRetainsRetryAndSignOutWithoutOrdinaryEditors
      SleepypodUITests/HouseholdPreparationUITests
      SleepypodUITests/PersonalRouteUITests
    )
    ;;
  review) selectors=(SleepypodUITests/ArrangementReviewUITests) ;;
  *) printf 'Unknown suite: %s\n' "$suite" >&2; exit 2 ;;
esac
if [[ "$mode" == list ]]; then
  printf '%s\n' "${selectors[@]}"
  exit 0
fi
extras=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-)
case "$mode" in
  build) action=build-for-testing ;;
  test)
    action=test-without-building
    extras+=(-resultBundlePath "${RUNNER_TEMP:?}/Household.xcresult" -collect-test-diagnostics never -parallel-testing-enabled NO)
    ;;
  *) printf 'Unknown mode: %s\n' "$mode" >&2; exit 2 ;;
esac
command=(xcodebuild)
if [[ "$mode" == test ]]; then command=(python3 "$(dirname "$0")/run-simulator-ui.py"); fi
arguments=()
for selector in "${selectors[@]}"; do arguments+=("-only-testing:$selector"); done
if [[ "$mode" == test && -n "${HOUSEHOLD_TEST_RUN:-}" ]]; then
  [[ -f "$HOUSEHOLD_TEST_RUN" ]] || { printf 'Shared UI test bundle is missing.\n' >&2; exit 2; }
  "${command[@]}" "$action" -xctestrun "$HOUSEHOLD_TEST_RUN" \
    -destination "platform=iOS Simulator,id=${MAINTENANCE_SIM_ID:?}" \
    "${arguments[@]}" "${extras[@]}"
  exit
fi
"${command[@]}" "$action" -project Sleepypod.xcodeproj -scheme Sleepypod \
  -destination "platform=iOS Simulator,id=${MAINTENANCE_SIM_ID:?}" \
  -derivedDataPath "${RUNNER_TEMP:?}/MaintenanceBuild" \
  "${arguments[@]}" "${extras[@]}"
