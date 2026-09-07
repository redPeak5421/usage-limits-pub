import XCTest
@testable import UsageLimitsCore

#if canImport(JavaScriptCore)
import JavaScriptCore

final class ProviderProbeScriptDeadlineTests: XCTestCase {
    func testDefaultRequestTimesOutAtTwelveSeconds() throws {
        let run = try execute(behaviors: [["kind": "hang"]], body: "return await __probe('/hang', { retry: false });")
        XCTAssertEqual(run.result["status"] as? Int, -3)
        XCTAssertEqual(run.now, 12_000)
        XCTAssertEqual(run.calls.count, 1)
        XCTAssertEqual(run.calls.first?["at"] as? Int, 0)
    }

    func testTransientFailureWaitsThreeHundredMillisecondsThenRetriesOnce() throws {
        let run = try execute(
            behaviors: [
                ["kind": "response", "status": 503, "body": "busy"],
                ["kind": "response", "status": 200, "body": "ok"],
            ],
            body: "return await __probe('/retry', {});"
        )
        XCTAssertEqual(run.result["status"] as? Int, 200)
        XCTAssertEqual(run.result["body"] as? String, "ok")
        XCTAssertEqual(run.now, 300)
        XCTAssertEqual(run.calls.compactMap { $0["at"] as? Int }, [0, 300])
    }

    func testSharedDeadlineKeepsCompletedCoreAndDoesNotStartAnotherFetch() throws {
        let run = try execute(
            behaviors: [
                ["kind": "response", "status": 200, "body": "core-ok"],
                ["kind": "hang"],
            ],
            body: """
            const probes = {};
            probes.core = await __probe('/core', { retry: false });
            probes.side = await __probe('/side', { timeoutMs: 30000, retry: false });
            probes.afterDeadline = await __probe('/must-not-fetch', { retry: false });
            return probes;
            """
        )
        XCTAssertEqual((run.result["core"] as? [String: Any])?["body"] as? String, "core-ok")
        XCTAssertEqual((run.result["side"] as? [String: Any])?["status"] as? Int, -3)
        XCTAssertEqual((run.result["afterDeadline"] as? [String: Any])?["status"] as? Int, -3)
        XCTAssertEqual(run.calls.compactMap { $0["url"] as? String }, ["/core", "/side"])
        XCTAssertEqual(run.now, 27_000)
        XCTAssertLessThan(run.now, 30_000)
    }

    func testSharedDeadlineClampsEachRequestAndSuppressesRetryWhenBudgetIsGone() throws {
        let run = try execute(
            behaviors: [["kind": "hang"], ["kind": "hang"], ["kind": "hang"]],
            body: """
            const first = await __probe('/first', { timeoutMs: 12000, retry: false });
            const second = await __probe('/second', { timeoutMs: 12000, retry: false });
            const third = await __probe('/third', { timeoutMs: 12000 });
            return { first: first, second: second, third: third };
            """
        )
        XCTAssertEqual(run.calls.compactMap { $0["at"] as? Int }, [0, 12_000, 24_000])
        XCTAssertEqual(run.now, 27_000)
        XCTAssertEqual((run.result["third"] as? [String: Any])?["status"] as? Int, -3)
        XCTAssertEqual(run.calls.count, 3, "deadline 后不能为第三条的瞬态超时再发重试")
    }

    func testBinaryProbeUsesAbortableSharedBudgetAndPreservesResponseHeaders() throws {
        let run = try execute(
            behaviors: [[
                "kind": "binary", "status": 200, "bytes": [0, 1, 2, 3],
                "headers": ["grpc-status": "0", "grpc-message": "ok"],
            ]],
            body: "return await __probeBinary('/grpc', { method: 'POST', retry: false });"
        )
        XCTAssertEqual(run.result["status"] as? Int, 200)
        XCTAssertEqual(run.result["body"] as? String, "AAECAw==")
        XCTAssertEqual(run.result["grpcStatus"] as? String, "0")
        XCTAssertEqual(run.result["grpcMessage"] as? String, "ok")
        XCTAssertEqual(run.calls.first?["hasSignal"] as? Bool, true)
    }

    func testGenericDeadlineRaceReturnsFallbackForUnabortableTask() throws {
        let run = try execute(
            behaviors: [],
            body: "return await __deadlineRace(function () { return new Promise(function () {}); }, 5000, { status: -3, body: 'runtime timeout' });"
        )
        XCTAssertEqual(run.result["status"] as? Int, -3)
        XCTAssertEqual(run.result["body"] as? String, "runtime timeout")
        XCTAssertEqual(run.now, 5_000)
        XCTAssertTrue(run.calls.isEmpty)
    }

