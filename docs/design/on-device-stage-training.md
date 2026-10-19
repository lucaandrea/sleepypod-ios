# On-device sleep stage training with the Apple Watch as the label

Status: proposed. Implements ADR-004 Phase 2.

## Why

The pod's rules agree with the Apple Watch at chance (κ 0.02 on the night of Oct 18, κ ≈ 0.01 over nine nights). The bundled challenger (`SleepStageChallenger.mlmodel`, random forest after ojwalch/sleep_classifiers, PhysioNet Walch 2019) reaches κ 0.35 on its own sleep-lab data but only κ 0.12 on the pod (κ 0.11 for the card's logistic variant), because it was trained on wrist PPG and accelerometer and is applied to piezo heart rate and bed movement. The domain gap costs most of the model.

Everything needed to close that gap is already on the phone: pod vitals and movement over the API, Watch stages in HealthKit, the night matching from PR #62, and the scoring from PR #63. The missing piece is training on the user's own nights, on the device, with the Watch as the label.

## Goal

Train two personal classifiers on the phone from the user's Watch-labelled nights, score them leave-one-night-out against the Watch beside the rules and the bundled challenger, and let the better one drive the stages the app shows and writes to Health once it beats both.

Non-goals: medical claims, cloud training, any data leaving the phone, replacing the pod's own server-side rules in sleepypod-core.

## The two models

Both are the open-source pair from ojwalch/sleep_classifiers, which the challenger card already reports as `logistic` and `forest`:

| Model | Create ML class | Why |
|---|---|---|
| Logistic regression | `MLLogisticRegressionClassifier` | Inspectable weights, hard to overfit on few nights, the paper's baseline |
| Random forest | `MLRandomForestClassifier` (200 trees, maxDepth 4) | The paper's best; handles the non-linear HR/HRV interactions |

Hyperparameters are pinned to sleepypod-core's research script (`docs/research/sleep-stage-calibration/feat2.py`: 200 trees, depth 4) so the container run and the device fit are the same model. These are not the ojwalch defaults, and the bundled challenger was fit with 100 trees; the card records the settings used.

Both compile for iOS 17+ and the app targets iOS 26 (verified with a probe build). Create ML does not exist on the simulator, so training code sits behind `#if canImport(CreateML)` and tests use the `SleepStageClassifying` test double from PR #63. Core ML inference works everywhere.

