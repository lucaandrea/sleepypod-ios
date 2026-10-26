# Native hardware vibration test

Status: implemented and validated on iPhone, iPad and maximum Dynamic Type; local validation complete; CI pending. No real Pod cleanup or vibration command has been sent.

Compared with Core `HapticsTestCard.tsx`, `vibrationPatterns.ts` and the `device.setAlarm`/`device.clearAlarm` contracts. Quick (10s), Standard (30s), Long (60s) and Custom (1–60s) use intensity 100 and pattern rise. Preset names select durations; they do not claim to produce different motor strengths. Firmware interpretation still requires a physical test.

Tests target a single chosen side. The app presents the requested duration as an estimate because the controller's vibration flag is inferred from command duration. A response must explicitly acknowledge success before the test timer starts. Unknown play results preserve the original side and keep Stop available; another play remains disabled until Stop is acknowledged. Stop never clears the opposite side implicitly. No expiry timer or screen dismissal sends a new hardware command. The bounded requested duration remains authoritative to the firmware.

Core REST transport is separate from the explicitly labeled in-memory demo. The legacy API adapter retains support for the older backend without reusing its obsolete preset UI.

The existing Core status adapter no longer marks absent DAC/hardware responses healthy or substitutes zero for unavailable latency/signal. Monitor states running, polling and connected count as healthy; missing or unknown states do not. Four additional transport tests cover missing, malformed, disconnected and positive responses.

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
