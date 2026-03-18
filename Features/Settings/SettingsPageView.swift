import AppKit
import SwiftUI

private enum SettingsPersistence {
    static func bool(for key: String, fallback: Bool) -> Bool {
        FluxBarPreferences.bool(for: key, fallback: fallback)
    }

    static func string(for key: String, fallback: String) -> String {
        FluxBarPreferences.string(for: key, fallback: fallback)
    }

    static func set(_ value: Bool, for key: String) {
        FluxBarPreferences.set(value, for: key)
    }

    static func set(_ value: String, for key: String) {
        FluxBarPreferences.set(value, for: key)
    }
}

private enum SettingsPanel: String, CaseIterable {
    case basic = "基础设置"
    case ports = "端口"
    case debug = "调试"
    case maintenance = "维护"
}

private struct BasicSetting: Identifiable {
    let id: String
    let key: String
    let name: String
    let subtitle: String
    let icon: String

    static let items: [BasicSetting] = [
        .init(id: "autoLaunch", key: "autoLaunch", name: "开机自启", subtitle: "登录后自动启动菜单栏程序", icon: "⇪"),
        .init(id: "coreAutoStart", key: "coreAutoStart", name: "内核自启", subtitle: "应用启动时自动拉起当前内核", icon: "⚙️"),
        .init(id: "allowLan", key: "allowLan", name: "允许局域网", subtitle: "允许局域网设备通过本机代理", icon: "🧭"),
        .init(id: "ipv6", key: "ipv6", name: "IPv6", subtitle: "启用 IPv6 相关支持", icon: "🌍"),
        .init(id: "tunMode", key: "tunMode", name: "TUN 模式", subtitle: "增强网络接管能力", icon: "🛡")
    ]
}

private struct PortSetting: Identifiable {
    let id: String
    let name: String
    let description: String
    var value: String

    static let presets: [PortSetting] = [
        .init(id: "http", name: "HTTP 端口", description: "传统 HTTP 代理入口", value: "0"),
        .init(id: "socks", name: "SOCKS 端口", description: "Socket5 代理入口", value: "0"),
        .init(id: "mixed", name: "混合端口", description: "推荐桌面应用使用", value: "7890"),
        .init(id: "redir", name: "重定向端口", description: "Redir 流量接管", value: "0"),
        .init(id: "tproxy", name: "TProxy 端口", description: "TProxy 高级接管", value: "0")
    ]
}

private struct MaintenanceAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String

    static let items: [MaintenanceAction] = [
        .init(id: "fakeip", title: "清理 FakeIP 缓存", subtitle: "释放旧的 FakeIP 映射记录", icon: "🧹"),
        .init(id: "dns", title: "清理 DNS 缓存", subtitle: "清理本地 DNS 解析缓存", icon: "🧼"),
        .init(id: "kernelDir", title: "打开内核目录", subtitle: "查看当前内核文件与版本", icon: "📂"),
        .init(id: "logDir", title: "打开日志目录", subtitle: "查看运行日志与错误输出", icon: "📜")
    ]
}

private struct KernelUpdatePreviewItem: Identifiable {
    let id: String
    let title: String
    let version: String
    let status: String
    let tone: FluxTone

    nonisolated init(id: String, title: String, version: String, status: String, tone: FluxTone) {
        self.id = id
        self.title = title
        self.version = version
        self.status = status
        self.tone = tone
    }
}

private struct KernelVersionSummary {
    let currentVersion: String
    let latestVersion: String

    static let placeholder = KernelVersionSummary(currentVersion: "检测中", latestVersion: "检测中")
}

struct SettingsPageView: View {
    @ObservedObject var runtimeStore: FluxBarRuntimeStore
    var onShowToast: (String) -> Void = { _ in }

