# Health rebuild corrections — 2026-10-25

CI run 40243050840 failed a lifecycle assertion that assumed the seven-day recent sync and ninety-day rebuild contained identical demo nights. At late UTC hours, the oldest mock bedtime falls outside the recent window. The regression now uses stable two-day-old and ten-day-old sessions and explicitly checks the different windows.

Review of that path also found and corrected cleanup defects:

- Rebuild cleanup matches the current app source **and** the selected Pod/side device identifier. Other Pods and sides retain their samples and receipts.
- Existing receipts remain available while a forced rewrite runs, preserving the old interval when record bounds changed. Only successfully rebuilt receipts survive the final scoped cleanup.
- Missing analysis or no eligible selected Health metrics makes the rebuild incomplete, preventing the final sweep.
- Persisted increasing sample versions prevent equal-millisecond replacements or a backward wall-clock correction from invalidating cleanup ordering.
- The confirmation describes the actual ninety-day and Pod/side scope.

Validation: `/tmp/SleepypodHealthRebuildFixed.xcresult` passes all 15 Health lifecycle tests on iPhone 18 Pro / iOS 27 with a fake Health store. No personal Health data was read, written or deleted. CI now retains its result bundle and assertion output for future diagnosis. Real-device Health permission/sync verification and the final release remain pending.
