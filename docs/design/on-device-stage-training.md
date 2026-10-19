# On-device sleep stage training with the Apple Watch as the label

Status: proposed. Implements ADR-004 Phase 2.

## Why

The pod's rules agree with the Apple Watch at chance (κ 0.02 on the night of Oct 18, κ ≈ 0.01 over nine nights). The bundled challenger (`SleepStageChallenger.mlmodel`, random forest after ojwalch/sleep_classifiers, PhysioNet Walch 2019) reaches κ 0.35 on its own sleep-lab data but only κ 0.12–0.14 on the pod, because it was trained on wrist PPG and accelerometer and is applied to piezo heart rate and bed movement. The domain gap costs most of the model.

Everything needed to close that gap is already on the phone: pod vitals and movement over the API, Watch stages in HealthKit, the night matching from PR #62, and the scoring from PR #63. The missing piece is training on the user's own nights, on the device, with the Watch as the label.

## Goal

Train two personal classifiers on the phone from the user's Watch-labelled nights, score them leave-one-night-out against the Watch beside the rules and the bundled challenger, and let the better one drive the stages the app shows and writes to Health once it beats both.

Non-goals: medical claims, cloud training, any data leaving the phone, replacing the pod's own server-side rules in sleepypod-core.

## The two models

Both are the open-source pair from ojwalch/sleep_classifiers, which the challenger card already reports as `logistic` and `forest`:

| Model | Create ML class | Why |
|---|---|---|
| Logistic regression | `MLLogisticRegressionClassifier` | Inspectable weights, hard to overfit on few nights, the paper's baseline |
| Random forest | `MLRandomForestClassifier` (maxDepth 6, 100 trees) | The paper's best; handles the non-linear HR/HRV interactions |

Both compile for iOS 17+ and the app targets iOS 26 (verified with a probe build). Create ML does not exist on the simulator, so training code sits behind `#if canImport(CreateML)` and tests use the `SleepStageClassifying` test double from PR #63. Core ML inference works everywhere.

Training a tree on tabular data of a few thousand rows takes seconds on an A-series chip; it runs in a detached task off the main actor with the app in the foreground.

## Labels

- Source: Watch `sleepAnalysis` samples only, using the PR #63 filter (source `com.apple.health…`, Watch hardware, never this app). Core/Deep/REM/Awake map to light/deep/rem/wake; InBed and Unspecified are dropped.
- Night matching: `WatchComparison.sessions` and `session(for:)` from PR #62, so the Watch's night is matched to the pod record even when the two don't overlap.
- Pod record per day: the day's longest sleep record, as the Night page selects it.
- Label per epoch: the single Watch stage covering the epoch midpoint. Epochs covered by zero or two Watch stages are unlabelled and excluded from training and scoring.
- Minimum data: 5 labelled nights and 300 labelled epochs before training is offered. Nights shorter than 2 h of Watch sleep are skipped.

