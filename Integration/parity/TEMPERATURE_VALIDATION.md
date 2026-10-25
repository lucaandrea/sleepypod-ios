# Temperature parity — first implementation slice

Verified on 2026-10-25 with Xcode 27.1 and a dedicated iPhone 18 Pro / iOS 27 simulator. These are local and simulated checks; no live Pod actuation was performed. This is not full web parity or a new TestFlight release.

Implemented:

- Persistent Cards/Stage, Degrees/Offset/Eight Sleep, independent degree units, zone visibility and camera auto-return preferences. Existing native Dial, Slider, Night & Dawn and Both sides remain in the app.
- Interactive thermal bed: side selection, horizontal rotation, pinch zoom and reset. Vertical one-finger gestures remain available to the parent scroll view. The default camera shows the complete bed.
- Saved weekly schedule timeline, explicit step transitions, read-only scrub preview and Back to live. Preview is distinguished from measured temperature and cannot send temperature commands.
- Core ownership/hold durations, resume, pump/priming/alarm notices, and serialized temperature/power writes. All off discards unsent temperature edits and follows an already-sent temperature request. Linking alone never writes hardware.
- Core-only status metadata survives sensor-stream merges; periodic REST refresh supplies fields absent from the stream. HTTP errors stay visible rather than being cleared by a successful status poll.

Evidence:

- `/tmp/SleepypodTemperatureVerified.xcresult`: 10 focused unit tests and 2 UI tests passed. Captures are in `previews/temperature/`.
- `/tmp/SleepypodTemperatureRegression.xcresult`: 35 passed and 5 live-Pod tests skipped across selected startup, temperature, Night & Dawn and thermal-rendering suites.
- `Integration/verify_presentation.py` passes: retained native controls, no retired app shell, presentation source or asset catalog in the compiled app.

Still open within Temperature:

- Reconcile Run Once, Autopilot/current-night ownership and historical occupancy with the timeline; it currently projects saved weekly schedules only.
- Audit every Night & Dawn edit/recovery path against the current web implementation.
- Full schedule/sleep history parity. Room/light/recent-sleep context is implemented below; next-alarm controls are recorded in `ALARM_VALIDATION.md`.
- Dedicated notice fixtures and UI/error checks, pinch/auto-return accessibility checks, iPad and large-text coverage.
- Physical controller verification. Simulator and request assertions do not establish real hardware behavior.

## Room and recent-sleep context (2026-10-25)

Native cards now appear beneath the existing controls in Dial, Night & Dawn, Slider, Both sides and Stage. They reuse Sleepypod's card, typography and color components. The room card includes ambient temperature, humidity, the selected side's mean measured bed temperature, light and reading age. Environment units remain °C/°F when the dial uses Offset or Eight Sleep. Missing, stale (>120 seconds), invalid-date and future readings are never labeled current.

The recent-sleep card uses the selected side's latest record and asks for vitals only within that record's actual interval. Open sessions omit an end timestamp, leaving the server to choose now. Room, light, sleep and vitals failures remain independent. The card labels historical records with their date, preserves Pod processing provenance and withholds HRV when definitions differ. Tapping it selects the matching side/night in the existing Sleep tab. Requests stop when the app becomes inactive, and late responses cannot overwrite a newly selected side.

Read-only API contracts were checked against `sleepypod-core/src/server/routers/environment.ts`, `biometrics.ts` and `src/biometrics/profiles/vital-summary-provenance.ts`. Tests use synthetic responses shaped from those contracts, not live Pod measurements. Eight transport/state tests pass in `/tmp/SleepypodHealthAndContextIPad.xcresult`. The two context interaction tests pass on standard iPhone (`/tmp/SleepypodTemperatureContext5.xcresult`), maximum Dynamic Type (`/tmp/SleepypodTemperatureContextLargest.xcresult`) and iPad (`/tmp/SleepypodHealthAndContextIPad.xcresult`). Rendered captures are in `previews/temperature-context/`. The final cards separate metric labels and units; the standard iPhone captures precede that small spacing change, while the largest-text and iPad captures include it. The affected sleep-data/temperature suites also passed 36 focused unit checks in `/tmp/SleepypodTemperatureContext3.xcresult`; its earlier UI failures were test locator/scrolling issues corrected in the succeeding runs.

The saved schedule projection also honors Core's explicit `offDayOffset`, including next-day windows whose end clock is later than the start clock. Calendar arithmetic preserves the Pod timezone across daylight saving transitions. Run Once, Autopilot, history and the other open items above remain pending.
