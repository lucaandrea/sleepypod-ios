# Native storage workflow

Status: implemented and validated on iPhone, iPad and maximum Dynamic Type; local validation complete; CI pending. No real Pod cleanup or vibration command has been sent.

Compared against Core `System/StorageTab.tsx`, `system.getStorage`, `system.freeStorage` `podStorage.ts`, and the `scripts/bin/sp-storage-cleanup` allowlist.

The native screen shows /persistent capacity, six usage categories, the pruner's target, raw-history dates/count, and eligible leftovers. Old database backups are excluded by default. Review lists the current candidates and requires an explicit destructive confirmation. Core re-scans eligibility at execution, so the final amount may differ from the displayed estimate; the native confirmation states this. The running install, live databases, raw archive, swap and HomeKit pairing remain outside Core's cleanup scope.

Failed, unavailable, expired or changed reports cannot submit cleanup. Unknown cleanup outcomes require a readback before another attempt. Successful results trigger a fresh report and preserve the server's reported removed count and freed bytes. All demo cleanup is confined to the in-memory fixture.

The accompanying hardware change replaces the obsolete intensity/pattern test UI and corrects unavailable hardware/Wi-Fi status reporting. Dashboard firewall/uptime/maintenance facts remain in the next System audit portion.

## Validation

- `SystemMaintenance-phone2.xcresult`: all 16 focused tests passed (six storage, six vibration, four Core status transport checks).
- `SystemMaintenance-ipad-fullscreen.xcresult`: both interaction flows passed in iPad light appearance. The Status entry now uses full-screen navigation, matching the app's other detailed screens. This resolves inaccessible content in the compact sheet.
- `SystemMaintenance-accessibility.xcresult`: vibration and both Health/Thermal regression flows passed at maximum accessibility text size. Storage exposed a switch/label hit-target problem; that failed attempt is retained locally.
- `SystemStorage-accessibility-toggle.xcresult`: the corrected Storage flow passed. At accessibility sizes the backup switch is below its label, with an independent accessible label and hit target. Normal layouts retain the standard inline toggle.
- SwiftLint strict and the compiled-source presentation guard passed. The app still excludes retired Free Sleep presentation from its build.
- Screenshots in `previews/system-maintenance/` show demo data and actions only. Physical Pod cleanup, vibration and firmware interpretation remain unverified.

- `SystemMaintenance-phone-final.xcresult`: the final Storage flow passed at normal text size. Its hardware test exposed a missed simulator menu tap; no app-side action changed the selected side.
- `HardwareVibration-phone-menu.xcresult`: the final hardware flow passed after the test tapped the menu option's center, waited for dismissal, and verified the Play target before proceeding. The production vibration code is unchanged by this test correction.

- `SystemStorage-ipad-final.xcresult`: final iPad Storage flow passed after the accessibility/copy adjustment. Twenty-one final screenshots cover seven states on each of iPhone dark, iPad light and maximum-text iPhone.
