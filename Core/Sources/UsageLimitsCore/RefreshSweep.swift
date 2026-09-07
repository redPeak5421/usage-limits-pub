import Foundation

/// 后台一轮探针的排队：按上次成功快照的时间从旧到新。
/// 同样陈旧时附加内置账号优先于主号，避免 20s 预算被主号吃完后附加饿死。
public enum RefreshSweep {
    public enum Target: Equatable, Sendable {
        case primary(ProviderID)
        case extra(UUID)
        case custom(UUID)
    }

    public static func order(
        primaries: [(id: ProviderID, fetchedAt: Date)],
        extras: [(id: UUID, fetchedAt: Date)],
        customs: [(id: UUID, fetchedAt: Date)]
    ) -> [Target] {
        var items: [(Date, Int, String, Target)] = []
        for item in primaries {
            items.append((item.fetchedAt, 1, item.id.rawValue, .primary(item.id)))
        }
        for item in extras {
            items.append((item.fetchedAt, 0, item.id.uuidString, .extra(item.id)))
        }
        for item in customs {
            items.append((item.fetchedAt, 2, item.id.uuidString, .custom(item.id)))
        }
        return items.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }.map(\.3)
    }
}