    func testFetchIgnoringAbortStillReturnsAtOuterRequestBudget() throws {
        let run = try execute(
            behaviors: [["kind": "hangIgnoreAbort"]],
            body: "return await __probe('/ignores-abort', { timeoutMs: 1100, retry: false });"
        )
        XCTAssertEqual(run.result["status"] as? Int, -3)
        XCTAssertEqual(run.result["body"] as? String, "timeout after 1100ms")
        XCTAssertEqual(run.now, 1_100)
        XCTAssertEqual(run.calls.first?["hasSignal"] as? Bool, true)
    }

    func testResponseTextPromiseIgnoringAbortIsCoveredBySameRace() throws {
        let run = try execute(
            behaviors: [["kind": "textHang", "status": 200]],
            body: "return await __probe('/text-hangs', { timeoutMs: 1250, retry: false });"
        )
        XCTAssertEqual(run.result["status"] as? Int, -3)
        XCTAssertEqual(run.now, 1_250)
    }

    func testResponseArrayBufferPromiseIgnoringAbortIsCoveredBySameRace() throws {
        let run = try execute(
            behaviors: [["kind": "arrayBufferHang", "status": 200]],
            body: "return await __probeBinary('/binary-hangs', { timeoutMs: 1300, retry: false });"
        )
        XCTAssertEqual(run.result["status"] as? Int, -3)
        XCTAssertEqual(run.now, 1_300)
    }

    func testLateFetchRejectionAfterTimeoutIsConsumed() throws {
        let run = try execute(
            behaviors: [["kind": "lateReject", "rejectAt": 1050]],
            body: """
            const probe = await __probe('/late-reject', { timeoutMs: 1000, retry: false });
            await new Promise(function (resolve) { setTimeout(resolve, 100); });
            return { status: probe.status, body: probe.body, lateRejects: __lateRejects };
            """
        )
        XCTAssertEqual(run.result["status"] as? Int, -3)
        XCTAssertEqual(run.result["lateRejects"] as? Int, 1)
        XCTAssertEqual(run.now, 1_100)
    }

    func testSuccessfulDeadlineRaceSettlesOnceAndClearsItsTimer() throws {
        let run = try execute(
            behaviors: [],
            body: """
            let timeouts = 0;
            const value = await __deadlineRace(
                function () { return Promise.resolve({ status: 200, body: 'ok' }); },
                1000,
                { status: -3, body: 'timeout' },
                function () { timeouts++; }
            );
            return {
                status: value.status,
                body: value.body,
                timeouts: timeouts,
                liveTimers: __timers.filter(function (timer) { return !timer.cancelled; }).length
            };
            """
        )
        XCTAssertEqual(run.result["status"] as? Int, 200)
        XCTAssertEqual(run.result["timeouts"] as? Int, 0)
        XCTAssertEqual(run.result["liveTimers"] as? Int, 0)
        XCTAssertEqual(run.now, 0)
    }

    func testWorkCompletingExactlyAtDeadlineSettlesOnceAndClearsDeadlineTimer() throws {
        let run = try execute(
            behaviors: [],
            body: """
            let timeouts = 0;
            const value = await __deadlineRace(function () {
                return new Promise(function (resolve) {
                    setTimeout(function () { resolve({ status: 200, body: 'edge' }); }, 1000);
                });
            }, 1000, { status: -3, body: 'timeout' }, function () { timeouts++; });
            return {
                status: value.status,
                body: value.body,
                timeouts: timeouts,
                liveTimers: __timers.filter(function (timer) { return !timer.cancelled; }).length
            };
            """
        )
        XCTAssertEqual(run.result["status"] as? Int, 200)
        XCTAssertEqual(run.result["body"] as? String, "edge")
        XCTAssertEqual(run.result["timeouts"] as? Int, 0)
        XCTAssertEqual(run.result["liveTimers"] as? Int, 0)
        XCTAssertEqual(run.now, 1_000)
    }

    func testTextFallbackTruncatesByUTF8BytesNotJavaScriptCharacters() throws {
        let run = try execute(
            behaviors: [["kind": "response", "status": 200, "textRepeat": "中", "repeatCount": 400_000]],
            body: "return await __probe('/utf8', { retry: false });"
        )
        let text = try XCTUnwrap(run.result["body"] as? String)
        XCTAssertLessThanOrEqual(text.data(using: .utf8)?.count ?? .max, 1_000_000)
        XCTAssertGreaterThan(text.count, 300_000)
        XCTAssertLessThan(text.count, 400_000, "不能按 1,000,000 个 JS 字符截断")
    }

    func testBinaryFallbackCapsRawBytesSoBase64NeverExceedsTwoHundredThousandBytes() throws {
        let run = try execute(
            behaviors: [["kind": "binary", "status": 200, "byteCount": 180_000]],
            body: "return await __probeBinary('/large-binary', { retry: false });"
        )
        XCTAssertEqual((run.result["body"] as? String)?.utf8.count, 200_000)
    }

