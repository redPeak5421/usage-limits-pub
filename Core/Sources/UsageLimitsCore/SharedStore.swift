import Foundation

/// App 与小组件共享的本地存储（App Group UserDefaults）。
/// 快照与诊断不含凭据。自定义 token 存在独立键 `custom.accountTokens`，仅本机、不上传、不进 Watch。
public final class SharedStore: @unchecked Sendable {
    public static let appGroupID = "group.com.canonforge.usagelimits"
    public static let shared = SharedStore()

    private let defaults: UserDefaults
    private let filesDirectory: URL
    private let queue = DispatchQueue(label: "usagelimits.sharedstore")
    /// 诊断日志内存缓冲（只在 queue 上访问）：一轮 13 实例刷新约 80 行，逐行读写 500 行数组会在主线程卡顿。
    private var pendingDiagnostics: [String] = []
    private var diagnosticsFlushScheduled = false
    /// 复用而非每行新建（创建开销毫秒级）；只在 queue 上使用，随实例而非全局共享。
    private let diagnosticStamp = ISO8601DateFormatter()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(defaults: UserDefaults? = nil, filesDirectory: URL? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: Self.appGroupID) ?? .standard
        if let filesDirectory {
            self.filesDirectory = filesDirectory
        } else if let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) {
            self.filesDirectory = container.appendingPathComponent("custom-logos", isDirectory: true)
        } else {
            // 保留旧回退目录，工程改名不移动已有自定义图标。
            self.filesDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("aiusage-custom-logos", isDirectory: true)
        }
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private func key(_ p: ProviderID) -> String { "snapshot.\(p.rawValue)" }

    // MARK: - 快照

    @discardableResult
    public func save(_ snapshot: ProviderSnapshot) -> Bool {
        if snapshot.isCustom {
            appendDiagnostic("custom: refused snapshot.<provider> write for isCustom snapshot")
            return false
        }
        if let issue = snapshot.persistenceValidationIssue {
            appendDiagnostic("\(snapshot.provider.rawValue): refused invalid snapshot (\(issue))")
            return false
        }
        let result: (saved: Bool, encodingFailure: String?) = queue.sync {
            do {
                let data = try encoder.encode(snapshot)
                defaults.set(data, forKey: key(snapshot.provider))
                return (true, nil)
            } catch {
                return (false, String(describing: error))
            }
        }
        if let encodingFailure = result.encodingFailure {
            appendDiagnostic("\(snapshot.provider.rawValue): refused snapshot encoding failure (\(encodingFailure))")
        }
        return result.saved
    }

    public func snapshot(for provider: ProviderID) -> ProviderSnapshot? {
        let read: (snapshot: ProviderSnapshot?, diagnostic: String?) = queue.sync {
            guard let data = defaults.data(forKey: key(provider)) else { return (nil, nil) }
            guard var snap = try? decoder.decode(ProviderSnapshot.self, from: data) else {
                return (nil, "\(provider.rawValue): refused unreadable cached snapshot")
            }
            snap.metrics = MetricOrdering.apply(snap.metrics, order: metricOrderLocked(for: Self.metricOrderKey(provider: provider)))
            if let issue = snap.persistenceValidationIssue {
                return (nil, "\(provider.rawValue): refused invalid cached snapshot (\(issue))")
            }
            return (snap, nil)
        }
        if let diagnostic = read.diagnostic { appendDiagnostic(diagnostic) }
        return read.snapshot
    }

    // MARK: - 计量条顺序（用户在卡片「…」→ 编辑计量顺序里拖出来的）

    /// 主账号 / 服务商级按服务商存；附加账号与自定义账号按账号 id 存。
    public static func metricOrderKey(provider: ProviderID) -> String { "provider.\(provider.rawValue)" }
    public static func metricOrderKey(accountID: UUID) -> String { "account.\(accountID.uuidString)" }

    public func metricOrder(for key: String) -> [String] {
        queue.sync { metricOrderLocked(for: key) }
    }

    /// 空数组 = 清除自定义顺序，回到解析器默认顺序。
    public func setMetricOrder(_ ids: [String], for key: String) {
        queue.sync {
            if ids.isEmpty {
                defaults.removeObject(forKey: "metricOrder.\(key)")
            } else {
                defaults.set(ids, forKey: "metricOrder.\(key)")
            }
        }
    }

    private func metricOrderLocked(for key: String) -> [String] {
        defaults.stringArray(forKey: "metricOrder.\(key)") ?? []
    }

    public func removeSnapshot(for provider: ProviderID) {
        queue.sync { defaults.removeObject(forKey: key(provider)) }
    }

    public func allSnapshots() -> [ProviderSnapshot] {
        ProviderID.allCases.compactMap { snapshot(for: $0) }
    }

    // MARK: - 手动添加的账号（主账号 + 附加账号；服务商没有固定内置列表）

    private func accountKey(_ id: UUID) -> String { "snapshot.account.\(id.uuidString)" }

    /// 全部已添加账号（按添加顺序）。存储键沿用早期的 "extraAccounts"，避免迁移。
    public var accounts: [ProviderAccount] {
        get {
            queue.sync {
                guard let data = defaults.data(forKey: "extraAccounts"),
                      let accounts = try? decoder.decode([ProviderAccount].self, from: data) else {
                    return []
                }
                return accounts
            }
        }
        set {
            queue.sync {
                if let data = try? encoder.encode(newValue) {
                    defaults.set(data, forKey: "extraAccounts")
                }
            }
        }
    }

    public func accounts(of provider: ProviderID) -> [ProviderAccount] {
        accounts.filter { $0.provider == provider }
    }

    public func primaryAccount(of provider: ProviderID) -> ProviderAccount? {
        accounts.first { $0.provider == provider && $0.isPrimary }
    }

    public func displayName(for account: ProviderAccount) -> String {
        account.displayName(templates: customTemplates, language: appLanguage)
    }

    // MARK: - 自定义模板与 token（token 仅 App / BackgroundRefresh 读取）

    private var customTemplatesKey: String { "custom.templates" }
    private var customAccountTokensKey: String { "custom.accountTokens" }

    public var customTemplates: [CustomUsageTemplate] {
        get {
            queue.sync {
                guard let data = defaults.data(forKey: customTemplatesKey),
                      let templates = try? decoder.decode([CustomUsageTemplate].self, from: data) else {
                    return []
                }
                return templates
            }
        }
        set {
            queue.sync {
                if let data = try? encoder.encode(newValue) {
                    defaults.set(data, forKey: customTemplatesKey)
                }
            }
        }
    }

    public func customTemplate(id: UUID) -> CustomUsageTemplate? {
        customTemplates.first { $0.id == id }
    }

    public func accounts(referencingTemplate templateID: UUID) -> [ProviderAccount] {
        accounts.filter { $0.templateID == templateID }
    }

    /// 仍有账号引用则拒绝删除。无引用时连 logo 文件一起清。
    @discardableResult
    public func removeCustomTemplate(id: UUID) -> Bool {
        guard accounts(referencingTemplate: id).isEmpty else { return false }
        let path = customTemplates.first { $0.id == id }?.logoRelativePath
        customTemplates = customTemplates.filter { $0.id != id }
        removeCustomLogo(relativePath: path)
        return true
    }

    public func customLogoURL(relativePath: String) -> URL {
        filesDirectory.appendingPathComponent(relativePath)
    }

    public func customLogoData(relativePath: String?) -> Data? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        return queue.sync {
            try? Data(contentsOf: customLogoURL(relativePath: relativePath))
        }
    }

    public func customLogoData(for template: CustomUsageTemplate) -> Data? {
        customLogoData(relativePath: template.logoRelativePath)
    }

    public func customLogoData(for account: ProviderAccount) -> Data? {
        guard let templateID = account.templateID,
              let template = customTemplate(id: templateID)
        else { return nil }
        return customLogoData(for: template)
    }

    @discardableResult
    public func writeCustomLogo(data: Data, for templateID: UUID, fileExtension: String) -> String? {
        guard !data.isEmpty else { return nil }
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let safeExt = ext.isEmpty ? "png" : ext
        let name = "\(templateID.uuidString.lowercased()).\(safeExt)"
        return queue.sync {
            do {
                try FileManager.default.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
                try data.write(to: customLogoURL(relativePath: name), options: .atomic)
                return name
            } catch {
                return nil
            }
        }
    }

    public func removeCustomLogo(relativePath: String?) {
        guard let relativePath, !relativePath.isEmpty else { return }
        queue.sync {
            try? FileManager.default.removeItem(at: customLogoURL(relativePath: relativePath))
        }
    }

    public func accountToken(for accountID: UUID) -> String? {
        queue.sync { tokenMap()[accountID.uuidString] }
    }

    public func setAccountToken(_ token: String, for accountID: UUID) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        queue.sync {
            var map = tokenMap()
            if trimmed.isEmpty {
                map.removeValue(forKey: accountID.uuidString)
            } else {
                map[accountID.uuidString] = trimmed
            }
            writeTokenMap(map)
        }
    }

    public func removeAccountToken(for accountID: UUID) {
        queue.sync {
            var map = tokenMap()
            map.removeValue(forKey: accountID.uuidString)
            writeTokenMap(map)
        }
    }

    /// 删自定义账号：清 token 与账号快照，不碰 WebKit。
    public func removeCustomAccountData(accountID: UUID) {
        removeAccountToken(for: accountID)
        removeAccountSnapshot(for: accountID)
    }

    private func tokenMap() -> [String: String] {
        (defaults.dictionary(forKey: customAccountTokensKey) as? [String: String]) ?? [:]
    }

    private func writeTokenMap(_ map: [String: String]) {
        defaults.set(map, forKey: customAccountTokensKey)
    }

    /// 一次性迁移：固定开关模式 → 手动新增模式。
    /// 有历史快照且启用的服务商视为「正在使用」，保留为主账号；
    /// 其余全部关闭（首页与小组件同步隐藏，重新添加即恢复）。
    public func migrateToManualAccountsIfNeeded() {
        let flag = "accountsMigration.v1"
        guard !(queue.sync { defaults.bool(forKey: flag) }) else { return }
        var migrated = accounts
        for provider in providerOrder where primaryAccount(of: provider) == nil {
            if isEnabled(provider), snapshot(for: provider) != nil {
                migrated.append(ProviderAccount(provider: provider, name: "", isPrimary: true))
            }
        }
        accounts = migrated
        for provider in ProviderID.allCases
        where !migrated.contains(where: { $0.provider == provider && $0.isPrimary }) {
            setEnabled(false, for: provider)
        }
        queue.sync { defaults.set(true, forKey: flag) }
    }

    @discardableResult
    public func saveAccountSnapshot(_ snapshot: ProviderSnapshot, accountID: UUID) -> Bool {
        guard accounts.contains(where: { $0.id == accountID }) else {
            appendDiagnostic("account \(accountID.uuidString): refused snapshot for unknown account")
            return false
        }
        if let issue = snapshot.persistenceValidationIssue {
            appendDiagnostic("\(snapshot.provider.rawValue): refused invalid snapshot (\(issue))")
            return false
        }
        let result: (saved: Bool, encodingFailure: String?) = queue.sync {
            do {
                let data = try encoder.encode(snapshot)
                defaults.set(data, forKey: accountKey(accountID))
                return (true, nil)
            } catch {
                return (false, String(describing: error))
            }
        }
        if let encodingFailure = result.encodingFailure {
            appendDiagnostic("\(snapshot.provider.rawValue): refused snapshot encoding failure (\(encodingFailure))")
        }
        return result.saved
    }

    public func accountSnapshot(for accountID: UUID) -> ProviderSnapshot? {
        let read: (snapshot: ProviderSnapshot?, diagnostic: String?) = queue.sync {
            guard let data = defaults.data(forKey: accountKey(accountID)) else { return (nil, nil) }
            guard var snap = try? decoder.decode(ProviderSnapshot.self, from: data) else {
                return (nil, "account \(accountID.uuidString): refused unreadable cached snapshot")
            }
            snap.metrics = MetricOrdering.apply(snap.metrics, order: metricOrderLocked(for: Self.metricOrderKey(accountID: accountID)))
            if let issue = snap.persistenceValidationIssue {
                return (nil, "account \(accountID.uuidString): refused invalid cached snapshot (\(issue))")
            }
            return (snap, nil)
        }
        if let diagnostic = read.diagnostic { appendDiagnostic(diagnostic) }
        return read.snapshot
    }

    public func removeAccountSnapshot(for accountID: UUID) {
        queue.sync { defaults.removeObject(forKey: accountKey(accountID)) }
    }

    // MARK: - 自定义主题色（账号级存在 ProviderAccount.tint；这里是供应商级默认覆盖）

    /// 供应商默认主题色覆盖；key 为 `ProviderID.rawValue`。
    /// 同供应商新增账号经 TintResolver 自动继承，无需复制到账号上。
    public var providerTintOverrides: [String: BrandTint] {
        get {
            queue.sync {
                guard let data = defaults.data(forKey: "providerTintOverrides"),
                      let map = try? decoder.decode([String: BrandTint].self, from: data) else {
                    return [:]
                }
                return map
            }
        }
        set {
            queue.sync {
                if let data = try? encoder.encode(newValue) {
                    defaults.set(data, forKey: "providerTintOverrides")
                }
            }
        }
    }

    /// 三层回落取色：账号自定义 → 供应商默认覆盖 → 内置品牌色。
    public func resolvedTint(provider: ProviderID, accountID: UUID? = nil) -> BrandTint {
        let accountTint = accountID.flatMap { id in accounts.first { $0.id == id }?.tint }
        return TintResolver.resolve(
            accountTint: accountTint, provider: provider, overrides: providerTintOverrides
        )
    }

    /// 一键重置全部自定义颜色：清空所有账号色、模板默认色与供应商默认覆盖。
    public func resetAllCustomTints() {
        var next = accounts
        for i in next.indices { next[i].tint = nil }
        accounts = next
        var templates = customTemplates
        for i in templates.indices { templates[i].tint = nil }
        customTemplates = templates
        providerTintOverrides = [:]
    }

    // MARK: - Provider 启用开关（关闭的服务商不出现在首页/小组件，也不被自动刷新）

    private func enabledKey(_ p: ProviderID) -> String { "provider.enabled.\(p.rawValue)" }

    /// 默认全部启用；只有显式写入 false 才算关闭。
    public func isEnabled(_ provider: ProviderID) -> Bool {
        queue.sync { (defaults.object(forKey: enabledKey(provider)) as? Bool) ?? true }
    }

    /// 自定义账号没有供应商开关，只看账号自身。
    public func isProviderEnabled(for account: ProviderAccount) -> Bool {
        account.provider.map(isEnabled) ?? true
    }

    public func setEnabled(_ enabled: Bool, for provider: ProviderID) {
        queue.sync { defaults.set(enabled, forKey: enabledKey(provider)) }
    }

    public var enabledProviders: [ProviderID] {
        providerOrder.filter { isEnabled($0) }
    }

    // MARK: - 服务商顺序（主页与设置共用同一份全局顺序，拖动排序联动）

    /// 全局顺序：含已关闭的服务商；新增的服务商自动追加在末尾。
    public var providerOrder: [ProviderID] {
        get {
            queue.sync {
                let raw = defaults.stringArray(forKey: "providerOrder") ?? []
                var order = raw.compactMap(ProviderID.init(rawValue:))
                for p in ProviderID.allCases where !order.contains(p) { order.append(p) }
                return order
            }
        }
        set { queue.sync { defaults.set(newValue.map(\.rawValue), forKey: "providerOrder") } }
    }


    public var widgetRainbowGlow: Bool {
        get { queue.sync { defaults.bool(forKey: "widgetRainbowGlow") } }
        set { queue.sync { defaults.set(newValue, forKey: "widgetRainbowGlow") } }
    }

    public var cardRefreshRainbowGlow: Bool {
        get { queue.sync { defaults.bool(forKey: "cardRefreshRainbowGlow") } }
        set { queue.sync { defaults.set(newValue, forKey: "cardRefreshRainbowGlow") } }
    }

    /// 首页卡片用量条用卡片主题色而非阈值色（默认关，仅 App 读）。
    public var cardTintedBars: Bool {
        get { queue.sync { defaults.bool(forKey: "cardTintedBars") } }
        set { queue.sync { defaults.set(newValue, forKey: "cardTintedBars") } }
    }

    /// 用量条上一道高光从 0 扫到当前进度末端循环流动（阈值色与主题色都生效，默认关，仅 App 读）。
    public var cardBarShimmer: Bool {
        get { queue.sync { defaults.bool(forKey: "cardBarShimmer") } }
        set { queue.sync { defaults.set(newValue, forKey: "cardBarShimmer") } }
    }

    // MARK: - 演示模式

    public var demoMode: Bool {
        get { queue.sync { defaults.bool(forKey: "demoMode") } }
        set { queue.sync { defaults.set(newValue, forKey: "demoMode") } }
    }

    // MARK: - 显示语言与自动刷新间隔（App 与小组件共用）

    public var appLanguage: AppLanguage {
        get { queue.sync { AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .system } }
        set { queue.sync { defaults.set(newValue.rawValue, forKey: "appLanguage") } }
    }

    /// 外观主题。App 与小组件都读：浅色 / 深色固定 colorScheme，跟随系统则交给系统外观。
    public var appTheme: AppTheme {
        get { queue.sync { AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .system } }
        set { queue.sync { defaults.set(newValue.rawValue, forKey: "appTheme") } }
    }

    /// 首页主题布局（平铺 / 轮盘 / 螺旋，深浅色另由 appTheme 决定）。只有 App 读；小组件与手表不感知。
    public var dashboardTheme: DashboardTheme {
        get { queue.sync { DashboardTheme(rawValue: defaults.string(forKey: "dashboardTheme") ?? "") ?? .flat } }
        set { queue.sync { defaults.set(newValue.rawValue, forKey: "dashboardTheme") } }
    }

    /// 百分比展示口径（已用 / 剩余）。App、小组件共用；手表经 applicationContext 同步。
    public var usageDisplayMode: UsageDisplayMode {
        get { queue.sync { UsageDisplayMode(rawValue: defaults.string(forKey: "usageDisplayMode") ?? "") ?? .used } }
        set { queue.sync { defaults.set(newValue.rawValue, forKey: "usageDisplayMode") } }
    }

    /// 重置时间展示口径（倒计时 / 具体时刻）。App、小组件共用；手表经 applicationContext 同步。
    public var resetTimeStyle: ResetTimeStyle {
        get { queue.sync { ResetTimeStyle(rawValue: defaults.string(forKey: "resetTimeStyle") ?? "") ?? .countdown } }
        set { queue.sync { defaults.set(newValue.rawValue, forKey: "resetTimeStyle") } }
    }

    /// 自动刷新间隔（秒）。0 = 不自动刷新。
    public var autoRefreshInterval: Double {
        get { queue.sync { AutoRefreshInterval.clamped(defaults.double(forKey: "autoRefreshInterval")) } }
        set {
            let safe = AutoRefreshInterval.clamped(newValue)
            queue.sync { defaults.set(safe, forKey: "autoRefreshInterval") }
        }
    }

    // MARK: - 分享预览选项（隐藏更新时间 / 隐藏未使用 / 用量条同色）

    public var shareComposeOptions: ShareComposeOptions {
        get {
            queue.sync {
                guard let data = defaults.data(forKey: "shareComposeOptions"),
                      let options = try? decoder.decode(ShareComposeOptions.self, from: data) else {
                    return ShareComposeOptions()
                }
                return options
            }
        }
        set {
            queue.sync {
                if let data = try? encoder.encode(newValue) {
                    defaults.set(data, forKey: "shareComposeOptions")
                }
            }
        }
    }

    // MARK: - 提醒设置与已发提醒去重键

    public var notificationSettings: NotificationSettings {
        get {
            queue.sync {
                guard let data = defaults.data(forKey: "notificationSettings"),
                      let settings = try? decoder.decode(NotificationSettings.self, from: data) else {
                    return NotificationSettings()
                }
                return settings
            }
        }
        set {
            queue.sync {
                if let data = try? encoder.encode(newValue) {
                    defaults.set(data, forKey: "notificationSettings")
                }
            }
        }
    }

    /// 已发出的提醒去重键（同一窗口周期同一事件只提醒一次）。环形上限 200。
    public func markNotified(_ key: String) {
        queue.sync {
            var keys = defaults.stringArray(forKey: "notifiedKeys") ?? []
            guard !keys.contains(key) else { return }
            keys.append(key)
            if keys.count > 200 { keys.removeFirst(keys.count - 200) }
            defaults.set(keys, forKey: "notifiedKeys")
        }
    }

    public func notifiedKeys() -> Set<String> {
        queue.sync { Set(defaults.stringArray(forKey: "notifiedKeys") ?? []) }
    }

    /// 展示用快照：演示模式返回演示数据，否则返回真实缓存；已关闭的服务商一律不返回。
    /// 结果按全局服务商顺序排列。
    public func displaySnapshots(now: Date = Date()) -> [ProviderSnapshot] {
        providerOrder.compactMap { displaySnapshot(for: $0, now: now) }
    }

    public func displaySnapshot(for provider: ProviderID, now: Date = Date()) -> ProviderSnapshot? {
        guard isEnabled(provider) else { return nil }
        return demoMode
            ? Self.demoSnapshots(now: now).first { $0.provider == provider }
            : snapshot(for: provider)
    }

    // MARK: - 诊断日志（给用户与开发排查探针问题）

    /// 追加一行诊断：只进内存缓冲，0.5s 内合并一次落盘（在 store 队列上，不占主线程）。
    /// 读取、清空、退到后台前会先 flush，内容与顺序与逐行落盘完全一致。
    public func appendDiagnostic(_ line: String) {
        queue.sync { appendDiagnosticLocked(line) }
    }

    private func appendDiagnosticLocked(_ line: String) {
        pendingDiagnostics.append("[\(diagnosticStamp.string(from: Date()))] \(line)")
        guard !diagnosticsFlushScheduled else { return }
        diagnosticsFlushScheduled = true
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.flushDiagnosticsOnQueue()
        }
    }

    /// 把缓冲写进 UserDefaults；调用方需持有 queue。
    private func flushDiagnosticsOnQueue() {
        diagnosticsFlushScheduled = false
        guard !pendingDiagnostics.isEmpty else { return }
        var lines = defaults.stringArray(forKey: "diagnostics") ?? []
        lines.append(contentsOf: pendingDiagnostics)
        pendingDiagnostics.removeAll(keepingCapacity: true)
        // 结构化日志每次刷新每家约 4–8 行，留 500 行 ≈ 十几轮刷新
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        defaults.set(lines, forKey: "diagnostics")
    }

    /// 立刻落盘缓冲中的诊断（退到后台前调用）。
    public func flushDiagnostics() {
        queue.sync { flushDiagnosticsOnQueue() }
    }

    public func diagnostics() -> [String] {
        queue.sync {
            flushDiagnosticsOnQueue()
            return defaults.stringArray(forKey: "diagnostics") ?? []
        }
    }

    public func clearDiagnostics() {
        queue.sync {
            pendingDiagnostics.removeAll()
            defaults.removeObject(forKey: "diagnostics")
        }
    }

    // MARK: - 演示数据

    public static func demoSnapshots(now: Date) -> [ProviderSnapshot] {
        [
            ProviderSnapshot(
                provider: .claude,
                planName: "Claude Max 5x",
                metrics: [
                    UsageMetric(id: "five_hour", label: "Current session", usedPercent: 34,
                                resetsAt: now.addingTimeInterval(2 * 3600 + 600)),
                    UsageMetric(id: "seven_day", label: "All models", usedPercent: 61,
                                resetsAt: now.addingTimeInterval(3 * 86400)),
                    UsageMetric(id: "weekly_scoped_fable", label: "Fable", usedPercent: 44,
                                resetsAt: now.addingTimeInterval(3 * 86400)),
                    // 未使用的指标：演示「用量为空默认隐藏」
                    UsageMetric(id: "seven_day_sonnet", label: "Sonnet", usedPercent: 0,
                                resetsAt: now.addingTimeInterval(3 * 86400)),
                ],
                fetchedAt: now,
                status: .ok,
                billingCycle: .monthly
            ),
            ProviderSnapshot(
                provider: .openai,
                planName: "ChatGPT Plus",
                metrics: [
                    UsageMetric(id: "primary", label: "Codex 5 小时窗口", usedPercent: 42,
                                resetsAt: now.addingTimeInterval(90 * 60)),
                    UsageMetric(id: "secondary", label: "Codex 7 天窗口", usedPercent: 18,
                                resetsAt: now.addingTimeInterval(5 * 86400)),
                ],
                fetchedAt: now,
                status: .ok,
                billingCycle: .monthly,
                openAIResetCredits: OpenAIResetCredits(
                    availableCount: 5, expiresAt: now.addingTimeInterval(25 * 86400),
                    usedCount: 5, windowStart: now.addingTimeInterval(-30 * 86400),
                    asOf: now, historyComplete: true,
                    availableExpirations: (25...29).map { now.addingTimeInterval(Double($0) * 86400) },
                    usedDates: (1...5).map { now.addingTimeInterval(-Double($0) * 86400) }
                )
            ),
            ProviderSnapshot(
                provider: .grok,
                planName: "SuperGrok Heavy",
                metrics: [
                    UsageMetric(id: "weekly", label: "本周限额", usedPercent: 3,
                                resetsAt: now.addingTimeInterval(5 * 86400),
                                detail: "已使用"),
                    UsageMetric(id: "weekly.2", label: "Grok Build", usedPercent: 2),
                    UsageMetric(id: "weekly.5", label: "Imagine", usedPercent: 1),
                ],
                fetchedAt: now,
                status: .ok,
                billingCycle: .monthly
            ),
            ProviderSnapshot(
                provider: .cursor,
                planName: "Cursor Ultra",
                metrics: [
                    UsageMetric(id: "cursor_models", label: "Cursor Models", usedPercent: 18,
                                resetsAt: now.addingTimeInterval(12 * 86400)),
                    UsageMetric(id: "other_models", label: "Other Models", usedPercent: 6,
                                resetsAt: now.addingTimeInterval(12 * 86400)),
                    UsageMetric(id: "grok_bot", label: "Grok Bot", usedPercent: 3,
                                resetsAt: now.addingTimeInterval(4 * 86400)),
                ],
                fetchedAt: now,
                status: .ok,
                billingCycle: .monthly
            ),
            ProviderSnapshot(
                provider: .deepseek,
                metrics: [
                    UsageMetric(id: "balance", label: "重置余额", amount: 54.48, currency: "CNY"),
                    UsageMetric(id: "total_spent", label: "累计消费金额", amount: 95.65, currency: "CNY"),
                ],
                fetchedAt: now,
                status: .ok,
                currency: "CNY",
                timeBreakdowns: [
                    UsageBreakdown(
                        id: "this_month", label: "本月",
                        cost: 12.4, requests: 86, tokens: 1_240_000,
                        series: [
                            UsagePoint(at: now.addingTimeInterval(-5 * 86400), value: 1.2),
                            UsagePoint(at: now.addingTimeInterval(-4 * 86400), value: 3.8),
                            UsagePoint(at: now.addingTimeInterval(-3 * 86400), value: 0.4),
                            UsagePoint(at: now.addingTimeInterval(-2 * 86400), value: 2.9),
                            UsagePoint(at: now.addingTimeInterval(-86400), value: 4.1),
                        ]
                    ),
                    UsageBreakdown(id: "today", label: "今天", cost: 0.8, requests: 6, tokens: 42_000),
                    UsageBreakdown(id: "yesterday", label: "昨天", cost: 4.1, requests: 18, tokens: 210_000),
                    UsageBreakdown(id: "last_7d", label: "近 7 天", cost: 12.4, requests: 86, tokens: 1_240_000),
                    UsageBreakdown(id: "last_30d", label: "近 30 天", cost: 38.2, requests: 240, tokens: 3_100_000),
                    UsageBreakdown(id: "last_month", label: "上月", cost: 41.9, requests: 190, tokens: 2_800_000),
                ],
                keyBreakdowns: [
                    UsageBreakdown(id: "key-translate", label: "翻译插件", cost: 4.2, requests: 36, tokens: 440_000,
                                   lastUsed: now.addingTimeInterval(-3600)),
                    UsageBreakdown(id: "key-desktop", label: "桌面工具", cost: 8.2, requests: 50, tokens: 800_000,
                                   lastUsed: now.addingTimeInterval(-2 * 86400)),
                    UsageBreakdown(id: "key-cli", label: "CLI", cost: 1.1, requests: 8, tokens: 90_000,
                                   lastUsed: now.addingTimeInterval(-5 * 86400)),
                    UsageBreakdown(id: "key-bot", label: "Bot", cost: 0.4, requests: 3, tokens: 20_000,
                                   lastUsed: now.addingTimeInterval(-12 * 86400)),
                    UsageBreakdown(id: "key-old", label: "旧项目", cost: 0.1, requests: 1, tokens: 4_000,
                                   lastUsed: now.addingTimeInterval(-30 * 86400)),
                    UsageBreakdown(id: "key-idle", label: "闲置", lastUsed: now.addingTimeInterval(-90 * 86400)),
                ]
            ),
            ProviderSnapshot(
                provider: .zhipu,
                planName: "Coding Plan Pro",
                metrics: [
                    UsageMetric(id: "five_hour", label: "每 5 小时", usedPercent: 1,
                                resetsAt: now.addingTimeInterval(3 * 3600 + 2700)),
                    UsageMetric(id: "seven_day", label: "近 7 天 Token",
                                detail: "6.87M tokens", amount: 6_871_706),
                    UsageMetric(id: "mcp_monthly", label: "MCP 每月额度", usedPercent: 0,
                                resetsAt: now.addingTimeInterval(8 * 86400)),
                    UsageMetric(id: "model_glm_5_2", label: "GLM-5.2",
                                detail: "6.62M tokens", amount: 6_622_107),
                ],
                fetchedAt: now,
                status: .ok,
                billingCycle: .yearly,
                planProductID: "product-733034"
            ),
            ProviderSnapshot(
                provider: .kimi,
                planName: "Kimi Code Allegretto",
                metrics: [
                    UsageMetric(id: "seven_day", label: "本周用量", usedPercent: 1,
                                remaining: 99, total: 100,
                                resetsAt: now.addingTimeInterval(5 * 86400 + 21 * 3600)),
                    UsageMetric(id: "five_hour", label: "频限明细", usedPercent: 0,
                                remaining: 100, total: 100,
                                resetsAt: now.addingTimeInterval(45 * 60)),
                ],
                fetchedAt: now,
                status: .ok,
                billingCycle: .yearly,
                planExpiresAt: now.addingTimeInterval(218 * 86400)
            ),
            ProviderSnapshot(
                provider: .minimax,
                planName: "Token Plan Max",
                metrics: [
                    UsageMetric(id: "five_hour", label: "5h 限额", usedPercent: 0,
                                resetsAt: now.addingTimeInterval(4 * 3600 + 17 * 60), pinned: true),
                    UsageMetric(id: "seven_day", label: "周限额", usedPercent: 0,
                                detail: "无限制", pinned: true),
                    UsageMetric(id: "video_gift", label: "视频赠送", usedPercent: 0,
                                remaining: 3, total: 3,
                                resetsAt: now.addingTimeInterval(23 * 3600 + 17 * 60), pinned: true),
                    UsageMetric(id: "credits", label: "积分余额", usedPercent: 0,
                                remaining: 35000, total: 35000),
                ],
                fetchedAt: now,
                status: .ok,
                billingCycle: .yearly
            ),
            ProviderSnapshot(
                provider: .jimeng,
                metrics: [
                    UsageMetric(id: "remaining", label: "剩余积分", amount: 179, pinned: true),
                    UsageMetric(id: "subscription", label: "订阅积分", amount: 0, pinned: true),
                    UsageMetric(id: "recharge", label: "充值积分", amount: 149, pinned: true),
                    UsageMetric(id: "gift", label: "赠送积分", amount: 30, pinned: true),
                ],
                fetchedAt: now,
                status: .ok,
                creditHistory: [
                    CreditLedgerEntry(id: "d1", title: "每日免费积分", amount: 30, historyType: 1,
                                     createdAt: now.addingTimeInterval(-2 * 3600)),
                    CreditLedgerEntry(id: "d2", title: "积分到期清零", amount: 80, historyType: 2,
                                     createdAt: now.addingTimeInterval(-11 * 86400)),
                    CreditLedgerEntry(id: "d3", title: "每日免费积分", amount: 80, historyType: 1,
                                     createdAt: now.addingTimeInterval(-12 * 86400)),
                    CreditLedgerEntry(id: "d4", title: "Seedance2.5", amount: 160, historyType: 2,
                                     createdAt: now.addingTimeInterval(-13 * 86400)),
                    CreditLedgerEntry(id: "d5", title: "失败返还", amount: 496, historyType: 1,
                                     createdAt: now.addingTimeInterval(-14 * 86400)),
                    CreditLedgerEntry(id: "d6", title: "Seedance2.5", amount: 544, historyType: 2,
                                     createdAt: now.addingTimeInterval(-14 * 86400 + 600)),
                ]
            ),
            ProviderSnapshot(
                provider: .opencode,
                planName: "OpenCode Go",
                metrics: [
                    UsageMetric(id: "weekly", label: "每周窗口", usedPercent: 40,
                                resetsAt: now.addingTimeInterval(3 * 86400 + 12 * 3600), pinned: true),
                    UsageMetric(id: "five_hour", label: "5 小时窗口", usedPercent: 12,
                                resetsAt: now.addingTimeInterval(2 * 3600 + 43 * 60)),
                    UsageMetric(id: "monthly", label: "每月窗口", usedPercent: 8,
                                resetsAt: now.addingTimeInterval(22 * 86400)),
                    UsageMetric(id: "balance", label: "Zen 余额", amount: 12.35, currency: "USD", pinned: true),
                ],
                fetchedAt: now,
                status: .ok,
                billingCycle: .monthly
            ),
            ProviderSnapshot(
                provider: .longcat, planName: "LongCat 加油包",
                metrics: [UsageMetric(id: "token_pack", label: "Token 包", usedPercent: 37,
                                      detail: "已用 3.7M / 10M tokens", pinned: true)],
                fetchedAt: now, status: .ok
            ),
            ProviderSnapshot(
                provider: .mimo, planName: "MiMo Token Plan",
                metrics: [
                    UsageMetric(id: "monthly", label: "月度额度", usedPercent: 52,
                                resetsAt: now.addingTimeInterval(11 * 86400), pinned: true),
                    UsageMetric(id: "balance", label: "余额", amount: 23.5, currency: "CNY", pinned: true),
                ],
                fetchedAt: now, status: .ok
            ),
            ProviderSnapshot(
                provider: .qoder, planName: "Qoder Pro",
                metrics: [UsageMetric(id: "credits", label: "Credits", usedPercent: 64,
                                      resetsAt: now.addingTimeInterval(6 * 86400), pinned: true)],
                fetchedAt: now, status: .ok
            ),
            ProviderSnapshot(
                provider: .perplexity, planName: "Perplexity Pro",
                metrics: [UsageMetric(id: "recurring", label: "本月额度", usedPercent: 28,
                                      resetsAt: now.addingTimeInterval(14 * 86400), pinned: true)],
                fetchedAt: now, status: .ok, billingCycle: .monthly
            ),
            ProviderSnapshot(
                provider: .augment, planName: "Augment Developer",
                metrics: [UsageMetric(id: "credits", label: "Credits", usedPercent: 71,
                                      resetsAt: now.addingTimeInterval(9 * 86400), pinned: true)],
                fetchedAt: now, status: .ok
            ),
            ProviderSnapshot(
                provider: .abacus, planName: "ChatLLM",
                metrics: [UsageMetric(id: "compute_points", label: "Compute points", usedPercent: 45,
                                      resetsAt: now.addingTimeInterval(20 * 86400), pinned: true)],
                fetchedAt: now, status: .ok
            ),
            ProviderSnapshot(
                provider: .t3chat, planName: "T3 Chat Pro",
                metrics: [
                    UsageMetric(id: "four_hour", label: "4 小时窗口", usedPercent: 15,
                                resetsAt: now.addingTimeInterval(2 * 3600), pinned: true),
                    UsageMetric(id: "monthly", label: "本月", usedPercent: 33,
                                resetsAt: now.addingTimeInterval(17 * 86400)),
                ],
                fetchedAt: now, status: .ok, billingCycle: .monthly
            ),
            ProviderSnapshot(
                provider: .notion, planName: "Notion Business",
                metrics: [
                    UsageMetric(id: "window", label: "6 小时窗口", usedPercent: 42,
                                resetsAt: now.addingTimeInterval(3 * 3600 + 30 * 60), pinned: true),
                    UsageMetric(id: "billing_period", label: "账期额度", usedPercent: 18,
                                resetsAt: now.addingTimeInterval(21 * 86400)),
                ],
                fetchedAt: now, status: .ok
            ),
            ProviderSnapshot(
                provider: .ollama, planName: "Ollama Pro",
                metrics: [
                    UsageMetric(id: "five_hour", label: "Session usage", usedPercent: 22,
                                resetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60), pinned: true),
                    UsageMetric(id: "weekly", label: "Weekly usage", usedPercent: 48,
                                resetsAt: now.addingTimeInterval(4 * 86400)),
                ],
                fetchedAt: now, status: .ok, billingCycle: .monthly
            ),
            ProviderSnapshot(
                provider: .stepfun, planName: "StepFun Pro",
                metrics: [
                    UsageMetric(id: "five_hour", label: "5 小时窗口", usedPercent: 31,
                                resetsAt: now.addingTimeInterval(3 * 3600), pinned: true),
                    UsageMetric(id: "weekly", label: "每周窗口", usedPercent: 57,
                                resetsAt: now.addingTimeInterval(5 * 86400)),
                ],
                fetchedAt: now, status: .ok
            ),
            ProviderSnapshot(
                provider: .copilot, planName: "Copilot Pro",
                metrics: [UsageMetric(id: "copilot", label: "Copilot", usedPercent: 25,
                                      remaining: 75, total: 100, pinned: true)],
                fetchedAt: now, status: .ok
            ),
            ProviderSnapshot(
                provider: .gemini, planName: "Gemini",
                metrics: [UsageMetric(id: "gemini-2.5-pro", label: "Gemini 2.5 Pro", usedPercent: 40,
                                      resetsAt: now.addingTimeInterval(2 * 86400), pinned: true)],
                fetchedAt: now, status: .ok
            ),
            ProviderSnapshot(
                provider: .antigravity, planName: "Antigravity",
                metrics: [UsageMetric(id: "weekly", label: "Weekly", usedPercent: 55,
                                      resetsAt: now.addingTimeInterval(4 * 86400), pinned: true)],
                fetchedAt: now, status: .ok
            ),
            ProviderSnapshot(
                provider: .kiro, planName: "Kiro",
                metrics: [UsageMetric(id: "plan", label: "Plan", usedPercent: 20,
                                      remaining: 40, total: 50,
                                      resetsAt: now.addingTimeInterval(10 * 86400), pinned: true)],
                fetchedAt: now, status: .ok
            ),
            ProviderSnapshot(
                provider: .minimaxGlobal, planName: "Token Plan Plus",
                metrics: [
                    UsageMetric(id: "five_hour", label: "5 小时窗口", usedPercent: 12,
                                resetsAt: now.addingTimeInterval(4 * 3600), pinned: true, displayValue: "12%/100%"),
                    UsageMetric(id: "weekly", label: "每周窗口", usedPercent: 40,
                                resetsAt: now.addingTimeInterval(3 * 86400)),
                ],
                fetchedAt: now, status: .ok, billingCycle: .monthly
            ),
        ]
    }
}
