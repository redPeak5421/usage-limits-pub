import XCTest
@testable import UsageLimitsCore

/// 分享预览切开关时的滚动锚点：正在看的那张卡必须留在原处。
final class SharePreviewScrollTests: XCTestCase {

    private func meter(_ label: String, caption: Bool) -> ShareMeter {
        ShareMeter(
            label: label,
            valueText: "42%",
            usedPercent: 42,
            isUnused: false,
            detailText: caption ? "已用 4.2 / 10" : nil,
            resetText: caption ? "重置：3 天后" : nil
        )
    }

    private func section(_ name: String, caption: Bool) -> ShareCardModel.Section {
        ShareCardModel.Section(
            provider: .claude,
            providerName: name,
            planName: "Max",
            meters: [meter("窗口一", caption: caption), meter("窗口二", caption: caption)],
            updateTime: "更新于 02:22",
            includesLogo: true,
            tint: nil
        )
    }

    private func model(_ names: [String], caption: Bool) -> ShareCardModel {
        ShareCardModel(
            title: "Usage Limits",
            appStoreURL: ShareChrome.appStoreURL.absoluteString,
            includesAppIcon: false,
            includesQR: false,
            includesSubtitle: false,
            brandAtBottom: false,
            options: ShareComposeOptions(),
            sections: names.map { section($0, caption: caption) },
            topSafeReserve: ShareImageComposer.topSafeReserve,
            visibleTexts: []
        )
    }

    private let names = (1...12).map { "服务商 \($0)" }
    private let viewport: CGFloat = 600

    func testSectionTopsStayInStepWithCanvasHeight() {
        let m = model(names, caption: true)
        let tops = ShareLayout.sectionTops(of: m)
        XCTAssertEqual(tops.count, m.sections.count)
        let bottom = tops[tops.count - 1] + ShareLayout.cardHeight(m.sections[m.sections.count - 1])
        XCTAssertEqual(
            bottom + ShareLayout.padding + ShareLayout.margin,
            ShareLayout.canvasHeight(of: m),
            accuracy: 0.01,
            "卡片顶边表与画布总高必须出自同一套算式"
        )
    }

    func testAnchorPicksCardUnderViewportCenter() throws {
        let m = model(names, caption: true)
        let tops = ShareLayout.sectionTops(of: m)
        // 视口中心刻意落在第 5 张卡的中段。
        let center = tops[4] + ShareLayout.cardHeight(m.sections[4]) / 2
        let offset = center - viewport / 2
        let anchor = try XCTUnwrap(
            SharePreviewScroll.anchor(in: m, offset: offset, viewportHeight: viewport)
        )
        XCTAssertEqual(anchor.index, 4)
        XCTAssertEqual(anchor.key, "服务商 5")
        XCTAssertEqual(anchor.topInViewport, tops[4] - offset, accuracy: 0.01)
    }

    func testCollapsingDetailsKeepsAnchoredCardOnScreen() throws {
        let expanded = model(names, caption: true)
        let collapsed = model(names, caption: false)
        let tops = ShareLayout.sectionTops(of: expanded)
        let offset = tops[7] - 120
        let anchor = try XCTUnwrap(
            SharePreviewScroll.anchor(in: expanded, offset: offset, viewportHeight: viewport)
        )
        XCTAssertEqual(anchor.key, "服务商 8", "锚点应落在视口中心那张卡上")

        let restored = SharePreviewScroll.restoredOffset(
            for: anchor, in: collapsed, viewportHeight: viewport
        )
        let newTops = ShareLayout.sectionTops(of: collapsed)
        XCTAssertEqual(
            newTops[7] - restored, anchor.topInViewport, accuracy: 0.01,
            "收起明细后锚点卡片相对视口顶边的位置不变"
        )
        XCTAssertLessThan(restored, offset, "上方卡片变矮，偏移必须跟着回收")
    }

    func testRestoreFindsCardByNameWhenIndexMoved() throws {
        let before = model(names, caption: true)
        let tops = ShareLayout.sectionTops(of: before)
        let offset = tops[6]
        let anchor = try XCTUnwrap(
            SharePreviewScroll.anchor(in: before, offset: offset, viewportHeight: viewport)
        )
        XCTAssertEqual(anchor.index, 7)
        // 「编辑」删掉前两张卡，锚点卡片下标从 7 变成 5。
        let after = model(Array(names.dropFirst(2)), caption: true)
        let restored = SharePreviewScroll.restoredOffset(
            for: anchor, in: after, viewportHeight: viewport
        )
        let newIndex = try XCTUnwrap(after.sections.firstIndex { $0.providerName == anchor.key })
        XCTAssertEqual(newIndex, 5, "按名字找回同一张卡，不认旧下标")
        let newTops = ShareLayout.sectionTops(of: after)
        XCTAssertEqual(newTops[newIndex] - restored, anchor.topInViewport, accuracy: 0.01)
    }

    func testRestoreClampsIntoScrollableRange() throws {
        let many = model(names, caption: true)
        let tops = ShareLayout.sectionTops(of: many)
        let anchor = try XCTUnwrap(
            SharePreviewScroll.anchor(
                in: many, offset: tops[11] - 60, viewportHeight: viewport
            )
        )
        // 只剩一张卡，画布比视口还矮：偏移必须夹回 0，不能露出空白。
        let single = model([names[11]], caption: false)
        let restored = SharePreviewScroll.restoredOffset(
            for: anchor, in: single, viewportHeight: viewport
        )
        XCTAssertEqual(restored, 0, accuracy: 0.01)
        XCTAssertLessThan(ShareLayout.canvasHeight(of: single), viewport)
    }

    /// 停在最顶上时，取锚点再还原必须回到原处；否则每次切开关都凭空滚掉一圈留白。
    func testTopOfListRoundTripsThroughSlack() throws {
        let m = model(names, caption: true)
        let slack: CGFloat = 12
        let offset = -slack
        // 视口小到中心还落在首卡上，这时理想偏移是负的，正好检验下界。
        let shortViewport: CGFloat = 300
        let anchor = try XCTUnwrap(
            SharePreviewScroll.anchor(in: m, offset: offset, viewportHeight: shortViewport)
        )
        XCTAssertEqual(anchor.index, 0)
        let restored = SharePreviewScroll.restoredOffset(
            for: anchor, in: m, viewportHeight: shortViewport, slack: slack
        )
        XCTAssertEqual(restored, offset, accuracy: 0.01)
        XCTAssertEqual(
            SharePreviewScroll.restoredOffset(for: anchor, in: m, viewportHeight: shortViewport),
            0, accuracy: 0.01,
            "不传 slack 时仍按老口径夹在 0"
        )
    }

    func testAnchorIsNilWithoutSections() {
        let empty = model([], caption: true)
        XCTAssertNil(SharePreviewScroll.anchor(in: empty, offset: 0, viewportHeight: viewport))
        XCTAssertEqual(
            SharePreviewScroll.restoredOffset(for: nil, in: empty, viewportHeight: viewport), 0
        )
    }
}
