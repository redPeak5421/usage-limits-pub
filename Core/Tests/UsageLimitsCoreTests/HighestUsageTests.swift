import XCTest
@testable import UsageLimitsCore

final class HighestUsageTests: XCTestCase {
    private func snap(_ provider: ProviderID, _ percents: [Double?], status: SnapshotStatus = .ok) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            metrics: percents.enumerated().map { i, p in UsageMetric(id: "m\(i)", label: "m\(i)", usedPercent: p, pinned: true) },
            fetchedAt: Date(), status: status
        )
    }

    func testPicksHighestUsedPercentAcrossMetrics() {
        let items: [(ProviderID, ProviderSnapshot)] = [
            (.claude, snap(.claude, [20, 65])),
            (.openai, snap(.openai, [70])),
            (.grok, snap(.grok, [10, 30])),
        ]
        XCTAssertEqual(HighestUsagePicker.pick(items, snapshot: { $0.1 })?.0, .openai)
    }

    func testFullyUsedIsDeprioritizedUnlessEverythingIsFull() {
        let items: [(ProviderID, ProviderSnapshot)] = [
            (.claude, snap(.claude, [100])),
            (.openai, snap(.openai, [40])),
        ]
        XCTAssertEqual(HighestUsagePicker.pick(items, snapshot: { $0.1 })?.0, .openai)
        let allFull: [(ProviderID, ProviderSnapshot)] = [
            (.claude, snap(.claude, [100])),
            (.openai, snap(.openai, [100])),
        ]
        XCTAssertEqual(HighestUsagePicker.pick(allFull, snapshot: { $0.1 })?.0, .claude)
    }

    func testSkipsNotLoggedInAndAmountOnlySnapshots() {
        let items: [(ProviderID, ProviderSnapshot)] = [
            (.claude, snap(.claude, [90], status: .needsLogin)),
            (.deepseek, ProviderSnapshot(provider: .deepseek, metrics: [UsageMetric(id: "balance", label: "余额", amount: 12)], fetchedAt: Date(), status: .ok)),
            (.openai, snap(.openai, [5])),
        ]
        XCTAssertEqual(HighestUsagePicker.pick(items, snapshot: { $0.1 })?.0, .openai)
        XCTAssertNil(HighestUsagePicker.pick([items[0], items[1]], snapshot: { $0.1 }))
    }

    func testIndependentOfDisplayMode() {
        // 选择逻辑不看展示口径：按剩余显示时，仍应选已用最高（剩余最少）的那家。
        let items: [(ProviderID, ProviderSnapshot)] = [(.claude, snap(.claude, [30])), (.openai, snap(.openai, [80]))]
        let picked = HighestUsagePicker.pick(items, snapshot: { $0.1 })?.0
        XCTAssertEqual(picked, .openai)
        XCTAssertEqual(UsagePresentation.barPercent(used: 80, mode: .remaining), 20)
    }

    func testScoreReadsAllMetricsWhenActiveAmountWouldHideZeroPercent() {
        let snap = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "balance", label: "Balance", amount: 12),
                UsageMetric(id: "window", label: "Window", usedPercent: 0),
            ],
            fetchedAt: Date(), status: .ok
        )
        XCTAssertEqual(HighestUsagePicker.score(snap), 0)
    }

    func testScoreFiltersNonFinitePercentages() {
        XCTAssertEqual(HighestUsagePicker.score(snap(.claude, [.nan, .infinity, 42])), 42)
        XCTAssertNil(HighestUsagePicker.score(snap(.claude, [.nan, .infinity, -.infinity])))
    }

    func testScoreRejectsFinitePercentagesOutsideZeroThroughOneHundred() {
        XCTAssertNil(HighestUsagePicker.score(snap(.claude, [-1, 101, .greatestFiniteMagnitude])))
        XCTAssertEqual(HighestUsagePicker.score(snap(.claude, [0, 100])), 100)
    }

    func testExplicitTieAndZeroPercentKeepInputOrder() {
        let tied: [(ProviderID, ProviderSnapshot)] = [
            (.claude, snap(.claude, [40, 5])),
            (.openai, snap(.openai, [40])),
        ]
        XCTAssertEqual(HighestUsagePicker.pick(tied, snapshot: { $0.1 })?.0, .claude)

        let zeroWithAmount = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "balance", label: "Balance", amount: 12),
                UsageMetric(id: "window", label: "Window", usedPercent: 0),
            ],
            fetchedAt: Date(), status: .ok
        )
        let zeros: [(ProviderID, ProviderSnapshot)] = [
            (.claude, zeroWithAmount),
            (.openai, snap(.openai, [0])),
        ]
        XCTAssertEqual(HighestUsagePicker.pick(zeros, snapshot: { $0.1 })?.0, .claude)
    }

    func testScoreUsesCustomPercentRoleAndShareWithoutUsedPercent() {
        let percentOnly = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(
                    id: "ratio", label: "Usage", amount: 67, pinned: true,
                    kind: CustomFieldRole.percent.rawValue
                )
            ],
            fetchedAt: Date(), status: .ok, isCustom: true
        )
        XCTAssertEqual(HighestUsagePicker.score(percentOnly), 67)

        let shareOnly = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "used", label: "Tokens", amount: 80, pinned: true, kind: CustomFieldRole.used.rawValue),
                UsageMetric(id: "left", label: "Left", amount: 20, pinned: true, kind: CustomFieldRole.remaining.rawValue),
            ],
            fetchedAt: Date(), status: .ok, isCustom: true
        )
        XCTAssertEqual(HighestUsagePicker.score(shareOnly) ?? -1, 80, accuracy: 0.05)
        XCTAssertNil(
            HighestUsagePicker.score(ProviderSnapshot(
                provider: .deepseek,
                metrics: [UsageMetric(id: "balance", label: "余额", amount: 12)],
                fetchedAt: Date(), status: .ok
            )),
            "只有金额、没有占比角色时仍不得进最高用量"
        )
    }

    func testScoreUsesGaugeWhenCustomHasLimitButNoUsedPercent() {
        let remainingLimit = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "left", label: "Left", amount: 25, pinned: true, kind: CustomFieldRole.remaining.rawValue),
                UsageMetric(id: "cap", label: "Cap", amount: 100, pinned: true, kind: CustomFieldRole.limit.rawValue),
            ],
            fetchedAt: Date(), status: .ok, isCustom: true
        )
        XCTAssertEqual(HighestUsagePicker.score(remainingLimit) ?? -1, 75, accuracy: 0.05)

        let usedLimit = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "used", label: "Used", amount: 80, pinned: true, kind: CustomFieldRole.used.rawValue),
                UsageMetric(id: "cap", label: "Cap", amount: 100, pinned: true, kind: CustomFieldRole.limit.rawValue),
            ],
            fetchedAt: Date(), status: .ok, isCustom: true
        )
        XCTAssertEqual(HighestUsagePicker.score(usedLimit) ?? -1, 80, accuracy: 0.05)
    }

    func testScoreUsesLimitGaugeWhenUsedRemainingAndLimitAllPresent() {
        let triple = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "used", label: "Used", amount: 80, pinned: true, kind: CustomFieldRole.used.rawValue),
                UsageMetric(id: "left", label: "Left", amount: 20, pinned: true, kind: CustomFieldRole.remaining.rawValue),
                UsageMetric(id: "cap", label: "Cap", amount: 200, pinned: true, kind: CustomFieldRole.limit.rawValue),
            ],
            fetchedAt: Date(), status: .ok, isCustom: true
        )
        XCTAssertEqual(
            HighestUsagePicker.score(triple) ?? -1, 40, accuracy: 0.05,
            "used+remaining+limit 必须跟圆环同一 riskPercent，不得先用 share 80%"
        )
    }

    func testScoreIgnoresMixedUnitCrofCreditsAndUsesRequestPair() {
        XCTAssertNil(
            HighestUsagePicker.score(ProviderSnapshot(
                provider: .claude,
                metrics: [
                    UsageMetric(id: "credits", label: "积分", amount: 12.5, currency: "USD", pinned: true, kind: "remaining"),
                    UsageMetric(id: "requests_plan", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
                ],
                fetchedAt: Date(), status: .ok, isCustom: true
            )),
            "美元积分 + 请求上限不得当成 98.75% 进最高用量"
        )
        let crof = ProviderSnapshot(
            provider: .claude,
            metrics: [
                UsageMetric(id: "credits", label: "积分", amount: 12.5, currency: "USD", pinned: true, kind: "remaining"),
                UsageMetric(id: "requests_plan", label: "请求上限", amount: 1000, pinned: true, kind: "limit"),
                UsageMetric(id: "usable_requests", label: "剩余请求", amount: 250, pinned: true, kind: "remaining"),
            ],
            fetchedAt: Date(), status: .ok, isCustom: true
        )
        XCTAssertEqual(HighestUsagePicker.score(crof) ?? -1, 75, accuracy: 0.05)
    }
}
