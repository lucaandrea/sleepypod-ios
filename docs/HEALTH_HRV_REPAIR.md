# Review earlier HRV exports

Apple Health's HRV type is SDNN. The Pod's window IBI variability index is not SDNN and must not be converted, scaled or relabelled into that field.

The existing writer accepts only original Pod records whose provenance identifies recorded `hrv_sdnn`. Older app versions did not necessarily record the metric in Health sample metadata. A missing marker makes a historical entry **unverified**, not automatically incorrect. Sync intentionally preserves a measurement when no valid replacement exists, so stopping incompatible future exports does not clean up older entries.

## Export changes

Build 20 defaults HRV export off and pauses an existing selection once using `healthHRVExportReviewVersion`. Other export choices, Health read preferences and existing Health data are unchanged. A later explicit HRV selection persists. The existing SDNN gate remains mandatory. Future SDNN samples carry `sleepypod_hrv_metric=hrv_sdnn` and `sleepypod_hrv_provenance=recorded`; the receipt version advances to 4.

All generic date-based sync/rebuild cleanup excludes HRV, including rejected-record cleanup. The system store enforces this again. Verified future SDNN can replace the same stable sync identifier through a successful HealthKit save, but a normal rebuild cannot sweep unrelated older HRV entries, even with write permission. Historical HRV removal uses the explicit UUID review below.

## Review flow

Settings → Apple Health → Review earlier HRV entries works on the iPhone without contacting the Pod. It needs the saved owner connection and linked side, not a live controller connection. The explicit read action pauses HRV export and requests Health access for this review. The access request itself does not enable export.

The user chooses 7, 30 or 90 days. Only this app's HRV with the exact linked Pod/side device identity is queried. Samples with matching explicit SDNN provenance are kept. Other apps, Apple Watch, other Pod identities, other sides, missing device identities and other Health types are outside the cleanup scope. An empty query is described as no matching entries returned, never proof that all Health data is clean.

Nothing is preselected. The screen lists dates, counts, times and value ranges. The user selects dates and confirms removal of the resulting exact UUID list. The confirmation explains that absence of metadata does not prove every value wrong, and that Health deletion propagates and cannot be undone by this app.

Before deleting anything, the workspace re-reads the selected entries and compares their fields with the review. The store then re-reads each batch's exact UUIDs under source/device/type/date predicates, compares the same fields again, checks permissions and revalidates the owner/side/Health context immediately before deletion. It calls HealthKit deletion with those exact objects, never an unbounded date predicate. New arrivals cannot join the selection. Batches contain at most 200 entries. Failures stop, retain the successful count, clear selection and require a fresh review. Cancellation, backgrounding, side/owner changes and HRV re-enablement invalidate pending review work. A deletion already accepted by HealthKit cannot be undone by cancellation.

The in-memory review is cleared when dismissed/backgrounded. Samples are not logged, uploaded to a model, sent to the Pod or saved in an audit file. Queries are capped at 100,000 results; an oversized range fails visibly and asks for a shorter period.

## Verification boundaries

Regression tests cover migration, preserving read choices, source/device/side filtering, verified SDNN preservation, no automatic selection/deletion, exact UUID removal, changed samples/permissions/context, new arrivals, cancellation and partial failure. UI tests cover the review route and demo's no-Health-access boundary. Synthetic tests do not constitute deletion of real Health data. Physical review/removal requires the owner's iPhone and its confirmation.

This repair does not change sleep classification, occupancy calibration, bed controls or thermal models. Short recorded nights still require actual Pod recording coverage and matching Watch references.

Apple references: [SDNN type](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn), [source predicates](https://developer.apple.com/documentation/healthkit/hkquery/predicateforobjects%28from%3A%29-89b4t), and [deleting app-owned objects](https://developer.apple.com/documentation/healthkit/hkhealthstore/delete%28_%3Awithcompletion%3A%29-78l1m).
