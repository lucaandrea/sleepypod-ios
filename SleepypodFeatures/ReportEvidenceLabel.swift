import Foundation

/// Labels only identify evidence supplied with the saved report; they never endorse its claims.
enum ReportEvidenceLabel {
    static let titles = [
        "health.coverage": "Health coverage", "health.recent": "Recent Health records",
        "health.sleep": "Recorded sleep", "health.rhr": "Daily resting heart rate",
        "health.hrv": "Daily HRV · SDNN", "health.respiration": "Daily breathing rate",
        "health.timing": "Sleep timing", "health.change": "Recorded sleep change",
        "pod.range": "Pod date range", "pod.coverage": "Pod coverage",
        "pod.presence": "Bed presence", "pod.occupancy": "Bed presence",
        "pod.latest": "Latest presence", "pod.heart": "Estimated Pod heart rate",
        "pod.processing": "Processing provenance"
    ]
    static func title(_ identifier: String) -> String { titles[identifier] ?? identifier }
}
