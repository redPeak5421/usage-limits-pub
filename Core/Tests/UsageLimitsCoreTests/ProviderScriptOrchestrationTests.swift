import XCTest
@testable import UsageLimitsCore

#if canImport(JavaScriptCore)
import JavaScriptCore

final class ProviderScriptOrchestrationTests: XCTestCase {
    func testClaudeKeepsOrgUsageDependencyAndRunsAllSideProbesTogether() throws {
        let run = try execute("claude", routes: [
            route("/api/organizations", body: #"[{"uuid":"org-1","capabilities":["chat"]}]"#),
            route("/usage", body: #"{"five_hour":{"utilization":5}}"#),
            route("/api/account", kind: "hang"),
            route("/overage_spend_limit", kind: "hang"),
            route("/prepaid/credits", kind: "hang"),
        ])
        XCTAssertEqual(probe(run, "organizations")["status"] as? Int, 200)
        XCTAssertEqual(probe(run, "usage")["status"] as? Int, 200)
        XCTAssertEqual(callTimes(run, matching: ["/api/account", "/overage_spend_limit", "/prepaid/credits"]), [0, 0, 0])
        XCTAssertEqual(run.now, 4_000)
    }

    func testOpenAIRunsTokenDependentCoreTogetherAndSideNeverResolveCannotDropSession() throws {
        let run = try execute("openai", routes: [
            route("/api/auth/session", body: #"{"accessToken":"placeholder"}"#),
            route("/backend-api/accounts/check", kind: "hang"),
            route("/backend-api/wham/usage", body: #"{"plan_type":"plus"}"#),
            route("/backend-api/subscriptions", kind: "hang"),
        ])
        XCTAssertEqual(probe(run, "session")["status"] as? Int, 200)
        XCTAssertEqual(firstCallTime(run, containing: "/backend-api/wham/usage"), 0)
        XCTAssertEqual(firstCallTime(run, containing: "/backend-api/accounts/check"), 0)
        XCTAssertLessThan(run.now, 30_000)
    }

    func testGrokRunsModesAndIndependentSupplementalLegsConcurrently() throws {
        let run = try execute("grok", routes: [
            route("/rest/rate-limits", kind: "hang", bodyIncludes: #""modelName":"auto""#),
            route("/rest/rate-limits", body: #"{"remainingTokens":3}"#),
            route("/rest/subscriptions", body: "{}"),
            route("/rest/grok/credits", body: "{}"),
            route("GetGrokCreditsConfig", kind: "hang"),
        ])
        XCTAssertEqual(probe(run, "rate_limits")["status"] as? Int, 200)
        let initialModeCalls = run.calls.filter { ($0["url"] as? String)?.contains("/rest/rate-limits") == true && ($0["at"] as? Int) == 0 }
        XCTAssertEqual(initialModeCalls.count, 4)
        XCTAssertEqual(firstCallTime(run, containing: "/rest/subscriptions"), 0)
        XCTAssertEqual(firstCallTime(run, containing: "GetGrokCreditsConfig"), 0)
        XCTAssertLessThan(run.now, 30_000)
    }

    func testGrokSyntheticShellStays200AndPreservesSuccessfulChildBeside503() throws {
        let run = try execute("grok", routes: [
            route("/rest/rate-limits", body: #"{"remainingQueries":2,"totalQueries":3,"windowSizeSeconds":7200}"#, bodyIncludes: #""modelName":"auto""#),
            route("/rest/rate-limits", status: 503, body: "busy"),
            route("/rest/subscriptions", status: 503, body: "busy"),
            route("/rest/grok/credits", status: 503, body: "busy"),
            route("GetGrokCreditsConfig", status: 503, body: "busy"),
        ])
        let aggregate = probe(run, "rate_limits")
        XCTAssertEqual(aggregate["status"] as? Int, 200)
        let body = try jsonObject(aggregate["body"] as? String)
        let children = try XCTUnwrap(body["results"] as? [[String: Any]])
        XCTAssertEqual(children.first?["status"] as? Int, 200)
        XCTAssertTrue(children.dropFirst().allSatisfy { $0["status"] as? Int == 503 })

        let snapshot = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: try XCTUnwrap(aggregate["body"] as? String))
        ], now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.metrics.first?.id, "auto")
    }

    func testGrokAllInnerTimeoutsKeepSyntheticShell200AndParseAsTimeout() throws {
        let run = try execute("grok", routes: [
            route("/rest/rate-limits", kind: "hang"),
            route("/rest/subscriptions", kind: "hang"),
            route("/rest/grok/credits", kind: "hang"),
            route("GetGrokCreditsConfig", kind: "hang"),
        ])
        let aggregate = probe(run, "rate_limits")
        XCTAssertEqual(aggregate["status"] as? Int, 200)
        let snapshot = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: try XCTUnwrap(aggregate["body"] as? String))
        ], now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(snapshot.status, .error("请求超时"))
    }

    func testCursorRunsCoreAndAuthTogetherAndAuthHangCannotDropCore() throws {
        let run = try execute("cursor", routes: [
            route("/api/usage-summary", body: #"{"billingCycleStart":"2026-08-01","billingCycleEnd":"2026-09-01"}"#),
            route("get-sand-usage-status", body: "{}"),
            route("/api/auth/me", kind: "hang"),
        ], hostname: "cursor.com")
        XCTAssertEqual(probe(run, "usage_summary")["status"] as? Int, 200)
        XCTAssertEqual(run.calls.filter { ($0["at"] as? Int) == 0 }.count, 3)
        XCTAssertEqual(firstCallTime(run, containing: "/api/usage-summary"), 0)
        XCTAssertEqual(firstCallTime(run, containing: "/api/auth/me"), 0)
        XCTAssertLessThan(run.now, 30_000)
    }

    func testDeepSeekRunsBaseAndPeriodsTogetherAndSyntheticShellPreserves200Beside503() throws {
        let summary = #"{"code":0,"data":{"biz_data":{"normal_wallets":[{"balance":"10","currency":"CNY"}],"bonus_wallets":[],"total_costs":[]}}}"#
        let cost = #"{"code":0,"data":{"biz_data":{"data":[{"series":[{"api_key":{"tracking_id":"k","name":"K"},"model":"deepseek-v4","buckets":[{"cost":1,"time":1760000000}]}]}]}}}"#
        let run = try execute("deepseek", routes: [
            route("/auth-api/v0/users/current", body: #"{"code":0,"data":{"biz_data":{"id":"u"}}}"#),
            route("/api/v0/users/get_user_summary", body: summary),
            route("/api/v0/users/get_api_keys", body: #"{"code":0,"data":{"biz_data":{"api_keys":[]}}}"#),
            route("/usage/by_api_key/cost", body: cost),
            route("/usage/by_api_key/amount", status: 503, body: "busy"),
        ], hostname: "platform.deepseek.com", pathname: "/usage")
        XCTAssertEqual(run.calls.filter { ($0["at"] as? Int) == 0 }.count, 15)
        let aggregate = probe(run, "usage_periods")
        XCTAssertEqual(aggregate["status"] as? Int, 200)
        let periods = try jsonObject(aggregate["body"] as? String)
        let today = try XCTUnwrap(periods["today"] as? [String: Any])
        XCTAssertEqual((today["cost"] as? [String: Any])?["status"] as? Int, 200)
        XCTAssertEqual((today["amount"] as? [String: Any])?["status"] as? Int, 503)

        let snapshot = DeepSeekParser.parse(results: [
            "summary": ProbeResult(status: 200, body: summary),
            "usage_periods": ProbeResult(status: 200, body: try XCTUnwrap(aggregate["body"] as? String))
        ], now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.timeBreakdowns?.first?.cost, 1)
    }

    func testDeepSeekAllInnerTimeoutsParseAsTimeout() throws {
        let period = ["start": 0, "end": 1,
                      "cost": ["status": -3, "body": "timeout after 12000ms"],
                      "amount": ["status": -3, "body": "timeout after 12000ms"]] as [String: Any]
        let body = try json(["today": period])
        let snapshot = DeepSeekParser.parse(results: [
            "usage_periods": ProbeResult(status: 200, body: body)
        ], now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(snapshot.status, .error("请求超时"))
    }

    func testDeepSeekAllTimeoutProductionStillReturns200SyntheticShellWithInnerMinusThree() throws {
        let run = try execute("deepseek", routes: [
            route("/auth-api/v0/users/current", kind: "hang"),
            route("/api/v0/users/get_user_summary", kind: "hang"),
            route("/api/v0/users/get_api_keys", kind: "hang"),
            route("/api/v0/usage/by_api_key/", kind: "hang"),
        ], hostname: "platform.deepseek.com", pathname: "/usage")
        let aggregate = probe(run, "usage_periods")
        XCTAssertEqual(aggregate["status"] as? Int, 200)
        let periods = try jsonObject(aggregate["body"] as? String)
        for value in periods.values {
            let period = try XCTUnwrap(value as? [String: Any])
            XCTAssertEqual((period["cost"] as? [String: Any])?["status"] as? Int, -3)
            XCTAssertEqual((period["amount"] as? [String: Any])?["status"] as? Int, -3)
        }
        XCTAssertLessThan(run.now, 30_000)
    }

    func testZhipuStartsAllFourLegsTogetherAndKeepsCustomerWhenSupplementHangs() throws {
        let run = try execute("zhipu", routes: [
            route("getCustomerInfo", body: #"{"code":200,"success":true,"data":{"id":1}}"#),
            route("subscription/list", kind: "hang"),
            route("quota/limit", body: "{}"),
            route("model-usage", body: "{}"),
        ], hostname: "open.bigmodel.cn", pathname: "/coding-plan/personal/usage")
        XCTAssertEqual(probe(run, "customer")["status"] as? Int, 200)
        XCTAssertEqual(run.calls.filter { ($0["at"] as? Int) == 0 }.count, 4)
        XCTAssertLessThan(run.now, 30_000)
    }

    func testKimiStartsAllFiveLegsTogetherAndKeepsCompletedUser() throws {
        let run = try execute("kimi", routes: [
            route("GetCurrentUser", body: #"{"user":{"id":"redacted"}}"#),
            route("ListSubscriptions", kind: "hang"),
            route("GetSubscription", body: "{}"),
            route("GetUsages", body: "{}"),
            route("GetSubscriptionStats", body: "{}"),
        ])
        XCTAssertEqual(probe(run, "user")["status"] as? Int, 200)
        XCTAssertEqual(Set(run.calls.compactMap { $0["at"] as? Int }), [0, 12_300]) // only the hanging leg retries after 300ms
        XCTAssertEqual(run.calls.filter { ($0["at"] as? Int) == 0 }.count, 5)
        XCTAssertLessThan(run.now, 30_000)
    }

    func testMiniMaxStartsIndependentUsageComboAndBillingLegsTogether() throws {
        let run = try execute("minimax", routes: [
            route("remains_percent", body: #"{"base_resp":{"status_code":0}}"#),
            route("token_plan_credit", body: "{}"),
            route("usage_summary", body: "{}"),
            route("cycle_type=3", body: "{}"),
            route("cycle_type=1", body: "{}"),
            route("/account/amount?page=1", kind: "hang"),
        ], hostname: "www.minimaxi.com", pathname: "/user-center/basic-information")
        XCTAssertEqual(probe(run, "remains")["status"] as? Int, 200)
        XCTAssertEqual(run.calls.filter { ($0["at"] as? Int) == 0 }.count, 6)
        XCTAssertEqual(run.now, 8_000)
    }

    func testMiniMaxComboShellStays200AndPreservesYearly200BesideMonthly401() throws {
        let yearly = #"{"base_resp":{"status_code":0},"cycle_resource_packages":[{"title":"TokenPlanMax-年度会员","cycle_type":3,"button_text":"续订套餐"}]}"#
        let run = try execute("minimax", routes: [
            route("remains_percent", body: #"{"base_resp":{"status_code":0},"model_remains":[]}"#),
            route("token_plan_credit", body: "{}"),
            route("usage_summary", body: "{}"),
            route("cycle_type=3", body: yearly),
            route("cycle_type=1", status: 401, body: "unauthorized"),
            route("/account/amount?page=1", body: #"{"data":{"records":[]}}"#),
        ], hostname: "www.minimaxi.com", pathname: "/user-center/basic-information")
        let aggregate = probe(run, "combo")
        XCTAssertEqual(aggregate["status"] as? Int, 200)
        let combo = try jsonObject(aggregate["body"] as? String)
        XCTAssertEqual((combo["yearly"] as? [String: Any])?["status"] as? Int, 200)
        XCTAssertEqual((combo["monthly"] as? [String: Any])?["status"] as? Int, 401)

        let snapshot = MiniMaxParser.parse(results: [
            "remains": ProbeResult(status: 200, body: #"{"base_resp":{"status_code":0},"model_remains":[]}"#),
            "combo": ProbeResult(status: 200, body: try XCTUnwrap(aggregate["body"] as? String))
        ], now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.planName, "Token Plan Max")
        XCTAssertEqual(snapshot.billingCycle, .yearly)
    }

    func testMiniMaxAllInnerTimeoutsParseAsTimeout() throws {
        let combo = try json([
            "yearly": ["status": -3, "body": "timeout after 12000ms"],
            "monthly": ["status": -3, "body": "timeout after 12000ms"],
        ])
        let snapshot = MiniMaxParser.parse(results: [
            "combo": ProbeResult(status: 200, body: combo)
        ], now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(snapshot.status, .error("请求超时"))
    }

    func testMiniMaxAllTimeoutProductionStillReturns200SyntheticShellWithInnerMinusThree() throws {
        let run = try execute("minimax", routes: [
            route("remains_percent", kind: "hang"),
            route("token_plan_credit", kind: "hang"),
            route("usage_summary", kind: "hang"),
            route("cycle_audio_resource_package", kind: "hang"),
            route("/account/amount", kind: "hang"),
        ], hostname: "www.minimaxi.com", pathname: "/user-center/basic-information")
        let aggregate = probe(run, "combo")
        XCTAssertEqual(aggregate["status"] as? Int, 200)
        let combo = try jsonObject(aggregate["body"] as? String)
        XCTAssertEqual((combo["yearly"] as? [String: Any])?["status"] as? Int, -3)
        XCTAssertEqual((combo["monthly"] as? [String: Any])?["status"] as? Int, -3)
        XCTAssertLessThan(run.now, 30_000)
    }

    func testAggregateParsersKeepSuccessfulChildrenBeside401Or503() throws {
        let grok = #"{"results":[{"modelName":"auto","requestKind":"DEFAULT","status":200,"body":{"remainingQueries":2,"totalQueries":4,"windowSizeSeconds":7200}},{"modelName":"fast","requestKind":"DEFAULT","status":401,"body":{}}]}"#
        let grokSnapshot = GrokParser.parse(results: [
            "rate_limits": ProbeResult(status: 200, body: grok)
        ], now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(grokSnapshot.status, .ok)
        XCTAssertEqual(grokSnapshot.metrics.map(\.id), ["auto"])

        let summary = #"{"code":0,"data":{"biz_data":{"normal_wallets":[{"balance":"10","currency":"CNY"}],"bonus_wallets":[],"total_costs":[]}}}"#
        let cost = #"{"code":0,"data":{"biz_data":{"data":[{"series":[{"api_key":{"tracking_id":"k"},"buckets":[{"cost":2,"time":1760000000}]}]}]}}}"#
        let periods = try json(["today": [
            "start": 0, "end": 1,
            "cost": ["status": 200, "body": cost],
            "amount": ["status": 401, "body": "unauthorized"],
        ]])
        let deepSeekSnapshot = DeepSeekParser.parse(results: [
            "summary": ProbeResult(status: 200, body: summary),
            "usage_periods": ProbeResult(status: 200, body: periods),
        ], now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(deepSeekSnapshot.status, .ok)
        XCTAssertEqual(deepSeekSnapshot.timeBreakdowns?.first?.cost, 2)

        let yearly = #"{"base_resp":{"status_code":0},"cycle_resource_packages":[{"title":"TokenPlanPlus-年度会员","cycle_type":3,"button_text":"续订套餐"}]}"#
        let combo = try json([
            "yearly": ["status": 200, "body": yearly],
            "monthly": ["status": 503, "body": "busy"],
        ])
        let miniMaxSnapshot = MiniMaxParser.parse(results: [
            "remains": ProbeResult(status: 200, body: #"{"base_resp":{"status_code":0},"model_remains":[]}"#),
            "combo": ProbeResult(status: 200, body: combo),
        ], now: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertEqual(miniMaxSnapshot.status, .ok)
        XCTAssertEqual(miniMaxSnapshot.planName, "Token Plan Plus")
    }

    func testOpenCodeRunsBillingAndLiteFallbacksTogetherWithinDeadline() throws {
        let run = try execute("opencode", routes: [
            route("/auth/status", body: #"{"authenticated":true}"#),
            route("/workspace/wrk_test", body: "<html></html>"),
            route("c83b78a614689c38", kind: "hang"),
            route("c7389bd0e731f80f", status: 500, body: "lite unavailable"),
            route("/workspace/wrk_test/go", kind: "hang"),
        ], hostname: "opencode.ai", pathname: "/workspace/wrk_test")
        XCTAssertEqual(probe(run, "status")["status"] as? Int, 200)
        XCTAssertEqual(firstCallTime(run, containing: "c83b78a614689c38"), firstCallTime(run, containing: "c7389bd0e731f80f"))
        XCTAssertLessThan(run.now, 30_000)
        let body = try productionBody("opencode")
        XCTAssertTrue(body.contains("__deadlineRace(function () { return import("))
        XCTAssertTrue(body.contains("__deadlineRace(function () { return ref.apply("))
    }

    func testJimengSignedRequestsUseAbortableHelperAndRetry1014OnlyOnce() throws {
        let run = try execute("jimeng", routes: [
            route("/passport/web/account/info", body: "{}"),
            ["match": "/commerce/v1/benefits/user_credit?", "kind": "response", "status": 200, "body": "",
             "sequence": [
                ["kind": "response", "status": 200, "body": #"{"ret":"1014"}"#],
                ["kind": "response", "status": 200, "body": #"{"ret":"0","data":{"credit":{"purchase_credit":1}}}"#],
             ]],
            route("user_credit_history", body: #"{"ret":"0","data":{"records":[]}}"#),
        ], hostname: "jimeng.jianying.com", pathname: "/ai-tool/home", prelude: """
        window.__isLogined = true;
        window.use = function (name) {
            if (name === 'webSignBody') {
                return function (url) { return { url: url, headers: { 'X-Test-Signed': 'yes' } }; };
            }
            return function () {};
        };
        """)
        let creditCalls = run.calls.filter { ($0["url"] as? String)?.contains("/commerce/v1/benefits/user_credit?") == true }
        XCTAssertEqual(creditCalls.count, 2)
        XCTAssertEqual(creditCalls.compactMap { $0["at"] as? Int }, [0, 400])
        XCTAssertTrue(run.calls.allSatisfy { $0["hasSignal"] as? Bool == true })
        XCTAssertEqual(probe(run, "credit")["status"] as? Int, 200)
        XCTAssertNil(run.probes["identity"], "sec_uid/user_id 原值不得跨过 JS→Swift 边界")
        let source = try productionBody("jimeng")
        XCTAssertFalse(source.contains("JSON.stringify(discovered)"))
    }

    func testLongCatStartsFourIndependentLegsTogether() throws {
        let run = try execute("longcat", routes: [
            route("/api/v1/user-current", kind: "hang"),
            route("token-packs/summary", body: "{}"),
            route("/tokenUsage", body: "{}"),
            route("pending-fuel-packages", body: "{}"),
        ], hostname: "longcat.chat", pathname: "/platform/usage")
        XCTAssertEqual(run.calls.filter { ($0["at"] as? Int) == 0 }.count, 4)
        XCTAssertEqual(probe(run, "token_packs")["status"] as? Int, 200)
        XCTAssertLessThan(run.now, 30_000)
    }

    func testAugmentOptionalSubscriptionStartsWithCoreAndDoesNotRetry() throws {
        let run = try execute("augment", routes: [
            route("/api/credits", body: #"{"usageUnitsRemaining":10,"usageUnitsConsumedThisBillingCycle":1}"#),
            route("/api/subscription", kind: "hang"),
        ], hostname: "app.augmentcode.com", pathname: "/account/subscription")
        XCTAssertEqual(firstCallTime(run, containing: "/api/credits"), 0)
        XCTAssertEqual(firstCallTime(run, containing: "/api/subscription"), 0)
        XCTAssertEqual(run.calls.filter { ($0["url"] as? String)?.contains("/api/subscription") == true }.count, 1)
        XCTAssertEqual(run.now, 8_000)
    }

    private struct Execution { let probes: [String: Any]; let calls: [[String: Any]]; let now: Int }

    private func route(_ match: String, kind: String = "response", status: Int = 200,
                       body: String = "", bodyIncludes: String? = nil) -> [String: Any] {
        var value: [String: Any] = ["match": match, "kind": kind, "status": status, "body": body]
        if let bodyIncludes { value["bodyIncludes"] = bodyIncludes }
        return value
    }

    private func execute(_ name: String, routes: [[String: Any]],
                         hostname: String = "example.invalid", pathname: String = "/",
                         prelude: String = "") throws -> Execution {
        let body = try productionBody(name)
        let context = try XCTUnwrap(JSContext())
        var exception: String?
        context.exceptionHandler = { _, error in exception = error?.toString() }
        context.evaluateScript("""
        var __done=false, __error=null, __output=null, __now=0, __timerID=0, __timers=[], __calls=[];
        var __routes=\(try json(routes));
        Date.now=function(){return __now;};
        var location={hostname:\(try json(hostname)), pathname:\(try json(pathname)), origin:'https://'+\(try json(hostname))};
        var localStorage={getItem:function(){return null;}};
        var document={cookie:'',getElementById:function(){return null;}};
        var window=this;
        \(prelude)
        function URL(raw){const m=String(raw).match(/^([a-z]+:[/][/][^/?#]+)([/][^?#]*)?/i);if(!m)throw new Error('invalid URL');this.origin=m[1];this.pathname=m[2]||'/';}
        function AbortController(){const ls=[];this.signal={aborted:false,addEventListener:function(n,c){if(n==='abort')ls.push(c);}};this.abort=function(){if(this.signal.aborted)return;this.signal.aborted=true;ls.slice().forEach(function(c){c();});};}
        function setTimeout(cb,d){const id=++__timerID;__timers.push({id:id,at:__now+Math.max(0,Number(d)||0),cb:cb,cancelled:false});return id;}
        function clearTimeout(id){__timers.forEach(function(t){if(t.id===id)t.cancelled=true;});}
        function __runNextTimer(){const live=__timers.filter(function(t){return !t.cancelled;}).sort(function(a,b){return a.at-b.at||a.id-b.id;});if(!live.length)return false;const t=live[0];t.cancelled=true;__now=t.at;t.cb();return true;}
        function __abortError(){const e=new Error('aborted');e.name='AbortError';return e;}
        function __headers(){return {get:function(){return null;}};}
        async function fetch(url,options){
          const u=String(url), requestBody=String((options&&options.body)||'');
          let r=null;for(let i=0;i<__routes.length;i++){const x=__routes[i];if(u.indexOf(x.match)>=0&&(!x.bodyIncludes||requestBody.indexOf(x.bodyIncludes)>=0)){r=x;break;}}
          if(!r)r={kind:'response',status:200,body:'{}'};
          let chosen=r;
          if(Array.isArray(r.sequence)) { const index=Math.min(r.__uses||0,r.sequence.length-1); chosen=r.sequence[index]; r.__uses=(r.__uses||0)+1; }
          __calls.push({url:u,at:__now,body:requestBody,hasSignal:!!(options&&options.signal)});
          if(chosen.kind==='hang')return await new Promise(function(_,reject){if(options&&options.signal){if(options.signal.aborted){reject(__abortError());return;}options.signal.addEventListener('abort',function(){reject(__abortError());});}});
          return {status:Number(chosen.status),url:'https://'+location.hostname+'/safe?token=redacted',headers:__headers(),text:async function(){return String(chosen.body||'');},arrayBuffer:async function(){return new Uint8Array(chosen.bytes||[]).buffer;}};
        }
        function btoa(){return '';}
        \(ProviderProbeScript.helper)
        (async function(){
        \(body)
        })().then(function(v){__output=JSON.stringify({value:v,calls:__calls,now:__now});__done=true;},function(e){__error=String(e&&e.stack?e.stack:e);__done=true;});
        """)
        let deadline = Date().addingTimeInterval(3)
        while context.objectForKeyedSubscript("__done")?.toBool() != true, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
            if context.objectForKeyedSubscript("__done")?.toBool() != true { _ = context.evaluateScript("__runNextTimer()") }
        }
        if let exception { throw failure(exception, 1) }
        guard context.objectForKeyedSubscript("__done")?.toBool() == true else { throw failure("JavaScript Promise timed out", 2) }
        if let error = context.objectForKeyedSubscript("__error")?.toString(), error != "null" { throw failure(error, 3) }
        let raw = try XCTUnwrap(context.objectForKeyedSubscript("__output")?.toString())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(raw.data(using: .utf8))) as? [String: Any])
        let value = try XCTUnwrap(root["value"] as? [String: Any])
        return Execution(probes: try XCTUnwrap(value["probes"] as? [String: Any]),
                         calls: try XCTUnwrap(root["calls"] as? [[String: Any]]),
                         now: try XCTUnwrap(root["now"] as? NSNumber).intValue)
    }

    private func productionBody(_ name: String) throws -> String {
        let source = try String(contentsOf: providerScriptsURL(), encoding: .utf8)
        let marker = "static let \(name) = probeHelper + #\"\"\""
        let start = try XCTUnwrap(source.range(of: marker))
        let end = try XCTUnwrap(source.range(of: "\"\"\"#", range: start.upperBound..<source.endIndex))
        return String(source[start.upperBound..<end.lowerBound])
    }

    private func probe(_ run: Execution, _ name: String) -> [String: Any] { run.probes[name] as? [String: Any] ?? [:] }
    private func firstCallTime(_ run: Execution, containing value: String) -> Int? {
        run.calls.first { ($0["url"] as? String)?.contains(value) == true }?["at"] as? Int
    }
    private func callTimes(_ run: Execution, matching values: [String]) -> [Int] {
        values.compactMap { firstCallTime(run, containing: $0) }
    }
    private func providerScriptsURL() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Networking/ProviderScripts.swift")
    }
    private func json(_ value: Any) throws -> String {
        let data: Data
        if let string = value as? String { data = try JSONSerialization.data(withJSONObject: [string]); return String(data: data, encoding: .utf8)!.dropFirst().dropLast().description }
        data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
    private func jsonObject(_ text: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(try XCTUnwrap(text).data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func failure(_ message: String, _ code: Int) -> NSError {
        NSError(domain: "ProviderScriptOrchestrationTests", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
#endif
