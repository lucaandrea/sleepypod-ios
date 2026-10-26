import SwiftUI

/// Unified diagnostic console — firmware logs (default) + raw frame inspector.
/// Terminal-style with auto-scroll, pause, type filtering.
struct FirmwareLogConsoleView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let logs: [FirmwareLogEntry]
    let recentFrames: [RawFrameEntry]
    var onClear: () -> Void = {}

    @State private var mode: ConsoleMode = .logs
    @State private var paused = false
    @State private var frozenLogs: [FirmwareLogEntry] = []
    @State private var frozenFrames: [RawFrameEntry] = []
    @State private var selectedFrame: RawFrameEntry?
    @State private var typeFilter: String?

    enum ConsoleMode: String, CaseIterable {
        case logs = "Logs"
        case frames = "Frames"
    }

    private static let typeColors: [String: Color] = [
        "piezo-dual": Theme.violet,
        "capSense2": Theme.green,
        "bedTemp2": Theme.warming,
        "frzHealth": Theme.cooling,
        "frzTemp": Theme.cooling,
        "deviceStatus": Theme.cooling,
        "log": Theme.amber
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let header = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout())
            header {
                Label("CONSOLE", systemImage: "terminal.fill").font(.caption.weight(.semibold)).foregroundStyle(Theme.text2)
                if !typeSize.isAccessibilitySize { Spacer() }
                Text("\(mode == .logs ? displayedLogs.count : filteredFrames.count) entries").font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
            }
            if typeSize.isAccessibilitySize {
                Menu {
                    Picker("Console mode", selection: $mode) { ForEach(ConsoleMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                } label: {
                    Label(mode.rawValue, systemImage: "chevron.up.chevron.down").fixedSize(horizontal: false, vertical: true)
                }.accessibilityIdentifier("sensors.consoleModeMenu")
            } else {
                Picker("Console mode", selection: $mode) {
                    ForEach(ConsoleMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("sensors.consoleMode")
            }
            let controls = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout())
            controls {
                Button(paused ? "Resume" : "Pause") {
                    if !paused { frozenLogs = logs; frozenFrames = recentFrames }
                    paused.toggle()
                }.accessibilityIdentifier("sensors.consolePause")
                if !typeSize.isAccessibilitySize { Spacer() }
                Button("Clear logs") { onClear(); frozenLogs = [] }
            }.font(.subheadline)

            // Type filter (frames mode)
            if mode == .frames {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        FilterPill(label: "All", active: typeFilter == nil) { typeFilter = nil }
                        ForEach(seenTypes, id: \.self) { type in
                            FilterPill(label: type, active: typeFilter == type) { typeFilter = type }
                        }
                    }
                }
            }

            // Console body
            Group {
                if mode == .logs {
                    logsView
                } else {
                    framesView
                }
            }
            .frame(height: 200)
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.cardBorder, lineWidth: 1)
            )
        }
        .cardStyle()
        .sheet(item: $selectedFrame) { frame in
            NavigationStack {
                ScrollView {
                    Text(prettyJSON(frame.json)).font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }.background(Theme.background).navigationTitle(frame.type)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { selectedFrame = nil } }
                        ToolbarItem(placement: .primaryAction) { ShareLink(item: prettyJSON(frame.json)) }
                    }
            }
        }
    }

    // MARK: - Logs View

    private var logsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(displayedLogs) { entry in
                        logRow(entry).id(entry.id)
                    }
                }
                .padding(8)
            }
            .onChange(of: logs.count) {
                if !paused, let last = displayedLogs.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Frames View

    private var displayedLogs: [FirmwareLogEntry] { paused ? frozenLogs : logs }
    private var displayedFrames: [RawFrameEntry] { paused ? frozenFrames : recentFrames }

    private var filteredFrames: [RawFrameEntry] {
        let src = displayedFrames
        if let filter = typeFilter {
            return Array(src.filter { $0.type == filter }.prefix(100))
        }
        return Array(src.prefix(100))
    }

    private var seenTypes: [String] {
        Array(Set(displayedFrames.map(\.type))).sorted()
    }

    private var framesView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(filteredFrames) { frame in
                    Button {
                        if !paused { frozenLogs = logs; frozenFrames = recentFrames; paused = true }
                        selectedFrame = frame
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(frame.type).font(.subheadline.weight(.medium)).foregroundStyle(Self.typeColors[frame.type] ?? Theme.accent)
                            Text(Self.timeFmt.string(from: frame.timestamp)).font(.caption.monospacedDigit()).foregroundStyle(Theme.text2)
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 8)
                    }.buttonStyle(.plain).accessibilityIdentifier("sensors.rawFrame.\(frame.type)")
                }
            }.padding(.vertical, 8)
        }
    }

    // MARK: - Helpers

    private func logRow(_ entry: FirmwareLogEntry) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        return layout {
            Text(Self.timeFmt.string(from: entry.timestamp))
                .foregroundColor(Theme.textMuted)
                .frame(minWidth: 55, alignment: .leading)
            Text(entry.level.rawValue.prefix(3).uppercased())
                .foregroundColor(entry.level.color)
                .frame(minWidth: 30, alignment: .leading)
            Text(cleanMessage(entry.message))
                .foregroundColor(Theme.text1.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2.monospaced())
    }

    private static let timeFmt: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    private func cleanMessage(_ msg: String) -> String {
        if let pipeIdx = msg.firstIndex(of: "|") {
            return String(msg[msg.index(after: pipeIdx)...]).trimmingCharacters(in: .whitespaces)
        }
        return msg
    }

    private func prettyJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: pretty, encoding: .utf8)
        else { return json }
        return str
    }
}

// MARK: - Filter Pill

private struct FilterPill: View {
    let label: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundColor(active ? Theme.accent : Theme.textMuted)
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(active ? Theme.accent.opacity(0.15) : Theme.card)
                )
        }
        .buttonStyle(.plain)
    }
}
