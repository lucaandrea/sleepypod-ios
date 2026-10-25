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
- Room humidity/light/air, last-night/next-alarm context and full history parity.
- Dedicated notice fixtures and UI/error checks, pinch/auto-return accessibility checks, iPad and large-text coverage.
- Physical controller verification. Simulator and request assertions do not establish real hardware behavior.
