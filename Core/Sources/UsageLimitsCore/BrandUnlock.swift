import Foundation

/// 隐私卡片里的无反馈点击目标。
public enum BrandUnlockTap: Equatable, Sendable {
    case cookie
    case shield
    case webkit
    case version
}

/// 组合键：Cookie×2 → 版本×1 → 盾牌×2 → 版本×1 → WebKit×2 → 版本×1，整段再重复一遍。
public enum BrandUnlockCombo {
    public static let phrase: [BrandUnlockTap] = [
        .cookie, .cookie, .version,
        .shield, .shield, .version,
        .webkit, .webkit, .version,
    ]

    public static var sequence: [BrandUnlockTap] { phrase + phrase }

    /// 推进进度；点错则若该点是开头则回到 1，否则归零。完成时返回 sequence.count。
    public static func advance(progress: Int, tap: BrandUnlockTap) -> Int {
        let seq = sequence
        guard !seq.isEmpty else { return 0 }
        if progress >= 0, progress < seq.count, seq[progress] == tap {
            return progress + 1
        }
        return seq[0] == tap ? 1 : 0
    }

    public static func isComplete(_ progress: Int) -> Bool {
        progress >= sequence.count
    }

    /// 隐私正文里 Cookie / WebKit 的命中（不区分大小写；cookies 算 Cookie）。
    public static func hotspot(in text: String, utf16Index: Int) -> BrandUnlockTap? {
        let ns = text as NSString
        guard utf16Index >= 0, utf16Index < ns.length else { return nil }
        let tokens: [(String, BrandUnlockTap)] = [
            ("cookies", .cookie),
            ("cookie", .cookie),
            ("webkit", .webkit),
        ]
        for (token, tap) in tokens {
            var search = NSRange(location: 0, length: ns.length)
            while search.location < ns.length {
                let found = ns.range(of: token, options: [.caseInsensitive], range: search)
                if found.location == NSNotFound { break }
                if NSLocationInRange(utf16Index, found) { return tap }
                let next = found.location + found.length
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        return nil
    }
}

/// 组合键解锁只活在当前进程：重启即收回开关；常驻满 30 分钟也收回。
public enum BrandUnlockSession {
    public static let visibleDuration: TimeInterval = 30 * 60

    /// `unlockedAt == nil` 视为从未解锁或进程已重启。
    public static func isVisible(unlockedAt: Date?, now: Date) -> Bool {
        guard let unlockedAt else { return false }
        return now.timeIntervalSince(unlockedAt) < visibleDuration
    }

    public static func remainingVisible(unlockedAt: Date, now: Date) -> TimeInterval {
        max(0, visibleDuration - now.timeIntervalSince(unlockedAt))
    }

    /// 开关收回或下次再解锁：清掉隐藏二维码，分享图恢复 logo / 二维码 / 扫码提示；其它分享选项不动。
    public static func shareOptionsAfterHidingToggle(_ options: ShareComposeOptions) -> ShareComposeOptions {
        var next = options
        next.hideBrandRow = false
        return next
    }
}
