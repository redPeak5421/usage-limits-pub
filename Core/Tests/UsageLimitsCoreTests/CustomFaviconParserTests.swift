import XCTest
@testable import UsageLimitsCore

final class CustomFaviconParserTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "html", subdirectory: "Fixtures"),
            "缺少 fixture: \(name)"
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var base: URL { URL(string: "https://dragoncode.codes/")! }

    func testHomepageURLUsesOriginNotUsagePath() {
        let usage = URL(string: "https://dragoncode.codes/v1/usage")!
        XCTAssertEqual(
            CustomFaviconParser.homepageURL(from: usage)?.absoluteString,
            "https://dragoncode.codes/"
        )
        let withPort = URL(string: "https://example.com:8443/api/usage")!
        XCTAssertEqual(
            CustomFaviconParser.homepageURL(from: withPort)?.absoluteString,
            "https://example.com:8443/"
        )
        XCTAssertNil(CustomFaviconParser.homepageURL(from: URL(string: "http://dragoncode.codes/v1/usage")!))
    }

    func testFixturePrefersSVGOverPNG() throws {
        let html = try fixture("favicon_svg_preferred")
        let href = CustomFaviconParser.pickBestHref(html: html, baseURL: base)
        XCTAssertEqual(href?.absoluteString, "https://dragoncode.codes/favicon.svg")
    }

    func testFixturePicksPNGClosestTo64InRange() throws {
        let html = try fixture("favicon_png_sizes")
        let href = CustomFaviconParser.pickBestHref(html: html, baseURL: base)
        XCTAssertEqual(href?.absoluteString, "https://dragoncode.codes/favicon-48.png")
    }

    func testSuffixInferencePrefersSVG() throws {
        let html = try fixture("favicon_suffix_only")
        let href = CustomFaviconParser.pickBestHref(html: html, baseURL: base)
        XCTAssertEqual(href?.absoluteString, "https://dragoncode.codes/icons/mark.svg")
    }

    func testOutOfRangeSizesPickClosestTo64() {
        let html = """
        <link rel="icon" type="image/png" sizes="16x16" href="/16.png">
        <link rel="icon" type="image/png" sizes="256x256" href="/256.png">
        """
        let href = CustomFaviconParser.pickBestHref(html: html, baseURL: base)
        XCTAssertEqual(href?.path, "/16.png")
    }

    func testEqualDistanceInRangePrefersFirstClosest() {
        let html = """
        <link rel="icon" type="image/png" sizes="32x32" href="/32.png">
        <link rel="icon" type="image/png" sizes="64x64" href="/64.png">
        <link rel="icon" type="image/png" sizes="128x128" href="/128.png">
        """
        let href = CustomFaviconParser.pickBestHref(html: html, baseURL: base)
        XCTAssertEqual(href?.path, "/64.png")
    }

    func testNoIconLinksReturnsNil() {
        let html = #"<link rel="stylesheet" href="/app.css"><title>x</title>"#
        XCTAssertNil(CustomFaviconParser.pickBestHref(html: html, baseURL: base))
    }

    func testAppleTouchIconCountsAsIcon() {
        let html = #"<link rel="apple-touch-icon" sizes="120x120" href="/touch.png">"#
        XCTAssertEqual(
            CustomFaviconParser.pickBestHref(html: html, baseURL: base)?.path,
            "/touch.png"
        )
    }

    func testRelativeAndProtocolRelativeHref() {
        XCTAssertEqual(
            CustomFaviconParser.resolve(href: "/favicon.svg", base: base)?.absoluteString,
            "https://dragoncode.codes/favicon.svg"
        )
        XCTAssertNil(CustomFaviconParser.resolve(href: "http://evil.example/x.png", base: base))
        XCTAssertEqual(
            CustomFaviconParser.resolve(href: "https://cdn.example.com/a.png", base: base)?.host,
            "cdn.example.com"
        )
    }

    func testLooksLikeImageSniffsMagicAndRejectsJSON() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(repeating: 0, count: 8))
        XCTAssertTrue(CustomFaviconParser.looksLikeImage(png))
        XCTAssertTrue(CustomFaviconParser.looksLikeImage(Data("<svg xmlns='http://www.w3.org/2000/svg'></svg>".utf8)))
        XCTAssertFalse(CustomFaviconParser.looksLikeImage(Data(#"{"used":1}"#.utf8)))
        XCTAssertFalse(CustomFaviconParser.looksLikeImage(Data()))
        XCTAssertEqual(CustomFaviconParser.suggestedExtension(for: png), "png")
    }

    func testClipsHugeHTMLBeforeParse() {
        var html = String(repeating: " ", count: CustomFaviconParser.maxHTMLBytes + 100)
        html += #"<link rel="icon" href="/late.png">"#
        XCTAssertNil(CustomFaviconParser.pickBestHref(html: html, baseURL: base))
    }
}
