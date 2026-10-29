import Foundation

struct CoreProcessStatus: Decodable, Sendable {
    let sources: [LogSource]

    static var unavailable: StatusInfo {
        summary(status: .notStarted, message: "Process status unavailable. Check the controller’s Health and Logs views.")
    }

    /// Process liveness is separate from fresh measurements or accurate sleep classification.
    var biometrics: StatusInfo {
        let required = [
            (unit: "sleepypod-piezo-processor.service", label: "Piezo processor"),
            (unit: "sleepypod-sleep-detector.service", label: "Sleep detector"),
            (unit: "sleepypod-environment-monitor.service", label: "Environment monitor")
        ]
        var unavailable: [String] = []
        var inactive: [String] = []
        for service in required {
            let matches = sources.filter { $0.unit == service.unit }
            guard matches.count == 1, let source = matches.first else {
                unavailable.append(service.label)
                continue
            }
            if !source.active { inactive.append(service.label) }
        }
        var messages: [String] = []
        if !unavailable.isEmpty { messages.append("Status unavailable: \(unavailable.formatted()).") }
        if !inactive.isEmpty { messages.append("Not reported running: \(inactive.formatted()).") }
        if !messages.isEmpty {
            return Self.summary(status: .notStarted, message: messages.joined(separator: " "))
        }
        return Self.summary(status: .started,
                            message: "Sensor processes running. Check Health for data freshness and quality.")
    }

    private static func summary(status: ServiceStatus, message: String) -> StatusInfo {
        StatusInfo(name: "Biometric processes", status: status,
                   description: "Sensor processing services", message: message)
    }
}
