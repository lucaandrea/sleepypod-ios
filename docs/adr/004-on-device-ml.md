# ADR-004: On-Device Sleep Analysis with Core ML

## Status
Implemented: rules, bundled research forest, personal Core ML forest/logistic training, and a personal nearest-neighbour night baseline. Individual models remain unavailable until their data and validation gates pass.

## Context
The pod captures raw vitals (heart rate, HRV, breathing rate) from piezo sensors. Sleep stage classification (wake/light/deep/REM) and quality scoring add significant user value but require either server-side processing or on-device inference.

## Decision
Run sleep analysis on-device using Core ML:

### Phase 1 (Current): Rule-based classifier
- Thresholds from published research (Fonseca 2018, Walch 2019)
- HR < 85% avg → deep, HR > 95% + low HRV → REM, else → light
- No personal accuracy percentage has been established; no training data needed
- Quality score based on stage distribution targets (Walker 2017)

### Phase 2 (Implemented): Trained Core ML model
- Collect complete, reviewed paired nights via HealthKit (Apple Watch estimates are comparison labels, not clinical ground truth)
- Train logistic regression and random forest on the phone with Create ML from the user's own nights; design in docs/design/on-device-stage-training.md
- A bundled open-data challenger (PR #63) ships meanwhile for comparison only
- Eligibility to drive live stages: leave-one-night-out κ above both the rules and the challenger

### Phase 3 (Implemented): Personal night baseline
- Learn source-specific sleep timing/duration and optionally consistently covered Watch vitals.
- Fit earlier reviewed complete nights; calibrate scores on later reference nights.
- Compare only subsequent reviewed nights. Descriptive differences are not medical diagnoses or alerts.
- Runs in Swift with a protected learned artifact. No Core ML dependency is needed for this small model.

The former Status rows for “Sleep Stage CNN” and “Anomaly Detection” were hard-coded future labels. The new inventory reads real artifacts and validation. A CNN architecture is not a requirement for accurate personal classification; matched labels and held-out evaluation are. See [research and model contract](../NATIVE_MODEL_LEARNING.md).

## Consequences
- All inference runs on-device — no data leaves the phone
- Rule-based approach ships immediately without training data
- HealthKit integration requires user consent and Apple Watch ownership
- Model accuracy must be evaluated on calibrated, matched, independent recordings; calibration alone does not establish it
- These iPhone models do not own temperature, movement, vibration or notification commands
- See docs/health-vitals-science.md for formulas and references