    func testBinaryReadableStreamUsesRawOneHundredFiftyThousandByteCap() throws {
        let run = try execute(
            behaviors: [["kind": "stream", "status": 200, "streamByteCount": 180_000]],
            body: """
            const probe = await __probeBinary('/large-binary-stream', { retry: false });
            return { status: probe.status, body: probe.body, cancelledReaders: __cancelledReaders };
            """
        )
        XCTAssertEqual(run.result["status"] as? Int, 200)
        XCTAssertEqual((run.result["body"] as? String)?.utf8.count, 200_000)
        XCTAssertEqual(run.result["cancelledReaders"] as? Int, 1)
    }

    func testOversizedTrustedContentLengthWithoutStreamReturnsShapeErrorBeforeReadingBody() throws {
        let run = try execute(
            behaviors: [[
                "kind": "response", "status": 200, "body": "must-not-read",
                "headers": ["content-length": "1000001"],
            ]],
            body: """
            const probe = await __probe('/declared-too-large', { retry: false });
            return { status: probe.status, body: probe.body, textReads: __textReads };
            """
        )
        XCTAssertEqual(run.result["status"] as? Int, -2)
        XCTAssertEqual(run.result["body"] as? String, "response exceeds 1000000-byte limit")
        XCTAssertEqual(run.result["textReads"] as? Int, 0)
    }

    func testReadableStreamIsCancelledAtByteLimit() throws {
        let run = try execute(
            behaviors: [["kind": "stream", "status": 200, "streamByteCount": 1_100_000]],
            body: """
            const probe = await __probe('/large-stream', { retry: false });
            return { status: probe.status, body: probe.body, cancelledReaders: __cancelledReaders };
            """
        )
        XCTAssertEqual(run.result["status"] as? Int, 200)
        XCTAssertEqual((run.result["body"] as? String)?.utf8.count, 1_000_000)
        XCTAssertEqual(run.result["cancelledReaders"] as? Int, 1)
    }

    func testReadableStreamReaderIgnoringAbortCannotOutliveBudget() throws {
        let run = try execute(
            behaviors: [["kind": "streamHang", "status": 200]],
            body: "return await __probe('/reader-hangs', { timeoutMs: 1400, retry: false });"
        )
        XCTAssertEqual(run.result["status"] as? Int, -3)
        XCTAssertEqual(run.now, 1_400)
    }

    private struct Execution {
        let result: [String: Any]
        let calls: [[String: Any]]
        let now: Int
    }