Neither Create ML classifier takes class weights (none in the iOS SDK's CreateML interface), so class balance is handled by oversampling rows instead; see Training step 3.

Measured on an iPhone 15 Pro with 11 nights (756 labelled epochs, about 1,800 rows after oversampling): a Create ML random-forest fit takes about two minutes on one core, not seconds. Running folds concurrently made it worse (four at a time never finished within an hour), so folds run one after another, the whole run is reported with a progress bar and a "keep the app open" note, the screen is kept awake, and a forest run on eleven nights takes about 25 minutes; training runs in a detached task off the main actor with the app in the foreground.

## Labels

- Source: Watch `sleepAnalysis` samples only, using the PR #63 filter (source `com.apple.health…`, Watch hardware, never this app). Core/Deep/REM/Awake map to light/deep/rem/wake; InBed and Unspecified are dropped.
- Night matching: `WatchComparison.sessions` and `session(for:)` from PR #62, so the Watch's night is matched to the pod record even when the two don't overlap.
- Pod record per day: the day's longest sleep record, as the Night page selects it.
- Label per epoch: the first Watch block containing the epoch midpoint, the same rule `StageScore.score` uses, so training labels and scoring labels can never disagree. Epochs no block covers are unlabelled and excluded from both.
- Minimum data: 5 labelled nights and 300 labelled epochs before training is offered. Nights shorter than 2 h of Watch sleep are skipped.

Watch stages are themselves estimates (κ ≈ 0.6 against polysomnography in Walch's data). The personal model can at best learn to agree with the Watch; the plan treats the Watch as the reference, not the truth, and says so in the UI.

## Features

Two feature contracts, trained and scored separately so each result is attributable:

**Contract A, "challenger parity":** exactly the bundled model's inputs, from `StageChallenger.features`: 5-minute epochs from bed entry, per-night z-scores of epoch mean HR, epoch HR std, ln(1 + summed motion), and night fraction. Training the same two models on the same features from pod signals isolates the domain gap. If A beats the bundled challenger, the gap was the data, not the method.

**Contract B, "pod native":** adds what the pod has and a wrist doesn't, per ADR-004 and the core calibration plan:

- HRV: epoch mean RMSSD over the night median, and its 15-minute rolling mean
- HR: 15-minute rolling std over the night std
- Breathing rate: 15-minute std. core#172 (hardcoded 12 br/min) was resolved in core v1.1.0; before Contract B ships, confirm the pod's breathing rate varies across a night. If it is still constant the column stays in the contract and the trees ignore it.
- Movement: 15-minute summed motion, log-scaled
- Night fraction and minutes since bed entry

Feature code is one pure, tested type shared by training, inference and the export, so the contract cannot drift between them. Each trained model's card records which contract it used in a new `featureContract` field with the ordered column names.

The classifier plumbing from PR #63 is hardwired to Contract A: `SleepStageClassifying.predict` takes the four-field `StageChallenger.Features`, `CoreMLStageClassifier` builds its input from those four names, and `Card.TestVector` decodes that struct. Contract B needs the feature value generalised to an ordered `[String: Double]` keyed by the card's column list, with the protocol, the Core ML wrapper and the test vectors following. The bundled challenger keeps working through the same path with a four-column card.

## Training and evaluation

1. Build the dataset: for the last 90 days, fetch records through the existing chunked `HealthSyncService.sleepRecords` path, then vitals and movement per night (two requests a night, so up to ~180 pod requests, run sequentially with progress), filter outliers with `SleepAnalyzer.filterOutliers`, compute features, attach Watch labels.
2. Leave-one-night-out: for each labelled night, train on the others and score the held-out night per 5-minute epoch with `StageScore` (κ, accuracy, confusion). Report the pooled κ, the per-night κ, and the same for the rules and the bundled challenger on the same epochs.
3. Class balance: wake and REM are rare in bed data (on the card's nine nights the Watch says light 61%, REM 25%, deep 11%, wake 2%), so a forest collapses to "light". Create ML has no class-weight parameter; instead duplicate rows of each rare class in the training table in inverse proportion to its frequency, capped so no class exceeds light's count. Held-out nights are never oversampled.
4. Final fit: retrain on all nights, write `.mlmodel`, compile with `MLModel.compileModel`, store under Application Support/StageModel/ with a card in the challenger's card schema extended by two fields: `featureContract` (ordered column names) and a `lono` evaluation beside `loso` and `pod` in `Card.Metrics`, plus the hyperparameters used. Today's `Card` decodes neither, so both are additive schema changes. Loading moves from `StageChallenger.load(from: Bundle)` to a URL-based loader shared by the bundled and personal models; it keeps the rule that a model failing its own test vectors is refused.
5. Post-processing: the analyzer works in 60-second epochs and its smoothing only removes single-epoch A-B-A spikes, while the model emits 5-minute blocks. Smoothing therefore runs on the 5-minute blocks (an isolated block between two equal neighbours takes their stage), the blocks are then expanded to five 60-second epochs so the Night page, quality score and sync see the epoch shape they expect, and the transition constraints run on those epochs as they do for the rules.

Success criteria for a model to become eligible as the live classifier: pooled leave-one-night-out κ at least 0.05 above both the rules and the bundled challenger, and a higher κ than both on a majority of the nights, over at least 5 nights. The per-night condition guards against one good night carrying the pooled number; the card already shows per-night κ swinging from −0.05 to 0.13. Until then it stays a comparison lane.

## Integration

- **Stage models screen** gains two lanes, "Personal logistic" and "Personal forest", each with κ and accuracy, next to Watch, Pod (rules) and Challenger. A Train button with progress, last-trained date, nights and epochs used, and Delete.
- **Live classifier setting:** Settings → On-device analysis → "Sleep stages from": Rules (default), Personal logistic, Personal forest. Only eligible models can be chosen. `SleepAnalyzer.analyze` takes an optional `SleepStageClassifying`; when set and calibration quality ≥ 0.3 it classifies from features instead of rules, then applies the same post-processing.
- **Health sync:** `HealthSyncService.receiptSignature` includes the active model's card version, so switching models rewrites synced nights through the existing rewrite path from PR #60. The Night page, week view and sync all read the one setting.
- **Retraining:** offered when at least 3 new labelled nights have accrued since the last fit. Never automatic in the background; training runs only on user action, in the foreground.
- **Export:** the de-identified `stage-challenger-v1.json` share grows two optional per-night lanes, `personalLogistic` and `personalForest`, still without timestamps or IDs, so off-device analysis can compare across users. The schema name stays `stage-challenger-v1` because the new keys are optional and readers that ignore them keep working.

## Off-device parity in the Mac analysis container

The same two models should be trained off the pod on the same features so on-device results can be cross-checked:

- Dataset: the per-minute pairing of Watch stages and pod vitals from `sleepypod-core/docs/research/sleep-stage-calibration` (pod DB snapshot plus Health export, or `--from-db` after `import-watch-health.py`).
- Models: scikit-learn `LogisticRegression` and `RandomForestClassifier` with the ojwalch/sleep_classifiers settings, over Contract A and Contract B features computed by a port of the Swift feature code. Leave-one-night-out, κ and confusion per night, same as on device.
- Parity check, two halves. Conversion: convert each with coremltools to `.mlmodel`, generate card test vectors, and confirm the iOS `CoreMLStageClassifier` reproduces the container's predictions on those vectors; a mismatch there is the converter. Features: a fixture of one night's raw vitals and movement plus the feature rows the Python port computes from it, checked against the Swift feature type in a unit test; a mismatch there is the feature contract.
- Output: a card JSON in the challenger schema per model, so a container-trained model could also be bundled as a second challenger if it beats the personal one.

The container itself was not found in the sleepypod repositories on this Mac; its Dockerfile and the dataset script location need to be added to the research README when this lands.

## Work breakdown

1. `StageFeatures.swift`: Contract A and B feature computation, shared, pure, with tests against hand-computed rows and the raw-vitals parity fixture. Reuse `StageChallenger.features` for A. Generalise `SleepStageClassifying`, `CoreMLStageClassifier` and `Card.TestVector` to named columns in the same PR, keeping the bundled challenger's tests green.
2. `StageDataset.swift`: nights, labels, leave-one-night-out splits, rare-class oversampling. Tests with the Watch-comparison fixtures.
3. `StageTrainer.swift`: Create ML training behind `#if canImport(CreateML)`, card generation, compile and store. Device-only; a simulator build gets a stub that reports "needs an iPhone".
4. `StageModelStore.swift`: URL-based loader shared with the bundled challenger, the extended card (`featureContract`, `lono`), the live-classifier setting, eligibility.
5. `SleepAnalyzer` classifier injection; `HealthSyncService` signature; `SleepScreen` and sync call sites.
6. Stage models screen lanes, Train/Delete, Settings row. Demo mode shows a synthesized personal model from the demo Watch.
7. Research README additions for the container run and parity check, plus a scikit-learn script.

Each of 1–4 is its own PR with tests; 5 and 6 can ship together once 4 is in.

## Risks

- Few nights: nine today. Logistic is the safer first result; the forest needs 15–20 nights before its κ stabilises. The UI shows per-night κ so a lucky pooled number is visible as such.
- Label noise: the Watch is the reference, not the truth. The eligibility bar is relative to the rules and the challenger, not absolute.
- Class imbalance and short bed sessions: skipped below 2 h of Watch sleep; oversampled rare classes.
- Battery and time: seconds for these sizes, foreground only, never on background refresh.
- Privacy: all training and inference on the phone; the export stays de-identified; Health times and source names are logged private.
- Breathing rate may still be constant on older pod firmware even though core#172 is resolved; the plan does not depend on it.
