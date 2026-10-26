import SwiftUI

struct SystemRuntimeCard: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let runtime: SystemRuntimeFacts
    var body: some View {
        GroupedCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Controller runtime").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: typeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 14) {
                    fact("Uptime", runtime.uptime)
                    fact("Resident memory", SystemStorage.bytes(runtime.rssBytes))
                    fact("Sensor source", runtime.sensorSource.capitalized)
                    fact("First frame", runtime.firstFrameMs.map { milliseconds($0) } ?? "Not received")
                }
                DisclosureGroup("Performance details") {
                    VStack(alignment: .leading, spacing: 12) {
                        fact("Event loop · mean / p95 / max", "\(milliseconds(runtime.eventLoop.meanMs)) / \(milliseconds(runtime.eventLoop.p95Ms)) / \(milliseconds(runtime.eventLoop.maxMs))")
                        if let memory = runtime.memory {
                            fact("Heap used / allocated", "\(SystemStorage.bytes(memory.heapUsedBytes)) / \(SystemStorage.bytes(memory.heapTotalBytes))")
                            fact("External allocations", SystemStorage.bytes(memory.externalBytes))
                            fact("Array buffers", SystemStorage.bytes(memory.arrayBuffersBytes))
                            Text("Array buffers are included in external allocations. These counters do not add up to resident memory.").font(.caption).foregroundStyle(Theme.text2)
                        }
                        ForEach(runtime.startup) { stage in
                            fact(stage.name, "At \(milliseconds(stage.elapsedMs)) · took \(milliseconds(stage.durationMs))")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.accessibilityIdentifier("dashboard.performance")
            }.padding(16)
        }
    }
    private func fact(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.text2)
            Text(value).font(.subheadline.monospacedDigit()).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func milliseconds(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...1))) + " ms" }
}
