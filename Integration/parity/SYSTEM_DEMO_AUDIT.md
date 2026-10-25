# System demo inspection — 2026-10-25

Observed the public Sleepypod development demo at `https://sleepypod.vercel.app/en/system` (build label `47034d4`). This is a UI inventory, not evidence of native implementation or real hardware health. Only navigation and read-only view/filter controls were used; no calibration, vibration, deletion or recording-setting mutation was performed.

| Section | Observed workflows to preserve natively |
| --- | --- |
| Dashboard | Fourteen health checks, build/network/firewall/disk/uptime, pump alerts with dismiss, tonight's temperature/power/maintenance/alarm jobs, side thermal summaries and history. |
| Calibration | Side tabs; piezo, capacitance and temperature calibration state, signal quality, sample counts, expiry meters, per-type recalibration and Calibrate all. |
| Databases | Database/WAL/free-page sizes, integrity and migrations, daily table growth/retention/projection, integrity check and online backup download. Read-only row browser: database/table selector, exact-column equality filter, newest-first pagination, CSV copy. There is no arbitrary row delete control in the inspected web page. |
| Hardware | Side-specific vibration testing with Quick/Standard/Long/Custom patterns, Play and duration/progress. Other live hardware statistics are in Dashboard/Sensors/Thermal. |
| Health | Selectable sensor → service → output path, freshness/flow/down/idle states, diagnosis of the break, and a link to the relevant service logs. |
| Logs | Core/piezo/sleep/environment sources; All/Info/Warn/Error; text filter; Follow toggle; Refresh, Copy, Download; separate firmware console entry. |
| Scheduler | Sync status, job counts by kind, seven-night timeline, next five executions; All jobs view grouped/filterable by Temperature/Power/Alarms/Maintenance/Other with rule identifiers, recurrence and next time. |
| Sensors | Six measured bed regions with fixed thermal colors and missing/stale treatment; presence/zone activity; freezer/water/pump/fan/TEC/hub health; bed/humidity history; piezo side toggles/replay; flow/RPM and time ranges. |
| Storage | Usage categories/raw archive history, pruner target, eMMC wear/reserve/writes, hourly write rates and valid measurement windows; logging mode/debug duration; health-history/raw-recording switches; reclaimable release/staging cleanup and optional old database backups. |
| Thermal | Live/1h/12h/24h/7d histories: bed vs target, water, measured surface, pump RPM, heatsink/hub ambient, powered intervals. Side summaries include flow age and powered-since timestamp. |

The native implementation must use the existing Sleepypod components, preserve unknown/stale state and honor controller capabilities. Table data, diagnostic exports and credentials must remain scoped to the configured owner connection. Cleanup is a distinct reviewed operation with its actual reclaimable scope; the database row browser remains read-only. Detailed dialogs, request contracts and native interaction tests still need implementation/audit before any System checklist item is marked complete.
