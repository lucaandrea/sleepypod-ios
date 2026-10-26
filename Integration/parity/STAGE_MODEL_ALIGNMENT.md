# Native model-library and returned-classifier alignment

2026-10-26. Follow-up to STAGE_VALIDATION.md, against the coordinated Core's merged personal-model contract (PR10 c24e70c, model API commit `8f1a54fdd2f7f06ef181acf428d0a88f761a2896`; docs/PERSONAL_STAGE_MODELS.md).

The library preview now sends the explicitly chosen, side-owned modelId rather than implicitly evaluating the previously selected model. An imported document is the exclusive alternative. Changing the choice, input file, side or night window invalidates old scores; delayed responses cannot restore them. Returned display-version mismatches and invalid agreement scores are rejected before rendering. Version names are labels, not content identity; the controller owns content hashes and deduplication.

Model files are bounded to 4 MiB, matching Core's limit, and retain full arbitrary scorecard metadata through upload. Local format and test-vector checks are not accuracy evidence. The scorecard explicitly labels uploader-reported held-out metrics; comparison scores are independently returned by the controller. Missing reference overlap remains unavailable.

Library and selected-model responses retain modelHash. Night's classifier disclosure retains the actual returned engine/version/hash/reason and the distinct adopted rules-profile provenance. Rules fallback is reported from the response, never inferred from the current requested selection. Legacy responses without the new optional fields remain readable and do not acquire invented hashes.

The native Demo permits local file inspection without uploading or scoring the imported file. Its existing synthetic library has no recorded-night scores. File-picker cancellation is checked through the same Settings/Sleep navigation used by users. No health-store data, real upload, processor adoption, or actuator operation is established by these tests.

The literal fixture is generated from the immutable Core `4673112` source's pure stageModelSchema, stageNight, stageModelBlocks and canonical dataHash. It covers active-model identity, rules selection and no-epoch fallback from synthetic readings. It does not open a database. Expected model hash: 8a5032bd96d24ea97d5c122da89e804d6c7a72be757c87829974a185d3b5d54e. Maximum bytes: 4194304.

The implementation is integrated. `Stage-alignment-phone-v1.xcresult` passes all 27 focused checks (six new alignment tests, nine existing library tests, eight rule regressions and four Night source tests), plus the two native interaction flows in 43.446 and 16.900 seconds. `Stage-alignment-phone-final.xcresult` includes the Core-generated synthetic model hash and explicit Demo rules reason; its six focused checks and both UI flows pass in 43.224 and 16.808 seconds.

The iPad and maximum-text interaction flows also pass. Model/file-picker and Night source captures are retained under `previews/stage-model-alignment/`. Initial model-identity captures exposed the disclosure clipping animation continuing briefly beyond XCTest’s idle signal. Capture timing now waits half a second; the model flow also asserts the complete fixture hash. Settled-capture reruns pass on phone (45.880 seconds), iPad (37.026 seconds), and maximum text (114.508 seconds). All 21 retained captures were reviewed; long identities wrap and remain vertically scrollable at maximum text. This timing change affects tests only. Strict SwiftLint, diff whitespace checks and the native-presentation guard pass. PR #26 passed build, contract-test, lint and done, then merged at `d149cf5d94cf0b9b11a3b9caf725d625b3b66b34` on 2026-10-26. Its feature branch is removed.

Version/build remain 0.2.0 (7). Full parity, final QA and TestFlight remain pending.
