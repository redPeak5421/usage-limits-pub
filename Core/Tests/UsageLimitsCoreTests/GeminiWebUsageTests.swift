import XCTest
@testable import UsageLimitsCore
#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

final class GeminiWebUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_949_202)
    private func response(_ payload: String, rpc: String = "jSf9Qc") -> String {
        let data = try! JSONSerialization.data(withJSONObject: [["wrb.fr", rpc, payload]])
        return ")]}'\n\n\(data.count)\n" + String(decoding: data, as: UTF8.self) + "\n"
    }
    func testCapturedUsageResponse() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "gemini_web_usage", withExtension: "txt", subdirectory: "Fixtures"))
        let body = try String(contentsOf: url, encoding: .utf8)
        let snap = GeminiParser.parse(results: ["quota": ProbeResult(status: 200, body: body)], now: now)
        XCTAssertEqual(snap.status, .ok)
        XCTAssertEqual(snap.planName, "Google AI Pro")
        XCTAssertEqual(snap.metrics.map(\.id), ["five_hour", "weekly"])
        XCTAssertEqual(snap.metrics.map(\.usedPercent), [0, 0])
        XCTAssertEqual(snap.metrics.first?.resetsAt?.timeIntervalSince1970 ?? 0, 1_788_967_802.079295, accuracy: 0.001)
        XCTAssertEqual(snap.metrics.last?.resetsAt?.timeIntervalSince1970 ?? 0, 1_789_554_602.079296, accuracy: 0.001)
    }
    func testUsedFractionNotRemainingOrCapacity() {
        let snap = GeminiParser.parse(results: ["quota": ProbeResult(status: 200, body: response("[2,[[48384,0.25,2,[[1789554602]]],[2400,0.8,1,[[1788967802]]]],false]"))], now: now)
        XCTAssertEqual(snap.metrics.map(\.usedPercent), [80, 25])
        XCTAssertTrue(snap.metrics.allSatisfy { $0.total == nil && $0.remaining == nil })
    }
    func testMalformedAndUnrelatedRPCNeverConfirmLogin() {
        for payload in ["[]", "[2,[]]", "[2,[[2400,null,1]]]", "[2,[[2400,true,1]]]", "[2,[[2400,1.5,1]]]", "[2,[[2400,0,99]]]"] {
            let snap = GeminiParser.parse(results: ["quota": ProbeResult(status: 200, body: response(payload))], now: now)
            XCTAssertFalse(LoginProbePolicy.isAuthenticated(snap), payload)
        }
        let snap = GeminiParser.parse(results: ["quota": ProbeResult(status: 200, body: response("[2,[[2400,0,1]]]", rpc: "unrelated"))], now: now)
        XCTAssertFalse(snap.status.isOK)
    }
    func testMalformedWindowDoesNotDiscardValidWindow() {
        let snap = GeminiParser.parse(results: ["quota": ProbeResult(status: 200, body: response("[2,[[2400,null,1],[48384,0.4,2,[[1789554602]]]]]"))], now: now)
        XCTAssertEqual(snap.metrics.map(\.id), ["weekly"])
        XCTAssertEqual(snap.metrics.first?.usedPercent, 40)
    }
    func testProbeUsesObservedRPCAndAccountRoute() throws {
        let body = GeminiProbeScript.body
        XCTAssertTrue(body.contains("jSf9Qc"))
        XCTAssertTrue(body.contains("/_/BardChatUi/data/batchexecute"))
        XCTAssertTrue(body.contains("SNlM0e"))
        XCTAssertTrue(body.contains("geminiUseCurrentAccount"))
        XCTAssertFalse(body.contains("/u/3/"))
        XCTAssertFalse(body.contains("cloudcode-pa"))
        XCTAssertFalse(body.contains("eval("))
    }

    func testRPCErrorsPreserveLastGood() {
        let good = GeminiParser.parse(results: ["quota": ProbeResult(status: 200, body: response("[2,[[2400,0.5,1]]]"))], now: now)
        let results = ["quota": ProbeResult(status: 200, body: response("[]"))]
        let bad = GeminiParser.parse(results: results, now: now)
        XCTAssertFalse(RefreshPolicy.shouldCommit(old: good, new: bad, results: results))
    }

    #if canImport(JavaScriptCore)
    func testProductionProbePreservesSelectedRouteAndRedactsBootstrap() throws {
        for live in [true, false] {
            let context = try executeScript(live: live)
            let requests = try XCTUnwrap(context.objectForKeyedSubscript("requests")?.toArray() as? [[String: Any]])
            XCTAssertEqual(requests.count, 2, "只允许会话引导请求和单条 usage RPC，不采集其他网络记录")
            let route = live ? "/u/3" : "/u/7"
            XCTAssertEqual(requests[0]["url"] as? String, route + "/usage")
            let url = try XCTUnwrap(requests[1]["url"] as? String)
            XCTAssertTrue(url.hasPrefix(route + "/_/BardChatUi/data/batchexecute?"))
            XCTAssertTrue(url.contains("rpcids=jSf9Qc"))
            let options = try XCTUnwrap(requests[1]["options"] as? [String: Any])
            XCTAssertEqual(options["method"] as? String, "POST")
            XCTAssertEqual(options["noAuth"] as? Bool, true)
            XCTAssertTrue((options["body"] as? String ?? "").contains("at=fixture-csrf"))
            let form = try XCTUnwrap(options["body"] as? String)
            let parameters = URLComponents(string: "https://example.invalid/?" + form)?.queryItems
            XCTAssertEqual(parameters?.first(where: { $0.name == "f.req" })?.value,
                           #"[[["jSf9Qc","[]",null,"generic"]]]"#,
                           "batch 容器中也只能包含 GetUsageInfo，不混入其他 RPC")
            XCTAssertEqual(context.objectForKeyedSubscript("saved")?.toString(), route)
            XCTAssertEqual(context.objectForKeyedSubscript("canonical")?.toString(), "aiusage-identity-v1|gemini|sub|123456789")
            let bridged = context.evaluateScript("JSON.stringify(result)")?.toString() ?? ""
            XCTAssertFalse(bridged.contains("fixture-csrf"))
            XCTAssertFalse(bridged.contains("123456789"))
            XCTAssertFalse(bridged.contains("<html>"))
            XCTAssertTrue(bridged.contains("identityFingerprint"))
        }
    }

    func testProductionProbeDoesNotCacheFailedRPC() throws {
        let context = try executeScript(live: true, rpcStatus: 401)
        XCTAssertEqual(context.objectForKeyedSubscript("saved")?.toString(), "/u/7")
        XCTAssertEqual(context.evaluateScript("result.probes.quota.status")?.toInt32(), 401)
        XCTAssertTrue(context.evaluateScript("result.probes.identity === undefined")?.toBool() == true)
    }

    private func executeScript(live: Bool, rpcStatus: Int = 200) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        let bootstrap = #"<html><script nonce="fixture">window.WIZ_global_data = {"SNlM0e":"fixture-csrf","S06Grb":"123456789","cfb2h":"build","FdrFJe":"session"};</script></html>"#
        let responses: [[String: Any]] = [
            ["status": 200, "body": bootstrap],
            ["status": rpcStatus, "body": response("[2,[[2400,0.25,1,[[1788967802]]]]]")]
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: responses), as: UTF8.self)
        let prelude = """
        var requests = [], saved = '/u/7', canonical = '', result, failure;
        var location = { pathname: '/u/3/usage' };
        var geminiUseCurrentAccount = \(live);
        var localStorage = {getItem: () => saved, setItem: (key, value) => { saved = value; }};
        var responses = \(json);
        async function __probe(url, options) { requests.push({url, options}); return responses.shift(); }
        function URLSearchParams(value) { this.value = value; }
        URLSearchParams.prototype.set = function(key, value) { this.value[key] = value; };
        URLSearchParams.prototype.toString = function() { return Object.keys(this.value).map(key => encodeURIComponent(key) + '=' + encodeURIComponent(this.value[key])).join('&'); };
        function TextEncoder() {}
        TextEncoder.prototype.encode = function(value) { canonical = value; return value; };
        var crypto = {subtle: {digest: async () => new Uint8Array(32).buffer}};
        """
        context.evaluateScript(prelude + "\n(async function(){\n" + GeminiProbeScript.body + "\n})().then(x => { result = x; }, e => { failure = String(e); });")
        XCTAssertNil(context.exception?.toString())
        XCTAssertTrue(context.objectForKeyedSubscript("failure")?.isUndefined == true)
        XCTAssertFalse(context.objectForKeyedSubscript("result")?.isUndefined == true)
        return context
    }
    #endif
}