    @State private var selectedPanel: SettingsPanel = .basic
    @State private var basicSettingsState: [String: Bool] = [
        "autoLaunch": SettingsPersistence.bool(for: "settings.autoLaunch", fallback: false),
        "coreAutoStart": SettingsPersistence.bool(for: "settings.coreAutoStart", fallback: true),
        "allowLan": SettingsPersistence.bool(for: "settings.allowLan", fallback: false),
        "ipv6": SettingsPersistence.bool(for: "settings.ipv6", fallback: false)
    ]
    @State private var portSettings = PortSetting.presets.map { item in
        PortSetting(
            id: item.id,
            name: item.name,
            description: item.description,
            value: SettingsPersistence.string(for: "ports.\(item.id)", fallback: item.value)
        )
    }
    @State private var isCheckingUpdate = false
    @State private var isApplyingCoreSettings = false
    @State private var isQuittingApplication = false
    @State private var updateStatus = "上次检查 11 分钟前"
    @State private var updateSheetPresented = false
    @State private var logsEntryPresented = false
    @State private var proxyAdvancedPresented = false
    @State private var externalControllerPresented = false
    @State private var tunAdvancedPresented = false
    @State private var systemProxyEnabled = false
    @State private var proxyAutoConfig = SettingsPersistence.bool(for: "settings.proxyAutoConfig", fallback: false)
    @State private var proxyHost = SettingsPersistence.string(for: "settings.proxyHost", fallback: "127.0.0.1")
    @State private var enableProxyGuard = SettingsPersistence.bool(for: "settings.enableProxyGuard", fallback: false)
    @State private var proxyGuardDuration = SettingsPersistence.string(for: "settings.proxyGuardDuration", fallback: "30")
    @State private var useDefaultBypass = SettingsPersistence.bool(for: "settings.useDefaultBypass", fallback: true)
    @State private var proxyBypass = SettingsPersistence.string(for: "settings.systemProxyBypass", fallback: "")
    @State private var autoCloseConnections = SettingsPersistence.bool(for: "settings.autoCloseConnections", fallback: true)
    @State private var pacFileContent = SettingsPersistence.string(for: "settings.pacFileContent", fallback: SystemProxyProfile.defaultPACTemplate)
    @State private var externalControllerEnabled = SettingsPersistence.bool(for: "settings.enableExternalController", fallback: false)
    @State private var externalControllerAddress = SettingsPersistence.string(for: "settings.externalControllerAddress", fallback: "127.0.0.1:19090")
    @State private var externalControllerSecret = SettingsPersistence.string(for: "settings.externalControllerSecret", fallback: "")
    @State private var externalControllerAllowPrivateNetwork = SettingsPersistence.bool(for: "settings.externalControllerAllowPrivateNetwork", fallback: true)
    @State private var externalControllerAllowOrigins = SettingsPersistence.string(for: "settings.externalControllerAllowOrigins", fallback: "")
    @State private var webUIList = SettingsPersistence.string(
        for: "settings.webUIList",
        fallback: "https://metacubex.github.io/metacubexd/#/setup?http=true&hostname=%host&port=%port&secret=%secret"
    )
    @State private var tunStack = ConfigTUNStack.system
    @State private var tunAutoRoute = true
    @State private var tunAutoDetectInterface = true
    @State private var tunStrictRoute = false
    @State private var tunDNSHijack = "any:53"
    @State private var isApplyingAdvancedSettings = false
    @State private var isApplyingProxyProfile = false
    @State private var isApplyingHelperAction = false
    @State private var kernelVersions: [KernelType: KernelVersionSummary] = Dictionary(
        uniqueKeysWithValues: KernelType.allCases.map { ($0, .placeholder) }
    )
    @State private var updatePreviewItems: [KernelUpdatePreviewItem] = [
        .init(id: "mihomo", title: "mihomo", version: "未检查", status: "待检查", tone: .neutral),
        .init(id: "smart", title: "smart", version: "未检查", status: "待检查", tone: .neutral)
    ]