Watch stages are themselves estimates (κ ≈ 0.6 against polysomnography in Walch's data). The personal model can at best learn to agree with the Watch; the plan treats the Watch as the reference, not the truth, and says so in the UI.

## Features

Two feature contracts, trained and scored separately so each result is attributable:

**Contract A, "challenger parity":** exactly the bundled model's inputs, from `StageChallenger.features`: 5-minute epochs from bed entry, per-night z-scores of epoch mean HR, epoch HR std, ln(1 + summed motion), and night fraction. Training the same two models on the same features from pod signals isolates the domain gap. If A beats the bundled challenger, the gap was the data, not the method.

**Contract B, "pod native":** adds what the pod has and a wrist doesn't, per ADR-004 and the core calibration plan:

- HRV: epoch mean RMSSD over the night median, and its 15-minute rolling mean
- HR: 15-minute rolling std over the night std
- Breathing rate: 15-minute std (only once sleepypod-core stops returning the hardcoded 12 br/min, core#172; until then the column is constant and the trees ignore it)
- Movement: 15-minute summed motion, log-scaled
- Night fraction and minutes since bed entry

Feature code is one pure, tested type shared by training, inference and the export, so the contract cannot drift between them. Each trained model's card records which contract it used.

## Training and evaluation

1. Build the dataset: for the last 90 days, fetch records, vitals and movement per night through the existing chunked `HealthSyncService.sleepRecords` path, filter outliers with `SleepAnalyzer.filterOutliers`, compute features, attach Watch labels.
2. Leave-one-night-out: for each labelled night, train on the others and score the held-out night per 5-minute epoch with `StageScore` (κ, accuracy, confusion). Report the pooled κ, the per-night κ, and the same for the rules and the bundled challenger on the same epochs.
3. Class weights: wake and REM are rare in bed data; weight classes by inverse frequency so the forest does not collapse to "light".
4. Final fit: retrain on all nights, write `.mlmodel`, compile with `MLModel.compileModel`, store under Application Support/StageModel/ with a card in the challenger's card schema (version, feature contract, test vectors sampled from the training rows, metrics with `lono` in place of `loso`). Loading reuses `StageChallenger.load`, which already refuses a model that fails its own test vectors.
5. Post-processing: the analyzer's temporal smoothing and transition constraints apply to model output exactly as to the rules, so the hypnogram stays physiologically plausible.

Success criteria for a model to become eligible as the live classifier: pooled leave-one-night-out κ at least 0.05 above both the rules and the bundled challenger, over at least 5 nights. Until then it stays a comparison lane.

## Integration

- **Stage models screen** gains two lanes, "Personal logistic" and "Personal forest", each with κ and accuracy, next to Watch, Pod (rules) and Challenger. A Train button with progress, last-trained date, nights and epochs used, and Delete.
- **Live classifier setting:** Settings → On-device analysis → "Sleep stages from": Rules (default), Personal logistic, Personal forest. Only eligible models can be chosen. `SleepAnalyzer.analyze` takes an optional `SleepStageClassifying`; when set and calibration quality ≥ 0.3 it classifies from features instead of rules, then applies the same post-processing.
- **Health sync:** `HealthSyncService.receiptSignature` includes the active model's card version, so switching models rewrites synced nights through the existing rewrite path from PR #60. The Night page, week view and sync all read the one setting.
- **Retraining:** offered when at least 3 new labelled nights have accrued since the last fit. Never automatic in the background; training runs only on user action, in the foreground.
- **Export:** the de-identified `stage-challenger-v1.json` share grows two per-night entries for the personal models, still without timestamps or IDs, so off-device analysis can compare across users.

## Off-device parity in the Mac analysis container

The same two models should be trained off the pod on the same features so on-device results can be cross-checked:

- Dataset: the per-minute pairing of Watch stages and pod vitals from `sleepypod-core/docs/research/sleep-stage-calibration` (pod DB snapshot plus Health export, or `--from-db` after `import-watch-health.py`).
- Models: scikit-learn `LogisticRegression` and `RandomForestClassifier` with the ojwalch/sleep_classifiers settings, over Contract A and Contract B features computed by a port of the Swift feature code. Leave-one-night-out, κ and confusion per night, same as on device.
- Parity check: convert each with coremltools to `.mlmodel`, generate card test vectors, and confirm the iOS `CoreMLStageClassifier` reproduces the container's predictions on those vectors. A mismatch means the feature contract drifted.
- Output: a card JSON in the challenger schema per model, so a container-trained model could also be bundled as a second challenger if it beats the personal one.

The container itself was not found in the sleepypod repositories on this Mac; its Dockerfile and the dataset script location need to be added to the research README when this lands.

## Work breakdown

1. `StageFeatures.swift`: Contract A and B feature computation, shared, pure, with tests against hand-computed rows. Reuse `StageChallenger.features` for A.
2. `StageDataset.swift`: nights, labels, leave-one-night-out splits, class weights. Tests with the Watch-comparison fixtures.
3. `StageTrainer.swift`: Create ML training behind `#if canImport(CreateML)`, card generation, compile and store. Device-only; a simulator build gets a stub that reports "needs an iPhone".
4. `StageModelStore.swift`: load personal models through `StageChallenger.load`, the live-classifier setting, eligibility.
5. `SleepAnalyzer` classifier injection; `HealthSyncService` signature; `SleepScreen` and sync call sites.
6. Stage models screen lanes, Train/Delete, Settings row. Demo mode shows a synthesized personal model from the demo Watch.
7. Research README additions for the container run and parity check, plus a scikit-learn script.

Each of 1–4 is its own PR with tests; 5 and 6 can ship together once 4 is in.

## Risks

- Few nights: nine today. Logistic is the safer first result; the forest needs 15–20 nights before its κ stabilises. The UI shows per-night κ so a lucky pooled number is visible as such.
- Label noise: the Watch is the reference, not the truth. The eligibility bar is relative to the rules and the challenger, not absolute.
- Class imbalance and short bed sessions: skipped below 2 h of Watch sleep; weighted classes.
- Battery and time: seconds for these sizes, foreground only, never on background refresh.
- Privacy: all training and inference on the phone; the export stays de-identified; Health times and source names are logged private.
- Breathing rate is constant until core#172; the plan does not depend on it.
