# Personal App Intents and command history

Source reconciliation: 26 October 2026, owner Core `ccafceb96fbba31b5a38153958962fc7a88a968c`, `docs/CONTROL_RECEIPTS.md`, `docs/CLIENT_CAPABILITIES.md`, `docs/NEXT_ALARMS.md` and the personal comfort mode-only route. Release remains 0.2.0 (7); Health and source-qualified personal reports are separate remaining work.

## Implemented behavior

- The app registers `NativePodActionBridge` during initialization, before any view task. Core App Intents use native services for temperature reads/writes, power, whole-bed head/feet/presets/Stop, vibration dismissal, Away, priming, next-alarm read/skip/time/restore and Off/Preview comfort. The original server transport remains available for its existing backend.
- Strict input and capability checks precede writes. No rounding of fractional temperature, invalid side substitution, null-temperature fallback or unqualified Active comfort setting is allowed. Read values require fresh device capability data. Core presets are Flat 0/0, Sleep 1/5, Relax 30/15 and Read 40/0, at explicit 50% speed.
- Immediate hardware controls retain UUID, payload and the original 30-second deadline in a protected, backup-excluded, owner-scoped ledger before one POST. Recovery only reads the same ID; requests and expiry are never renewed. A bounded three-read observation handles `executing`; manual refresh is also read-only.
- Unknown/missing outcomes survive app restart and block later related commands until explicit review. Stop, power-off and vibration dismissal remain available. Local review does not turn an unknown outcome into success. A controller acknowledgment explicitly leaves physical effects unverified.
- Native Settings → Command history shows all six Core receipt states, request identity, original time, refresh and review. Empty Demo stays empty; UI fixtures are labeled synthetic. Connection changes discard late UI publication while retaining an already-dispatched receipt in its original owner's ledger.
- Alarm actions read the exact next occurrence and preserve its revision preconditions, including skip/following occurrence and timezone. Lost writes are not retried. Comfort actions patch mode only, preserving newer server-side limits. Away/priming have explicit targeted routes and do not claim durable hardware receipts.

## Validation

- Source-generated fixtures retain real Core receipt output and all six states. Exact URL, body, version, UUID, deadline, replay policy and physical-verification fields are checked.
- 18 native control/REST/session checks pass (`NativeActions-v5`): protected persistence before dispatch, lost replies, restart recovery, blocked related commands, Stop/off escape actions, invalid replies, bounded reads, demo/cancellation/owner changes, alarm CAS and atomic comfort preservation.
- Eight original server Shortcut checks pass (`NativeActions-v5`); four Core App Intent checks pass (`NativeActions-ipad-v9`). The latter includes Apple's actual intent execution API with a deliberately invalid temperature, proving app-initialization dependency registration without sending a hardware command. This is not a Siri or physical-device acceptance claim.
- Both phone flows pass (`NativeActions-v5` offline/empty and `NativeActions-phone-v6` states/review/readback); both iPad flows pass (`NativeActions-ipad-v9`). Eleven captures per device are retained in `previews/personal-actions/`. Both maximum Dynamic Type flows pass (`NativeActions-AX-v10`); the shortened review confirmation also passes (`NativeActions-AX-v12`) and its complete message/button fit in the rendered capture. Eleven captures per device/text size are retained. The friendly offline-error phone recapture passes (`NativeActions-phone-offline-v11`); the iPad copy refresh passes (`NativeActions-ipad-offline-v13`). All 33 retained captures were reviewed.
- Fifteen existing Health lifecycle checks pass (`NativeActions-ipad-v9`). A preexisting CI fixture clock drift was corrected by freezing its timestamp per instance; production Health behavior was unchanged by that fix.
- Local strict lint, the native presentation guard and whitespace checks pass. GitHub CI and merge remain pending.

No live actuator request, new Health-store write, external model call or TestFlight upload was performed for these checks. Demo fixtures never qualify physical acceptance.
