# Apple Watch references and complete-night coverage

The native app can read Watch references directly from Health. In Sleep, open
Imported Apple Watch → Import Apple Watch data → Import directly from this iPhone.
Choose 7, 30 or 90 days, read the history, then review the side, destination and
sample counts before importing. The direct reader is offered only on this
phone's configured sleeper side. The existing ZIP/XML export route remains
available for another sleeper's own export.

The reader respects Health read preferences and pages queries by week. It sends
only identifiable Watch sleep stages, heart rate, respiratory rate and SDNN HRV
through the controller's authenticated reference endpoints. Pod-written samples,
time-in-bed, unspecified stages, future samples, incompatible units/ranges and
conflicting references cannot become Watch ground truth. No Health archive or
unrelated Health fields are sent. These are comparison references, not clinical
truth. Watch SDNN is not the Pod's window IBI variability metric.

Each upload batch contains at most 2,000 records. Original stage boundaries are
retained for idempotent retries. Existing conflicting stages are never replaced;
the app surfaces the rejection and confirmed partial receipt. Owner, side and
consent changes invalidate the reviewed snapshot before subsequent batches.
The app does not enable a model or change the bed during an import.

Night and week stage summaries combine all available recording segments. Epochs
are clipped to recorded windows, duplicate time is counted once, contradictory
overlap stays unknown and gaps are not filled as sleep. Vitals use all recorded
segments on the selected side. Model-tuning comparisons still explicitly identify
the longest segment; whole-night Watch comparisons use the complete recorded span.

## Validation boundaries

Unit tests cover clipping, conflicting overlaps, segmented-night fetches, partial
failures, Watch-source filtering, unit conversion, pagination, payload limits,
changed consent and retry receipts. Simulator tests cover navigation and demo's
no-upload state. Device import and comparison against real Watch nights must be
recorded separately after the build is installed. Historical Watch data without
matching Pod recordings cannot validate Pod staging; history without actual
thermal context and comfort feedback cannot train the comfort learner.