    private let basicSettings = BasicSetting.items
    private let maintenanceActions = MaintenanceAction.items

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    settingsCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            FluxSheet(
                isPresented: $updateSheetPresented,
                title: "更新检测"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(updatePreviewItems) { item in
                        updatePreviewRow(item)
                    }
                }
            }

            FluxSheet(
                isPresented: $logsEntryPresented,
                title: "运行日志入口"
            ) {
                LogsPanelView(onShowToast: onShowToast)
            }

            FluxSheet(
                isPresented: $proxyAdvancedPresented,
                title: "系统代理高级"
            ) {
                proxyAdvancedContent
            }

            FluxSheet(
                isPresented: $externalControllerPresented,
                title: "外部控制"
            ) {
                externalControllerContent
            }

            FluxSheet(
                isPresented: $tunAdvancedPresented,
                title: "TUN 细项"
            ) {
                tunAdvancedContent
            }
        }
        .task {
            syncAutoLaunchState()
            await refreshSystemProxyState()
            loadAdvancedSettingsFromRuntime()
            await refreshKernelVersionSummaries(checkLatest: false, announce: false)
        }
        .onChange(of: runtimeStore.lastSyncedAt) { _, _ in
            Task {
                await refreshSystemProxyState()
                await MainActor.run {
                    loadAdvancedSettingsFromRuntime()
                }
            }
        }
    }

    private var settingsCard: some View {
        FluxCard(
            title: "系统设置"
        ) {
            settingsSegments

            currentPanel
        }
    }

    @ViewBuilder
    private var currentPanel: some View {
        switch selectedPanel {
        case .basic:
            basicPanel
        case .ports:
            portsPanel
        case .debug:
            debugPanel
        case .maintenance:
            maintenancePanel
        }
    }

    private var basicPanel: some View {
        settingGroup {
            if systemProxyWarningVisible {
                warningSettingRow(
                    icon: "🌐",
                    title: "系统代理已开启",
                    message: "当前内核未运行，流量不会被转发。"
                )
            }

            ForEach(basicSettings) { item in
                if item.key == "tunMode" {
                    tunSettingRow(item)
                } else {
                    toggleSettingRow(icon: item.icon, title: item.name, subtitle: item.subtitle, toggle: binding(for: item.key, in: $basicSettingsState))
                }
            }

            actionSettingRow(
                icon: "🌐",
                title: "系统代理高级",
                subtitle: proxyAutoConfig ? "PAC 模式" : "普通代理模式"
            ) {
                Button {
                    proxyAdvancedPresented = true
                } label: {
                    openButtonLabel("配置")
                }
                .buttonStyle(.plain)
            }

            actionSettingRow(
                icon: "🛠",
                title: "TUN 细项",
                subtitle: "stack=\(tunStack.rawValue) · dns-hijack=\(tunDNSHijack)"
            ) {
                Button {
                    tunAdvancedPresented = true
                } label: {
                    openButtonLabel("配置")
                }
                .buttonStyle(.plain)
            }

            quitButton
        }
    }

    private var portsPanel: some View {
        settingSection(icon: "🔌", title: "代理端口") {
            ForEach($portSettings) { $port in
                valueSettingRow(
                    title: port.name,
                    subtitle: port.description,
                    value: Binding(
                        get: { port.value },
                        set: { newValue in
                            port.value = newValue
                            SettingsPersistence.set(newValue, for: "ports.\(port.id)")
                        }
                    )
                )
            }

            HStack {
                Spacer(minLength: 0)

                Button {
                    applyCoreSettings(reason: "端口配置")
                } label: {
                    openButtonLabel(isApplyingCoreSettings ? "应用中" : "保存并应用")
                }
                .buttonStyle(.plain)
                .disabled(isApplyingCoreSettings)
                .padding(.top, 8)
            }
        }
    }

    private var debugPanel: some View {
        settingSection(icon: "🪲", title: "调试与日志") {
            actionSettingRow(
                icon: "📜",
                title: "查看运行日志",
                subtitle: "进入日志页查看实时输出与错误信息"
            ) {
                Button {
                    logsEntryPresented = true
                    onShowToast("已打开日志入口")
                } label: {
                    openButtonLabel("打开")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var maintenancePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            settingSection(icon: "🧰", title: "内核与维护") {
                VStack(alignment: .leading, spacing: 10) {
                    FluxSegmentedControl(
                        options: KernelType.allCases.map { FluxSegmentedOption(value: $0, title: $0.displayName) },
                        selection: selectedKernelBinding,
                        appearance: .compact
                    )

                    kernelVersionsGrid
                }
                .padding(.bottom, 2)

                actionSettingRow(icon: "⬇️", title: "检查内核更新", subtitle: updateStatus) {
                    Button(action: checkKernelUpdate) {
                        openButtonLabel(isCheckingUpdate ? "检查中" : "检查")
                    }
                    .buttonStyle(.plain)
                }
            }

            settingSection(icon: "🧰", title: "维护工具") {
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(maintenanceActions) { action in
                        Button {
                            performMaintenanceAction(action)
                        } label: {
                            Text("\(action.icon) \(action.title)")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(Color(red: 0.16, green: 0.25, blue: 0.37))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.86),
                                                    Color.white.opacity(0.56)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(.white.opacity(0.80), lineWidth: 1)
                                )
                                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var settingsSegments: some View {
        HStack(spacing: 8) {
            ForEach(SettingsPanel.allCases, id: \.self) { panel in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedPanel = panel
                    }
                } label: {
                    Text(panel.rawValue)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(selectedPanel == panel ? .white : FluxTheme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(settingsSegmentBackground(for: panel))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.66), lineWidth: 1)
        )
        .padding(.bottom, 2)
    }

    private func settingsSegmentBackground(for panel: SettingsPanel) -> some View {
        Group {
            if selectedPanel == panel {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(FluxTheme.accentFill)
                    .shadow(color: FluxTheme.accentTop.opacity(0.20), radius: 8, y: 4)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.62))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(.white.opacity(0.74), lineWidth: 1)
                    )
            }
        }
    }

    private func settingSection<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(icon: icon, title: title)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.84),
                            Color.white.opacity(0.62)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.72), lineWidth: 1)
        )
    }

    private func settingGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.84),
                            Color.white.opacity(0.62)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.72), lineWidth: 1)
        )
    }

    private func toggleSettingRow(icon: String, title: String, subtitle: String, toggle: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                sectionIcon(icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(FluxTheme.textPrimary)
                }
            }

            Spacer(minLength: 8)

            FluxToggle(isOn: toggle)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func valueSettingRow(title: String, subtitle: String, value: Binding<String>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(FluxTheme.textPrimary)
            }

            Spacer(minLength: 8)

            TextField("0", text: value)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(FluxTheme.textPrimary)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(FluxTheme.elevatedFill, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.88), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.08), radius: 8, y: 4)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func actionSettingRow<Trailing: View>(icon: String, title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                sectionIcon(icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(FluxTheme.textPrimary)
                }
            }

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func warningSettingRow(icon: String, title: String, message: String) -> some View {
        HStack(spacing: 12) {
            sectionIcon(icon)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(FluxTheme.textPrimary)

                Text(message)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FluxTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func sectionIcon(_ icon: String) -> some View {
        Text(icon)
            .font(.system(size: 16))
            .foregroundStyle(FluxTheme.textPrimary)
            .frame(width: 34, height: 34)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(.white.opacity(0.82), lineWidth: 1)
            )
    }

    private var quitButton: some View {
        Button(action: quitFluxBar) {
            HStack(spacing: 8) {
                if isQuittingApplication {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .black))
                }

                Text(isQuittingApplication ? "正在退出 FluxBar" : "退出 FluxBar")
                    .font(.system(size: 13, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.44, blue: 0.41),
                                Color(red: 0.90, green: 0.20, blue: 0.18)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.30), lineWidth: 1)
            )
            .shadow(color: Color.red.opacity(0.22), radius: 10, y: 5)
            .padding(.top, 10)
        }
        .buttonStyle(.plain)
        .disabled(isQuittingApplication)
    }

    private func updatePreviewRow(_ item: KernelUpdatePreviewItem) -> some View {
        FluxListRow(
            icon: item.title == "mihomo" ? "🌀" : "🧠",
            title: item.title,
            subtitle: item.version
        ) {
            FluxBadge(title: item.status, tone: item.tone)
        }
    }

    private var kernelVersionsGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ], spacing: 8) {
            versionTag(title: "mihomo 当前", value: kernelVersions[.mihomo]?.currentVersion ?? "未安装", tone: .accent)
            versionTag(title: "mihomo 最新", value: kernelVersions[.mihomo]?.latestVersion ?? "未检查", tone: .positive)
            versionTag(title: "smart 当前", value: kernelVersions[.smart]?.currentVersion ?? "未安装", tone: .neutral)
            versionTag(title: "smart 最新", value: kernelVersions[.smart]?.latestVersion ?? "未检查", tone: .warning)
        }
    }

    private func versionTag(title: String, value: String, tone: FluxTone) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(FluxTheme.textSecondary)

            Text(value)
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundStyle(FluxTheme.chipForeground(for: tone))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.82), lineWidth: 1)
        )
    }

    private func checkKernelUpdate() {
        guard isCheckingUpdate == false else {
            return
        }

        isCheckingUpdate = true
        updateStatus = "正在检查内核更新"

        Task {
            await refreshKernelVersionSummaries(checkLatest: true, announce: true)
        }
    }

    private func previewVersionText(for result: KernelUpdateCheckResult) -> String {
        let installed = result.installedVersion
        let latest = result.latestRelease?.version

        switch (installed, latest) {
        case let (installed?, latest?) where installed != latest:
            return "\(installed) -> \(latest)"
        case (_, let latest?):
            return latest
        case (let installed?, nil):
            return installed
        default:
            return "未找到版本信息"
        }
    }

    private func previewStatusText(for status: KernelUpdateCheckStatus) -> String {
        switch status {
        case .updateAvailable:
            return "可更新"
        case .upToDate:
            return "最新"
        case .notInstalled:
            return "未安装"
        case .installedVersionUnknown:
            return "版本未知"
        case .sourceUnavailable:
            return "未配置源"
        }
    }

    private func previewTone(for status: KernelUpdateCheckStatus) -> FluxTone {
        switch status {
        case .updateAvailable:
            return .accent
        case .upToDate:
            return .positive
        case .notInstalled:
            return .warning
        case .installedVersionUnknown:
            return .neutral
        case .sourceUnavailable:
            return .warning
        }
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 10) {
            sectionIcon(icon)

            Text(title)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(FluxTheme.textPrimary)
        }
        .padding(.bottom, 2)
    }

    private var proxyAdvancedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            advancedToggleRow(title: "PAC 模式", isOn: $proxyAutoConfig)
            advancedTextFieldRow(title: "代理 Host", text: $proxyHost, placeholder: "127.0.0.1")
            advancedToggleRow(title: "Proxy Guard", isOn: $enableProxyGuard)
            advancedTextFieldRow(title: "Guard 间隔(秒)", text: $proxyGuardDuration, placeholder: "30")
            advancedToggleRow(title: "默认 Bypass", isOn: $useDefaultBypass)
            advancedTextFieldRow(title: "自定义 Bypass", text: $proxyBypass, placeholder: "localhost,127.0.0.1")
            advancedToggleRow(title: "关闭代理时断开连接", isOn: $autoCloseConnections)
            if proxyAutoConfig {
                advancedTextEditorRow(title: "PAC 模板", text: $pacFileContent)
            }

            HStack {
                Spacer(minLength: 0)

                Button {
                    applySystemProxyAdvancedSettings()
                } label: {
                    openButtonLabel(isApplyingProxyProfile ? "应用中" : "保存并应用")
                }
                .buttonStyle(.plain)
                .disabled(isApplyingProxyProfile)
            }
            .padding(.top, 6)
        }
    }

    private var externalControllerContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            advancedToggleRow(title: "启用外部控制", isOn: $externalControllerEnabled)
            advancedTextFieldRow(
                title: "Controller 地址",
                text: $externalControllerAddress,
                placeholder: "127.0.0.1:19090",
                disabled: externalControllerEnabled == false
            )
            advancedTextFieldRow(
                title: "Secret",
                text: $externalControllerSecret,
                placeholder: "必填",
                disabled: externalControllerEnabled == false
            )
            advancedToggleRow(
                title: "CORS allow-private-network",
                isOn: $externalControllerAllowPrivateNetwork
            )
            advancedTextEditorRow(
                title: "CORS allow-origins（每行一个）",
                text: $externalControllerAllowOrigins
            )
            advancedTextEditorRow(
                title: "WebUI 列表（每行一个 URL）",
                text: $webUIList
            )
            HStack {
                Spacer(minLength: 0)
                Button {
                    openPreferredWebUI()
                } label: {
                    openButtonLabel("打开首选 WebUI")
                }
                .buttonStyle(.plain)
                .disabled(externalControllerEnabled == false)
            }

            HStack {
                Spacer(minLength: 0)

                Button {
                    applyAdvancedRuntimeSettings()
                } label: {
                    openButtonLabel(isApplyingAdvancedSettings ? "应用中" : "保存并应用")
                }
                .buttonStyle(.plain)
                .disabled(isApplyingAdvancedSettings)
            }
            .padding(.top, 6)
        }
    }

    private var tunAdvancedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("TUN Stack")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FluxTheme.textSecondary)

                Spacer(minLength: 8)

                Menu {
                    ForEach(ConfigTUNStack.allCases, id: \.self) { stack in
                        Button(stack.rawValue) {
                            tunStack = stack
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(tunStack.rawValue)
                            .font(.system(size: 12, weight: .heavy))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(FluxTheme.elevatedFill, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(.white.opacity(0.88), lineWidth: 1)
                    )
                }
                .menuStyle(.borderlessButton)
            }

            advancedToggleRow(title: "auto-route", isOn: $tunAutoRoute)
            advancedToggleRow(title: "auto-detect-interface", isOn: $tunAutoDetectInterface)
            advancedToggleRow(title: "strict-route", isOn: $tunStrictRoute)
            advancedTextFieldRow(title: "dns-hijack", text: $tunDNSHijack, placeholder: "any:53")

            HStack(spacing: 8) {
                Button {
                    installTunHelper()
                } label: {
                    openButtonLabel(isApplyingHelperAction ? "处理中" : "安装 Helper")
                }
                .buttonStyle(.plain)
                .disabled(isApplyingHelperAction)

                Button {
                    uninstallTunHelper()
                } label: {
                    openButtonLabel(isApplyingHelperAction ? "处理中" : "卸载 Helper")
                }
                .buttonStyle(.plain)
                .disabled(isApplyingHelperAction)
            }

            HStack {
                Text(helperInstalled ? "当前状态：Helper 已安装" : "当前状态：Helper 未安装")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(helperInstalled ? FluxTheme.good : FluxTheme.warning)
                Spacer(minLength: 0)
            }

            HStack {
                Spacer(minLength: 0)

                Button {
                    applyAdvancedRuntimeSettings()
                } label: {
                    openButtonLabel(isApplyingAdvancedSettings ? "应用中" : "保存并应用")
                }
                .buttonStyle(.plain)
                .disabled(isApplyingAdvancedSettings)
            }
            .padding(.top, 6)
        }
    }

    private var helperInstalled: Bool {
        PrivilegedTUNHelperService.isInstalled()
    }

    private func advancedToggleRow(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FluxTheme.textSecondary)

            Spacer(minLength: 8)
            FluxToggle(isOn: isOn)
        }
        .padding(.vertical, 2)
    }

    private func advancedTextFieldRow(title: String, text: Binding<String>, placeholder: String, disabled: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FluxTheme.textSecondary)
                .frame(width: 160, alignment: .leading)

            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(FluxTheme.elevatedFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.88), lineWidth: 1)
                )
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1)
        }
    }

    private func advancedTextEditorRow(title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FluxTheme.textSecondary)

            TextEditor(text: text)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(minHeight: 96, maxHeight: 140)
                .padding(8)
                .background(FluxTheme.elevatedFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.88), lineWidth: 1)
                )
        }
    }

    private func tunSettingRow(_ item: BasicSetting) -> some View {
        actionSettingRow(icon: item.icon, title: item.name, subtitle: runtimeStore.tunStatus.statusMessage) {
            HStack(spacing: 8) {
                FluxChip(title: tunPhaseTitle, tone: tunPhaseTone)

                FluxToggle(
                    isOn: Binding(
                        get: { runtimeStore.tunConfiguration.enabled },
                        set: { newValue in
                            applyTUNChange(newValue)
                        }
                    ),
                    isEnabled: runtimeStore.isApplyingTun == false,
                    isLoading: runtimeStore.isApplyingTun
                )
            }
        }
    }

    private func openButtonLabel(_ title: String) -> some View {
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

    private var tunPhaseTitle: String {
        switch runtimeStore.tunStatus.phase {
        case .disabled:
            return "已关闭"
        case .configuring:
            return "配置中"
        case .connecting:
            return "启动中"
        case .running:
            return "运行中"
        case .disconnecting:
            return "关闭中"
        case .requiresSetup:
            return "待配置"
        case .recovering:
            return "已回退"
        case .failed:
            return "失败"
        }
    }

    private var tunPhaseTone: FluxTone {
        switch runtimeStore.tunStatus.phase {
        case .running:
            return .positive
        case .connecting, .configuring, .disconnecting:
            return .accent
        case .recovering, .requiresSetup, .failed:
            return .warning
        case .disabled:
            return .neutral
        }
    }

    private var tunPermissionTitle: String {
        switch runtimeStore.tunStatus.permissionState {
        case .unknown:
            return "状态未知"
        case .ready:
            return "权限就绪"
        case .permissionRequired:
            return "待授权"
        case .requiresManualSetup:
            return "需手动配置"
        }
    }

    private var tunPermissionTone: FluxTone {
        switch runtimeStore.tunStatus.permissionState {
        case .ready:
            return .positive
        case .permissionRequired, .requiresManualSetup:
            return .warning
        case .unknown:
            return .neutral
        }
    }

    private func applyTUNChange(_ enabled: Bool) {
        guard runtimeStore.isApplyingTun == false else {
            return
        }

        Task {
            let snapshot = await runtimeStore.applyTUNChange(enabled)

            await MainActor.run {
                onShowToast(snapshot.statusMessage)
            }
        }
    }

    private var selectedKernelBinding: Binding<KernelType> {
        Binding(
            get: { runtimeStore.selectedKernel },
            set: { newValue in
                Task {
                    FluxBarPreferences.selectedKernel = newValue
                    await runtimeStore.selectKernel(newValue)

                    await MainActor.run {
                        onShowToast("已切换到 \(newValue.displayName) 内核")
                    }
                }
            }
        )
    }

    private func binding(for key: String, in state: Binding<[String: Bool]>) -> Binding<Bool> {
        Binding(
            get: { state.wrappedValue[key] ?? false },
            set: { newValue in
                if key == "autoLaunch" {
                    Task {
                        do {
                            try OpenAtLoginManager.setEnabled(newValue)
                            await MainActor.run {
                                state.wrappedValue[key] = newValue
                                onShowToast("\(settingName(for: key))已\(newValue ? "开启" : "关闭")")
                            }
                        } catch {
                            await MainActor.run {
                                state.wrappedValue[key] = OpenAtLoginManager.isEnabled()
                                onShowToast(error.localizedDescription)
                            }
                        }
                    }
                    return
                }

                state.wrappedValue[key] = newValue
                SettingsPersistence.set(newValue, for: settingsPersistenceKey(for: key))
                onShowToast("\(settingName(for: key))已\(newValue ? "开启" : "关闭")")

                if key == "allowLan" || key == "ipv6" {
                    applyCoreSettings(reason: settingName(for: key))
                }
            }
        )
    }

    private func applyCoreSettings(reason: String) {
        guard isApplyingCoreSettings == false else {
            return
        }

        isApplyingCoreSettings = true
        let portMap = Dictionary(uniqueKeysWithValues: portSettings.map { ($0.id, $0.value) })

        Task {
            do {
                _ = try await FluxBarSettingsCoordinator.shared.applyCoreSettings(
                    allowLAN: basicSettingsState["allowLan"] ?? false,
                    ipv6: basicSettingsState["ipv6"] ?? true,
                    ports: portMap
                )
                await runtimeStore.refreshNow()

                await MainActor.run {
                    isApplyingCoreSettings = false
                    onShowToast("\(reason)已应用")
                }
            } catch {
                await MainActor.run {
                    isApplyingCoreSettings = false
                    onShowToast("\(reason)应用失败")
                }
            }
        }
    }

    private func refreshKernelVersionSummaries(checkLatest: Bool, announce: Bool) async {
        await MainActor.run {
            isCheckingUpdate = checkLatest
            if checkLatest {
                updateStatus = "正在检查内核更新"
            }
        }

        var nextVersions = kernelVersions
        var nextPreviewItems = updatePreviewItems
        var statusMessages: [String] = []

        for kernel in KernelType.allCases {
            let currentVersion = await KernelVersionInspector.currentVersion(for: kernel) ?? "未安装"
            var latestVersion = nextVersions[kernel]?.latestVersion ?? "未检查"

            if checkLatest {
                do {
                    let result = try await KernelUpdateService.shared.checkForUpdates(for: kernel)
                    latestVersion = result.latestRelease?.version ?? previewStatusText(for: result.status)
                    statusMessages.append("\(kernel.displayName)：\(result.message)")

                    nextPreviewItems = nextPreviewItems.map { item in
                        guard item.id == kernel.rawValue else {
                            return item
                        }

                        return KernelUpdatePreviewItem(
                            id: item.id,
                            title: item.title,
                            version: previewVersionText(for: result),
                            status: previewStatusText(for: result.status),
                            tone: previewTone(for: result.status)
                        )
                    }
                } catch {
                    latestVersion = "检查失败"
                    statusMessages.append("\(kernel.displayName)：\(error.localizedDescription)")
                    nextPreviewItems = nextPreviewItems.map { item in
                        guard item.id == kernel.rawValue else {
                            return item
                        }

                        return KernelUpdatePreviewItem(
                            id: item.id,
                            title: item.title,
                            version: currentVersion,
                            status: "错误",
                            tone: .warning
                        )
                    }
                }
            }

            nextVersions[kernel] = KernelVersionSummary(currentVersion: currentVersion, latestVersion: latestVersion)
        }

        await MainActor.run {
            kernelVersions = nextVersions
            updatePreviewItems = nextPreviewItems
            isCheckingUpdate = false

            if checkLatest {
                updateStatus = statusMessages.isEmpty ? "未检测到更新源" : statusMessages.joined(separator: " · ")
                updateSheetPresented = true
            }

            if announce {
                onShowToast(checkLatest ? "已完成内核版本检查" : "已更新内核版本信息")
            }
        }
    }

    private func settingsPersistenceKey(for key: String) -> String {
        "settings.\(key)"
    }

    private func settingName(for key: String) -> String {
        basicSettings.first(where: { $0.key == key })?.name
            ?? key
    }

    private func syncAutoLaunchState() {
        basicSettingsState["autoLaunch"] = OpenAtLoginManager.isEnabled()
    }

    @MainActor
    private func refreshSystemProxyState() async {
        let configurationURL = runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
        systemProxyEnabled = await SystemProxyManager.shared.currentProxyEnabled(configurationURL: configurationURL)
    }

    private func loadAdvancedSettingsFromRuntime() {
        if let runtimeStack = runtimeStore.tunConfiguration.stack,
           let parsedStack = ConfigTUNStack(rawValue: runtimeStack) {
            tunStack = parsedStack
        }
        tunAutoRoute = runtimeStore.tunConfiguration.autoRoute ?? true
        tunAutoDetectInterface = runtimeStore.tunConfiguration.autoDetectInterface ?? true
        tunStrictRoute = runtimeStore.tunConfiguration.strictRoute ?? false
        if runtimeStore.tunConfiguration.dnsHijackValues.isEmpty == false {
            tunDNSHijack = runtimeStore.tunConfiguration.dnsHijackValues.joined(separator: ",")
        } else {
            tunDNSHijack = "any:53"
        }

        let runtimeController = runtimeStore.controllerSnapshot
        if runtimeController.bindAddress != nil {
            externalControllerAddress = runtimeController.bindAddress ?? externalControllerAddress
        }
        if let secretValue = runtimeController.secretValue {
            externalControllerSecret = secretValue
        }
        externalControllerEnabled = runtimeController.bindAddress?.isEmpty == false
        if let allowPrivate = runtimeController.corsAllowPrivateNetwork {
            externalControllerAllowPrivateNetwork = allowPrivate
        }
        if runtimeController.corsAllowOrigins.isEmpty == false {
            externalControllerAllowOrigins = runtimeController.corsAllowOrigins.joined(separator: "\n")
        }
    }

    private func applySystemProxyAdvancedSettings() {
        guard isApplyingProxyProfile == false else {
            return
        }

        isApplyingProxyProfile = true
        let normalizedHost = proxyHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "127.0.0.1"
            : proxyHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGuardSeconds = max(5, Int(proxyGuardDuration) ?? 30)
        let normalizedBypass = proxyBypass.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPACTemplate = pacFileContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SystemProxyProfile.defaultPACTemplate
            : pacFileContent

        SettingsPersistence.set(proxyAutoConfig, for: "settings.proxyAutoConfig")
        SettingsPersistence.set(normalizedHost, for: "settings.proxyHost")
        SettingsPersistence.set(enableProxyGuard, for: "settings.enableProxyGuard")
        SettingsPersistence.set(String(normalizedGuardSeconds), for: "settings.proxyGuardDuration")
        SettingsPersistence.set(useDefaultBypass, for: "settings.useDefaultBypass")
        SettingsPersistence.set(normalizedBypass, for: "settings.systemProxyBypass")
        SettingsPersistence.set(autoCloseConnections, for: "settings.autoCloseConnections")
        SettingsPersistence.set(normalizedPACTemplate, for: "settings.pacFileContent")

        Task {
            if systemProxyEnabled == false {
                await MainActor.run {
                    proxyHost = normalizedHost
                    proxyGuardDuration = String(normalizedGuardSeconds)
                    proxyBypass = normalizedBypass
                    pacFileContent = normalizedPACTemplate
                    isApplyingProxyProfile = false
                    onShowToast("已保存系统代理高级设置（当前代理关闭）")
                    proxyAdvancedPresented = false
                }
                return
            }

            let configurationURL = runtimeStore.kernelStatus.configurationURL ?? FluxBarDefaultConfigurationLocator.locate()
            let profile = SystemProxyProfile(
                enabled: systemProxyEnabled,
                mode: proxyAutoConfig ? .pac : .manual,
                proxyHost: normalizedHost,
                enableGuard: enableProxyGuard,
                guardIntervalSeconds: normalizedGuardSeconds,
                useDefaultBypass: useDefaultBypass,
                customBypass: normalizedBypass,
                autoCloseConnections: autoCloseConnections,
                pacTemplate: normalizedPACTemplate
            )
            let summary = await SystemProxyManager.shared.applyProxyProfile(profile, configurationURL: configurationURL)

            await MainActor.run {
                proxyHost = normalizedHost
                proxyGuardDuration = String(normalizedGuardSeconds)
                proxyBypass = normalizedBypass
                pacFileContent = normalizedPACTemplate
                isApplyingProxyProfile = false
                onShowToast(summary)
                proxyAdvancedPresented = false
            }
        }
    }

    private func applyAdvancedRuntimeSettings() {
        guard isApplyingAdvancedSettings == false else {
            return
        }

        isApplyingAdvancedSettings = true

        Task {
            do {
                let allowOrigins = externalControllerAllowOrigins
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                let dnsHijack = tunDNSHijack
                    .split(whereSeparator: { ",;\n\r".contains($0) })
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
                let input = FluxBarAdvancedSettingsInput(
                    tunEnabled: runtimeStore.tunConfiguration.enabled,
                    tunStack: tunStack,
                    tunAutoRoute: tunAutoRoute,
                    tunAutoDetectInterface: tunAutoDetectInterface,
                    tunStrictRoute: tunStrictRoute,
                    tunDNSHijack: dnsHijack.isEmpty ? ["any:53"] : dnsHijack,
                    externalControllerEnabled: externalControllerEnabled,
                    externalControllerAddress: externalControllerAddress,
                    externalControllerSecret: externalControllerSecret,
                    externalControllerAllowPrivateNetwork: externalControllerAllowPrivateNetwork,
                    externalControllerAllowOrigins: allowOrigins
                )

                _ = try await FluxBarSettingsCoordinator.shared.applyAdvancedSettings(input)
                SettingsPersistence.set(externalControllerEnabled, for: "settings.enableExternalController")
                SettingsPersistence.set(externalControllerAddress, for: "settings.externalControllerAddress")
                SettingsPersistence.set(externalControllerSecret, for: "settings.externalControllerSecret")
                SettingsPersistence.set(externalControllerAllowPrivateNetwork, for: "settings.externalControllerAllowPrivateNetwork")
                SettingsPersistence.set(allowOrigins.joined(separator: "\n"), for: "settings.externalControllerAllowOrigins")
                SettingsPersistence.set(webUIList, for: "settings.webUIList")

                await runtimeStore.refreshNow()

                await MainActor.run {
                    isApplyingAdvancedSettings = false
                    externalControllerPresented = false
                    tunAdvancedPresented = false
                    onShowToast("高级配置已应用")
                }
            } catch {
                await MainActor.run {
                    isApplyingAdvancedSettings = false
                    onShowToast(error.localizedDescription)
                }
            }
        }
    }

    private func installTunHelper() {
        guard isApplyingHelperAction == false else {
            return
        }

        isApplyingHelperAction = true
        Task {
            do {
                try await PrivilegedTUNHelperService.shared.installHelperServiceManually()
                let refreshed = await TUNManager.shared.refreshStatus()
                await MainActor.run {
                    isApplyingHelperAction = false
                    onShowToast(refreshed.statusMessage)
                }
            } catch {
                await MainActor.run {
                    isApplyingHelperAction = false
                    onShowToast(error.localizedDescription)
                }
            }
        }
    }

    private func uninstallTunHelper() {
        guard isApplyingHelperAction == false else {
            return
        }

        isApplyingHelperAction = true
        Task {
            do {
                if runtimeStore.tunConfiguration.enabled {
                    _ = await runtimeStore.applyTUNChange(false)
                }
                try await PrivilegedTUNHelperService.shared.uninstallHelperService()
                let refreshed = await TUNManager.shared.refreshStatus()
                await MainActor.run {
                    isApplyingHelperAction = false
                    onShowToast(refreshed.statusMessage)
                }
            } catch {
                await MainActor.run {
                    isApplyingHelperAction = false
                    onShowToast(error.localizedDescription)
                }
            }
        }
    }

    private func openPreferredWebUI() {
        let templates = webUIList
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard let template = templates.first else {
            onShowToast("请先配置 WebUI 列表")
            return
        }

        let bindAddress = externalControllerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostPort = bindAddress.replacingOccurrences(of: "http://", with: "").replacingOccurrences(of: "https://", with: "")
        let split = hostPort.split(separator: ":", maxSplits: 1).map(String.init)
        let host = split.first?.isEmpty == false ? split.first! : "127.0.0.1"
        let port = split.count > 1 ? split[1] : "9090"
        let secret = externalControllerSecret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? externalControllerSecret

        let resolved = template
            .replacingOccurrences(of: "%host", with: host)
            .replacingOccurrences(of: "%port", with: port)
            .replacingOccurrences(of: "%secret", with: secret)

        guard let url = URL(string: resolved) else {
            onShowToast("WebUI 模板 URL 无效")
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func quitFluxBar() {
        guard isQuittingApplication == false else {
            return
        }

        isQuittingApplication = true

        Task {
            await FluxBarLogService.shared.record(
                source: .app,
                level: .info,
                message: "用户请求退出应用，开始执行退出前清理。"
            )

            let proxySummary = await SystemProxyManager.shared.disableAllProxies()
            let tunSnapshot = await TUNManager.shared.setEnabled(false)
            let kernelSnapshot = await KernelManager.shared.stop()

            await FluxBarLogService.shared.record(
                source: .app,
                level: .info,
                message: "退出前清理完成：\(proxySummary)；TUN=\(tunSnapshot.statusMessage)；内核=\(kernelSnapshot.message ?? "已停止")"
            )

            await MainActor.run {
                NSApp.terminate(nil)
            }
        }
    }

    private var systemProxyWarningVisible: Bool {
        systemProxyEnabled && runtimeStore.kernelStatus.isRunning == false && runtimeStore.isSwitchingKernelMode == false
    }

    private func performMaintenanceAction(_ action: MaintenanceAction) {
        Task {
            do {
                switch action.id {
                case "kernelDir":
                    NSWorkspace.shared.open(try FluxBarStorageDirectories.kernelsRoot())
                    await MainActor.run {
                        onShowToast("已打开内核目录")
                    }
                case "logDir":
                    NSWorkspace.shared.open(try FluxBarStorageDirectories.logsRoot())
                    await MainActor.run {
                        onShowToast("已打开日志目录")
                    }
                case "fakeip":
                    let tunnelRoot = try FluxBarStorageDirectories.tunnelRoot()
                    try clearFiles(in: tunnelRoot) { $0.lastPathComponent.localizedCaseInsensitiveContains("fakeip") }
                    await MainActor.run {
                        onShowToast("已清理 FakeIP 缓存")
                    }
                case "dns":
                    let tunnelRoot = try FluxBarStorageDirectories.tunnelRoot()
                    try clearFiles(in: tunnelRoot) { $0.lastPathComponent.localizedCaseInsensitiveContains("dns") }
                    await MainActor.run {
                        onShowToast("已清理 DNS 相关缓存")
                    }
                default:
                    await MainActor.run {
                        onShowToast("已执行 \(action.title)")
                    }
                }
            } catch {
                await MainActor.run {
                    onShowToast("\(action.title)执行失败")
                }
            }
        }
    }

    private func clearFiles(in directoryURL: URL, predicate: (URL) -> Bool) throws {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: nil) else {
            return
        }

        for case let fileURL as URL in enumerator where predicate(fileURL) {
            try? fileManager.removeItem(at: fileURL)
        }
    }
}
