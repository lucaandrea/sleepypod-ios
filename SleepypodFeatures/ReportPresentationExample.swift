#if DEBUG
import Foundation

/// Isolated UI example: no archive write, Health read, key access or provider request.
enum ReportPresentationExample {
    static let report = PersonalSleepReport(
        id: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
        createdAt: Date(timeIntervalSince1970: 1_793_333_700), provider: .openai, model: "Example model",
        source: "EXAMPLE · synthetic Health and Pod evidence",
        facts: [
            .init(id: "health.recent", text: "Three recorded days in seven. Missing days remain unknown, not zero sleep."),
            .init(id: "pod.coverage", text: "Four completed presence records. Bed presence does not establish sleep duration or stages."),
            .init(id: "health.hrv", text: "Daily HRV uses SDNN; it is not the Pod’s window variability metric.")
        ],
        text: """
        ### Your recent pattern
        **The available history is incomplete.** Start with the days that have recorded observations. [health.recent]

        ### What the evidence can tell us
        - Bed presence describes time in bed, **not confirmed sleep**. [pod.coverage]
        - Keep daily Health HRV separate from Pod estimates. [health.hrv]

        ### One optional experiment
        1. Keep a consistent bedtime for a week.
        2. Compare your morning notes with the next available records.

        ### Uncertainty
        Missing readings do not prove a poor night. An unsupported reference stays visible: [unknown.source].
        """, inputTokens: nil, outputTokens: nil)
}
#endif