    private func execute(behaviors: [[String: Any]], body: String) throws -> Execution {
        let behaviorJSON = try json(behaviors)
        let context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, error in exception = error?.toString() }
        context.evaluateScript("""
        var __done = false;
        var __error = null;
        var __output = null;
        var __now = 0;
        var __timerID = 0;
        var __timers = [];
        var __calls = [];
        var __lateRejects = 0;
        var __cancelledReaders = 0;
        var __textReads = 0;
        var __behaviors = \(behaviorJSON);
        Date.now = function () { return __now; };
        var localStorage = { getItem: function () { return null; } };
        var document = { cookie: '' };
        function URL(raw) {
            const match = String(raw).match(/^([a-z]+:[/][/][^/?#]+)([/][^?#]*)?/i);
            if (!match) { throw new Error('invalid URL'); }
            this.origin = match[1];
            this.pathname = match[2] || '/';
        }
        function AbortController() {
            const listeners = [];
            this.signal = {
                aborted: false,
                addEventListener: function (name, callback) { if (name === 'abort') { listeners.push(callback); } }
            };
            this.abort = function () {
                if (this.signal.aborted) { return; }
                this.signal.aborted = true;
                listeners.slice().forEach(function (callback) { callback(); });
            };
        }
        function setTimeout(callback, delay) {
            const id = ++__timerID;
            __timers.push({ id: id, at: __now + Math.max(0, Number(delay) || 0), callback: callback, cancelled: false });
            return id;
        }
        function clearTimeout(id) {
            __timers.forEach(function (timer) { if (timer.id === id) { timer.cancelled = true; } });
        }
        function __runNextTimer() {
            const live = __timers.filter(function (timer) { return !timer.cancelled; })
                .sort(function (a, b) { return a.at - b.at || a.id - b.id; });
            if (!live.length) { return false; }
            const timer = live[0];
            timer.cancelled = true;
            __now = timer.at;
            timer.callback();
            return true;
        }
        function __headers(values) {
            const lower = {};
            Object.keys(values || {}).forEach(function (key) { lower[String(key).toLowerCase()] = String(values[key]); });
            return { get: function (name) { return lower[String(name).toLowerCase()] ?? null; } };
        }
        function __abortError() { const error = new Error('aborted'); error.name = 'AbortError'; return error; }
        function btoa(raw) {
            const table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
            let out = '';
            for (let i = 0; i < raw.length; i += 3) {
                const a = raw.charCodeAt(i) & 255;
                const hasB = i + 1 < raw.length;
                const hasC = i + 2 < raw.length;
                const b = hasB ? (raw.charCodeAt(i + 1) & 255) : 0;
                const c = hasC ? (raw.charCodeAt(i + 2) & 255) : 0;
                out += table[a >> 2];
                out += table[((a & 3) << 4) | (b >> 4)];
                out += hasB ? table[((b & 15) << 2) | (c >> 6)] : '=';
                out += hasC ? table[c & 63] : '=';
            }
            return out;
        }
        async function fetch(url, options) {
            const behavior = __behaviors[Math.min(__calls.length, __behaviors.length - 1)] || { kind: 'hang' };
            __calls.push({ url: String(url), at: __now, hasSignal: !!(options && options.signal) });
            if (behavior.kind === 'hang') {
                return await new Promise(function (_, reject) {
                    if (options && options.signal) {
                        if (options.signal.aborted) { reject(__abortError()); return; }
                        options.signal.addEventListener('abort', function () { reject(__abortError()); });
                    }
                });
            }
            if (behavior.kind === 'hangIgnoreAbort') {
                return await new Promise(function () {});
            }
            if (behavior.kind === 'lateReject') {
                return await new Promise(function (_, reject) {
                    setTimeout(function () { __lateRejects++; reject(new Error('late network failure')); }, Number(behavior.rejectAt || 0));
                });
            }
            let responseBody = null;
            if (behavior.kind === 'stream' || behavior.kind === 'streamHang') {
                let sent = 0;
                responseBody = { getReader: function () { return {
                    read: function () {
                        if (behavior.kind === 'streamHang') { return new Promise(function () {}); }
                        if (sent >= Number(behavior.streamByteCount || 0)) { return Promise.resolve({ done: true }); }
                        const count = Math.min(65536, Number(behavior.streamByteCount || 0) - sent);
                        sent += count;
                        const chunk = new Uint8Array(count);
                        for (let i = 0; i < count; i++) { chunk[i] = 97; }
                        return Promise.resolve({ done: false, value: chunk });
                    },
                    cancel: function () { __cancelledReaders++; return Promise.resolve(); }
                }; } };
            }
            return {
                status: Number(behavior.status),
                url: 'https://example.invalid/result?secret=redacted',
                headers: __headers(behavior.headers || {}),
                body: responseBody,
                text: async function () {
                    __textReads++;
                    if (behavior.kind === 'textHang') { return await new Promise(function () {}); }
                    if (behavior.textRepeat) { return String(behavior.textRepeat).repeat(Number(behavior.repeatCount || 0)); }
                    return String(behavior.body || '');
                },
                arrayBuffer: async function () {
                    if (behavior.kind === 'arrayBufferHang') { return await new Promise(function () {}); }
                    if (behavior.byteCount) {
                        const out = new Uint8Array(Number(behavior.byteCount));
                        for (let i = 0; i < out.length; i++) { out[i] = i & 255; }
                        return out.buffer;
                    }
                    return new Uint8Array(behavior.bytes || []).buffer;
                }
            };
        }
        \(ProviderProbeScript.helper)
        (async function () {
        \(body)
        })().then(function (value) {
            __output = JSON.stringify({ value: value, calls: __calls, now: __now });
            __done = true;
        }, function (error) {
            __error = String(error && error.stack ? error.stack : error);
            __done = true;
        });
        """)

        let realDeadline = Date().addingTimeInterval(2)
        while context.objectForKeyedSubscript("__done")?.toBool() != true, Date() < realDeadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
            if context.objectForKeyedSubscript("__done")?.toBool() != true {
                _ = context.evaluateScript("__runNextTimer()")
            }
        }
        if let exception {
            throw NSError(domain: "ProviderProbeScriptDeadlineTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: exception])
        }
        guard context.objectForKeyedSubscript("__done")?.toBool() == true else {
            throw NSError(domain: "ProviderProbeScriptDeadlineTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "JavaScript Promise timed out"])
        }
        if let error = context.objectForKeyedSubscript("__error")?.toString(), error != "null" {
            throw NSError(domain: "ProviderProbeScriptDeadlineTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: error])
        }
        let raw = try XCTUnwrap(context.objectForKeyedSubscript("__output")?.toString())
        let data = try XCTUnwrap(raw.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Execution(
            result: try XCTUnwrap(root["value"] as? [String: Any]),
            calls: try XCTUnwrap(root["calls"] as? [[String: Any]]),
            now: try XCTUnwrap(root["now"] as? NSNumber).intValue
        )
    }

    private func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
#endif
