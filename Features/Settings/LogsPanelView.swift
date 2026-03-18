import SwiftUI

private enum LogsLevelFilter: String, CaseIterable {
    case all = "全部"
    case info = "信息"
    case warning = "警告"
    case error = "错误"

    func matches(_ level: FluxLogLevel) -> Bool {
        switch self {
        case .all:
            return true
        case .info:
            return level == .info || level == .debug
        case .warning:
            return level == .warning
        case .error:
            return level == .error
        }
    }
}

struct LogsPanelView: View {
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var onShowToast: (String) -> Void = { _ in }

    @State private var entries: [FluxLogEntry] = []
    @State private var searchText = ""
    @State private var selectedLevel: LogsLevelFilter = .all
    @State private var selectedSource: FluxLogSource?
    @State private var isRefreshing = false
    @State private var lastUpdatedAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            filterRow
            entriesPanel
        }
        .frame(minHeight: 560, alignment: .top)
        .task {
            await startLogSubscriptionLoop()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            searchField

            Button(action: reloadLogs) {
                toolbarButtonLabel(isRefreshing ? "刷新中" : "刷新")
            }
            .buttonStyle(.plain)
            .disabled(isRefreshing)

            Button(action: clearLogs) {
                toolbarButtonLabel("清空")
            }
            .buttonStyle(.plain)
        }
    }

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sourceMenu
                FluxBadge(title: "\(filteredEntries.count) 条", tone: .accent)
                Spacer(minLength: 8)
                Text(lastUpdatedText)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FluxTheme.textSecondary)
            }

            FluxSegmentedControl(
                options: LogsLevelFilter.allCases.map { FluxSegmentedOption(value: $0, title: $0.rawValue) },
                selection: $selectedLevel,
                appearance: .compact
            )
        }
    }

    private var entriesPanel: some View {
        Group {
            if filteredEntries.isEmpty {
                Text("当前没有匹配的日志。内核启动、TUN 变更或后续控制器事件会出现在这里。")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FluxTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 450, alignment: .center)
                    .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(.white.opacity(0.86), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.05), radius: 10, y: 4)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredEntries) { entry in
                            logRow(entry)
                        }
                    }
                }
                .frame(minHeight: 450, maxHeight: 450)
            }
        }
    }

    private var filteredEntries: [FluxLogEntry] {
        entries.filter { entry in
            let sourceMatches = selectedSource.map { $0 == entry.source } ?? true
            let levelMatches = selectedLevel.matches(entry.level)
            let textMatches: Bool

            if searchText.isEmpty {
                textMatches = true
            } else {
                let normalizedSearch = searchText.lowercased()
                textMatches = entry.message.lowercased().contains(normalizedSearch)
                    || entry.source.title.lowercased().contains(normalizedSearch)
                    || entry.level.title.lowercased().contains(normalizedSearch)
            }

            return sourceMatches && levelMatches && textMatches
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FluxTheme.textTertiary)

            TextField("搜索日志内容、来源或级别", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FluxTheme.textPrimary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(FluxTheme.elevatedFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.88), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
    }

    private var sourceMenu: some View {
        Menu {
            Button("全部来源") {
                selectedSource = nil
            }

            ForEach(FluxLogSource.allCases) { source in
                Button(source.title) {
                    selectedSource = source
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedSource?.title ?? "全部来源")
                    .font(.system(size: 12, weight: .heavy))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(FluxTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(FluxTheme.elevatedFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.88), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
        }
        .menuStyle(.borderlessButton)
    }

    private func logRow(_ entry: FluxLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                FluxBadge(title: entry.level.title, tone: entry.level.tone)
                FluxChip(title: entry.source.title, tone: entry.source.tone)
                Spacer(minLength: 8)

                Text(timestampText(for: entry.timestamp))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(FluxTheme.textTertiary)
            }

            Text(entry.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(FluxTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FluxTheme.elevatedFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.86), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.05), radius: 8, y: 4)
    }

    private var lastUpdatedText: String {
        guard let lastUpdatedAt else {
            return "尚未读取日志"
        }

        return "最近刷新 \(timestampText(for: lastUpdatedAt))"
    }

    private func timestampText(for date: Date) -> String {
        Self.timestampFormatter.string(from: date)
    }

    private func toolbarButtonLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(FluxTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(FluxTheme.elevatedFill, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(.white.opacity(0.88), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
    }

    private func reloadLogs() {
        Task {
            await loadLogs()
        }
    }

    private func clearLogs() {
        Task {
            await FluxBarLogService.shared.clear()
            await loadLogs()

            await MainActor.run {
                onShowToast("日志已清空")
            }
        }
    }

    private func startLogSubscriptionLoop() async {
        let stream = await FluxBarLogService.shared.stream(limit: 400)
        for await latestEntries in stream {
            if Task.isCancelled {
                break
            }

            await MainActor.run {
                entries = latestEntries
                lastUpdatedAt = Date()
                isRefreshing = false
            }
        }
    }

    private func loadLogs(showBusyState: Bool = true) async {
        await MainActor.run {
            if showBusyState {
                isRefreshing = true
            }
        }

        let latestEntries = await FluxBarLogService.shared.recentEntries(limit: 400)

        await MainActor.run {
            if entries != latestEntries {
                entries = latestEntries
            }
            lastUpdatedAt = Date()
            isRefreshing = false
        }
    }
}
