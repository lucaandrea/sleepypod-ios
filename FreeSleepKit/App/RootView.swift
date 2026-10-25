import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage("appearance") private var appearance = "light"
    @AppStorage("podURL") private var address = ""
    @ScaledMetric(relativeTo: .caption) private var navigationLabelSize = 10
    @ScaledMetric(relativeTo: .body) private var brandSize = 17
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= SleepTokens.Layout.desktopBreakpoint {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        brand.padding(8).padding(.bottom, 32)
                        Text("WORKSPACE").sleepText(.eyebrow).foregroundStyle(SleepTheme.secondary)
                            .padding(.horizontal, 12).padding(.bottom, 8)
                        VStack(spacing: 4) {
                            ForEach(SleepTab.allCases, id: \.self) { tab in navigationButton(tab, horizontal: true) }
                        }
                        Spacer()
                        SleepBadge(title: model.connected ? "Pod connected" : "Pod unavailable",
                            tone: model.connected ? .success : .neutral, dot: true).padding(8)
                    }.padding(16).frame(width: SleepTokens.Layout.sidebarWidth).background(SleepTheme.canvas(scheme))
                    Rectangle().fill(SleepTheme.border(scheme)).frame(width: 1)
                    content.environment(\.sleepWideLayout, true)
                }
            } else {
                content.safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Rectangle().fill(SleepTheme.border(scheme)).frame(height: 1)
                        if typeSize.isAccessibilitySize {
                            accessibleNavigation.padding(.horizontal, 20).padding(.vertical, 8)
                        } else {
                            HStack(spacing: 0) {
                                ForEach(SleepTab.allCases, id: \.self) { tab in navigationButton(tab, horizontal: false) }
                            }.frame(minHeight: SleepTokens.Layout.navigationHeight)
                        }
                    }.background(SleepTheme.canvas(scheme))
                }
            }
        }.sleepText(.body).foregroundStyle(SleepTheme.text)
            .buttonStyle(SleepButtonStyle(kind: .text)).background(SleepTheme.canvas(scheme))
            .preferredColorScheme(appearance == "dark" ? .dark : .light)
            .task(id: "\(address)|\(model.side.rawValue)-\(model.days)-\(phase)") {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await model.refresh(includeAnalytics: false)
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
    }
    // Five enlarged labels cannot fit on a phone; retain every destination in one readable menu.
    private var accessibleNavigation: some View {
        Menu {
            ForEach(SleepTab.allCases, id: \.self) { tab in
                Button(tab.rawValue, systemImage: tab.icon) { model.tab = tab }
            }
        } label: {
            HStack {
                Image(systemName: model.tab.icon)
                Text(model.tab.rawValue)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
            }
        }.buttonStyle(SleepButtonStyle(fill: true))
            .accessibilityLabel("Navigate. \(model.tab.rawValue) selected")
    }
    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.stars").font(.system(size: 20)).foregroundStyle(SleepTheme.accent)
                .frame(width: 32, height: 32).background(SleepTheme.text.opacity(0.04), in: .rect(cornerRadius: 8))
            Text("free sleep").font(.system(size: brandSize, weight: .semibold)).tracking(-0.04 * brandSize)
            Spacer(minLength: 0)
            Text("LOCAL").font(.system(size: 8, weight: .semibold)).foregroundStyle(SleepTheme.secondary)
        }
    }
    @ViewBuilder private var content: some View {
        switch model.tab {
        case .tonight: TonightView()
        case .sleep: InsightsView()
        case .autopilot: AutopilotView()
        case .home: BedroomHomeView()
        case .more: ConnectionsView()
        }
    }
    private func navigationButton(_ tab: SleepTab, horizontal: Bool) -> some View {
        let selected = model.tab == tab
        return Button { model.tab = tab } label: {
            if horizontal {
                HStack(spacing: 12) {
                    Image(systemName: tab.icon).font(.system(size: 19)).foregroundStyle(selected ? SleepTheme.accent : SleepTheme.secondary)
                    Text(tab.rawValue).sleepText(.small).foregroundStyle(selected ? SleepTheme.text : SleepTheme.secondary)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12)
                    .background(selected ? SleepTheme.text.opacity(0.04) : .clear, in: .rect(cornerRadius: 8))
            } else {
                VStack(spacing: 6) {
                    Image(systemName: tab.icon).font(.system(size: 22))
                    Text(tab.rawValue).font(.system(size: navigationLabelSize, weight: .medium)).lineLimit(2)
                }.frame(maxWidth: .infinity, minHeight: 52).padding(.vertical, 8)
                    .foregroundStyle(selected ? SleepTheme.accent : SleepTheme.secondary)
            }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
