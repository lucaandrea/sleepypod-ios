# ADR-004: On-Device Sleep Analysis with Core ML

## Status
Accepted (rule-based), Proposed (trained model)

## Context
The pod captures raw vitals (heart rate, HRV, breathing rate) from piezo sensors. Sleep stage classification (wake/light/deep/REM) and quality scoring add significant user value but require either server-side processing or on-device inference.

## Decision
Run sleep analysis on-device using Core ML:

### Phase 1 (Current): Rule-based classifier
- Thresholds from published research (Fonseca 2018, Walch 2019)
- HR < 85% avg → deep, HR > 95% + low HRV → REM, else → light
- ~60-70% accuracy, no training data needed
- Quality score based on stage distribution targets (Walker 2017)

### Phase 2 (Planned): Trained Core ML model
- Collect labeled data via HealthKit (Apple Watch sleep stages as ground truth)
- Train logistic regression and random forest on the phone with Create ML from the user's own nights; design in docs/design/on-device-stage-training.md
- A bundled open-data challenger (PR #63) ships meanwhile for comparison only
- Eligibility to drive live stages: leave-one-night-out κ above both the rules and the challenger

### Phase 3 (Future): Additional models
- Anomaly detection (unusual HRV patterns)
- Presence detection (in-bed vs empty)
- Snoring/apnea hints from breathing irregularities

## Consequences
- All inference runs on-device — no data leaves the phone
- Rule-based approach ships immediately without training data
- HealthKit integration requires user consent and Apple Watch ownership
- Model accuracy depends on calibrated sensor data (blocked on core#172)
- See docs/health-vitals-science.md for formulas and references
