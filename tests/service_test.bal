import ballerina/http;
import ballerina/lang.runtime;
import ballerina/tcp;
import ballerina/test;
import ballerina/time;
import ballerina/url;

const string ORIGIN = "https://app.example.com";
const string UP = "http://127.0.0.1:9301";

final http:Client proxy = check new ("http://localhost:9300", httpVersion = http:HTTP_1_1, timeout = 20, cache = {enabled: false});

function call(string method, string? target, map<string|string[]> extra = {}, string body = "") returns http:Response|error {
    map<string|string[]> headers = {"Origin": ORIGIN};
    foreach [string, string|string[]] [name, value] in extra.entries() {
        headers[name] = value;
    }
    string path = target is string ? "/?target=" + check url:encode(target, "UTF-8") : "/";
    return proxy->execute(method, path, body == "" ? () : body, headers);
}

function headerOf(http:Response res, string name) returns string? {
    string|error value = res.getHeader(name);
    return value is string ? value : ();
}

function assertError(http:Response res, int status, string message) returns error? {
    test:assertEquals(res.statusCode, status);
    test:assertEquals(check res.getJsonPayload(), {"error": message});
}

@test:Config
function testPreflightIsAnsweredWithCorsHeaders() returns error? {
    http:Response res = check call("OPTIONS", (), {"Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "authorization, x-custom"});
    test:assertEquals(res.statusCode, 204);
    test:assertEquals(headerOf(res, "Access-Control-Allow-Origin"), ORIGIN);
    test:assertEquals(headerOf(res, "Access-Control-Allow-Headers"), "authorization, x-custom");
    test:assertEquals(headerOf(res, "Access-Control-Allow-Methods"), "GET, POST, DELETE, OPTIONS");
    test:assertEquals(headerOf(res, "Access-Control-Max-Age"), "600");
    test:assertEquals(headerOf(res, "Vary"), "Origin, Access-Control-Request-Headers");
}

@test:Config
function testPreflightFromAnUnknownOriginGetsNoAllowOrigin() returns error? {
    http:Response res = check call("OPTIONS", (), {"Origin": "https://evil.com"});
    test:assertEquals(res.statusCode, 204);
    test:assertEquals(headerOf(res, "Access-Control-Allow-Origin"), ());
}

@test:Config
function testPreflightIsNotRateLimited() returns error? {
    foreach int i in 0 ..< 20 {
        test:assertEquals((check call("OPTIONS", ())).statusCode, 204);
    }
}

@test:Config
function testOtherMethodsAreRejected() returns error? {
    foreach string method in ["PATCH", "PUT"] {
        http:Response res = check call(method, UP + "/echo");
        check assertError(res, 405, "Method not allowed");
        test:assertEquals(headerOf(res, "Access-Control-Allow-Origin"), ORIGIN);
    }
}

@test:Config
function testUnknownOriginIsRejectedWithoutAllowOrigin() returns error? {
    http:Response res = check call("GET", UP + "/echo", {"Origin": "https://evil.com"});
    check assertError(res, 403, "Origin not allowed");
    test:assertEquals(headerOf(res, "Access-Control-Allow-Origin"), ());
}

@test:Config
function testMissingOriginIsRejected() returns error? {
    http:Response res = check proxy->execute("GET", "/?target=" + UP, (), {});
    check assertError(res, 403, "Origin not allowed");
}

@test:Config
function testBadTargetsAreRejected() returns error? {
    check assertError(check call("GET", ()), 400, "Missing target URL");
    check assertError(check call("GET", "not a url"), 400, "Invalid target URL");
    check assertError(check call("GET", "http://10.0.0.1/mcp"), 403, "Target resolves to a blocked address range");
    check assertError(check call("GET", "http://no-such-host.invalid/"), 502, "Failed to validate target");
}

@test:Config
function testRequestIsRelayedToTheTarget() returns error? {
    http:Response res = check call("POST", UP + "/echo?x=1", {"Authorization": "Bearer secret", "Cookie": "session=1", "Content-Type": "application/json"}, "{\"a\":1}");
    test:assertEquals(res.statusCode, 200);
    string text = check res.getTextPayload();
    test:assertTrue(text.includes("POST /echo?x=1"), text);
    test:assertTrue(text.includes("authorization: Bearer secret"), text);
    test:assertTrue(text.includes("body: {\"a\":1}"), text);
    test:assertFalse(text.includes("cookie:"), text);
    test:assertFalse(text.includes("x-forwarded-for:"), text);
    test:assertFalse(text.includes("origin:"), text);
    test:assertEquals(headerOf(res, "Access-Control-Allow-Origin"), ORIGIN);
}

@test:Config
function testResponseHeadersAreCleanedAndCorsIsOurs() returns error? {
    http:Response res = check call("GET", UP + "/headers");
    test:assertEquals(res.statusCode, 200);
    test:assertEquals(headerOf(res, "Set-Cookie"), ());
    test:assertEquals(headerOf(res, "Access-Control-Allow-Credentials"), ());
    test:assertEquals(headerOf(res, "X-Custom"), "yes");
    test:assertEquals(headerOf(res, "WWW-Authenticate"), "Bearer realm=\"mcp\"");
    test:assertEquals(res.getHeaders("Access-Control-Allow-Origin"), [ORIGIN]);
    test:assertEquals(headerOf(res, "Access-Control-Expose-Headers"), "mcp-session-id, www-authenticate");
}

@test:Config
function testTargetStatusesPassThrough() returns error? {
    http:Response missing = check call("GET", UP + "/missing");
    test:assertEquals(missing.statusCode, 404);
    test:assertEquals(check missing.getTextPayload(), "nothing here");
}

@test:Config
function testRedirectIsFollowedAndTheAnswerHasCors() returns error? {
    http:Response res = check call("GET", UP + "/redirect");
    test:assertEquals(res.statusCode, 200);
    test:assertTrue((check res.getTextPayload()).startsWith("GET /echo\n"));
    test:assertEquals(headerOf(res, "Access-Control-Allow-Origin"), ORIGIN);
    test:assertFalse(res.hasHeader("Location"));
}

@test:Config
function testRedirectToABlockedAddressIsAn502WithCors() returns error? {
    http:Response res = check call("GET", UP + "/to?status=302&location=http%3A%2F%2F10.0.0.1%2F");
    check assertError(res, 502, "Redirect target is not allowed");
    test:assertEquals(headerOf(res, "Access-Control-Allow-Origin"), ORIGIN);
}

@test:Config
function testCredentialsFollowARedirectOnlyOnTheSameHost() returns error? {
    http:Response same = check call("GET", UP + "/redirect", {"Authorization": "Bearer abc", "X-Api-Key": "key-1"});
    string sameText = check same.getTextPayload();
    test:assertTrue(sameText.includes("authorization: Bearer abc") && sameText.includes("x-api-key: key-1"), sameText);
    http:Response other = check call("GET", UP + "/to?status=307&location=http%3A%2F%2Flocalhost%3A9301%2Fecho", {"Authorization": "Bearer abc", "X-Api-Key": "key-1"});
    string otherText = check other.getTextPayload();
    test:assertTrue(otherText.startsWith("GET /echo\n"), otherText);
    test:assertFalse(otherText.includes("authorization") || otherText.includes("x-api-key"), otherText);
}

@test:Config
function testLargeResponseIsRelayedWhole() returns error? {
    http:Response res = check call("GET", UP + "/big");
    test:assertEquals(res.statusCode, 200);
    test:assertEquals((check res.getTextPayload()).length(), 2000);
}

@test:Config
function testStalledTargetIsA504() returns error? {
    decimal started = time:monotonicNow();
    check assertError(check call("GET", UP + "/stall"), 504, "Upstream timed out");
    test:assertTrue(time:monotonicNow() - started < 4d);
}

@test:Config
function testEventsAreStreamedAsTheyArrive() returns error? {
    decimal started = time:monotonicNow();
    http:Response res = check call("GET", UP + "/events");
    stream<http:SseEvent, error?> events = check res.getSseEventStream();
    record {|http:SseEvent value;|}? first = check events.next();
    decimal firstAfter = time:monotonicNow() - started;
    if first is () {
        test:assertFail("no event arrived");
    }
    test:assertEquals(first.value.data, "event 1");
    int count = 1;
    while (check events.next()) is record {|http:SseEvent value;|} {
        count += 1;
    }
    decimal lastAfter = time:monotonicNow() - started;
    test:assertEquals(count, 4);
    test:assertTrue(firstAfter < 0.3d, "first event after " + firstAfter.toString());
    test:assertTrue(lastAfter > 1d, "last event after " + lastAfter.toString());
}

@test:Config
function testBodyWithinTheLimitIsRelayed() returns error? {
    http:Response res = check call("POST", UP + "/echo", {}, "".padEnd(900, "x"));
    test:assertEquals(res.statusCode, 200);
}

@test:Config
function testBodyOverTheLimitGetsA413WithCors() returns error? {
    http:Response res = check call("POST", UP + "/echo", {}, "".padEnd(1500, "x"));
    check assertError(res, 413, "Request body too large");
    test:assertEquals(headerOf(res, "Access-Control-Allow-Origin"), ORIGIN);
}

@test:Config
function testBodyOverTheTransportLimitIsRejected() returns error? {
    http:Response res = check call("POST", UP + "/echo", {}, "".padEnd(3000, "x"));
    test:assertEquals(res.statusCode, 413);
    test:assertEquals(headerOf(res, "Content-Type"), ());
    test:assertEquals(headerOf(res, "Access-Control-Allow-Origin"), ());
}

@test:Config
function testOneCallerIsNotLimitedOnItsOwn() returns error? {
    foreach int i in 0 ..< 20 {
        test:assertEquals((check call("GET", UP + "/echo")).statusCode, 200, i.toString());
    }
}

@test:Config
function testEveryoneTogetherIsLimitedAndTheAnswerHasCors() returns error? {
    _ = stats.take();
    future<http:Response|error>[] calls = [];
    foreach int i in 0 ..< 250 {
        future<http:Response|error> pending = start call("GET", ());
        calls.push(pending);
    }
    int limited = 0;
    http:Response? sample = ();
    foreach future<http:Response|error> pending in calls {
        http:Response|error res = check wait pending;
        if res is http:Response && res.statusCode == 429 {
            limited += 1;
            sample = res;
        }
    }
    test:assertTrue(limited >= 50, "limited " + limited.toString());
    if sample is () {
        test:assertFail("no request was limited");
    }
    check assertError(sample, 429, "Too many requests");
    test:assertEquals(headerOf(sample, "Retry-After"), "60");
    test:assertEquals(headerOf(sample, "Access-Control-Allow-Origin"), ORIGIN);
    assertStandardHeaders(sample);
    runtime:sleep(1.5);
    Window window = stats.take();
    test:assertEquals(window.requests, 250);
    test:assertEquals(window.rateLimited, limited);
    test:assertEquals(window.inFlight, 0);
}

function assertStandardHeaders(http:Response res) {
    test:assertEquals(headerOf(res, "X-Content-Type-Options"), "nosniff");
    test:assertEquals(headerOf(res, "Referrer-Policy"), "no-referrer");
}

@test:Config
function testEveryResponseCarriesTheStandardHeaders() returns error? {
    assertStandardHeaders(check call("GET", UP + "/echo"));
    assertStandardHeaders(check call("GET", UP + "/missing"));
    assertStandardHeaders(check call("OPTIONS", ()));
    assertStandardHeaders(check call("PATCH", UP + "/echo"));
    assertStandardHeaders(check call("GET", UP + "/echo", {"Origin": "https://evil.com"}));
}

@test:Config
function testOurOwnErrorsAreNeverCached() returns error? {
    foreach http:Response res in [
        check call("PATCH", UP + "/echo"),
        check call("GET", ()),
        check call("GET", "http://10.0.0.1/mcp")
    ] {
        test:assertEquals(headerOf(res, "Cache-Control"), "no-store");
    }
    test:assertEquals(headerOf(check call("GET", UP + "/echo"), "Cache-Control"), ());
}

@test:Config
function testTheTargetsVaryHeaderIsKeptAndOursIsAdded() returns error? {
    http:Response res = check call("GET", UP + "/headers");
    string[] vary = check res.getHeaders("Vary");
    string joined = string:'join(", ", ...vary);
    test:assertTrue(joined.includes("Accept-Encoding"), joined);
    test:assertTrue(joined.includes("Origin, Access-Control-Request-Headers"), joined);
}

function rawRequest(string request) returns string|error {
    tcp:Client socket = check new ("localhost", 9300, timeout = 10);
    check socket->writeBytes(request.toBytes());
    string response = "";
    while true {
        readonly & byte[]|tcp:Error chunk = socket->readBytes();
        if chunk is tcp:Error {
            break;
        }
        response += check string:fromBytes(chunk);
    }
    check socket->close();
    return response;
}

@test:Config
function testHeadersNamedByConnectionDoNotReachTheTarget() returns error? {
    string target = check url:encode(UP + "/echo", "UTF-8");
    string response = check rawRequest("POST /?target=" + target + " HTTP/1.1\r\nHost: x\r\nOrigin: " + ORIGIN
            + "\r\nConnection: close, X-Secret-Hop\r\nX-Secret-Hop: 1\r\nX-Keep: yes\r\nContent-Length: 5\r\n\r\nhello");
    test:assertTrue(response.startsWith("HTTP/1.1 200"), response);
    test:assertTrue(response.includes("x-keep: yes"), response);
    test:assertFalse(response.toLowerAscii().includes("x-secret-hop"), response);
}

@test:Config
function testExpectContinueWithTheBodySentAtOnceIsAnswered() returns error? {
    string target = check url:encode(UP + "/echo", "UTF-8");
    string response = check rawRequest("POST /?target=" + target + " HTTP/1.1\r\nHost: x\r\nOrigin: " + ORIGIN
            + "\r\nConnection: close\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello");
    test:assertTrue(response.includes("HTTP/1.1 200"), response);
    test:assertTrue(response.includes("body: hello"), response);
    test:assertFalse(response.toLowerAscii().includes("expect:"), response);
}

@test:Config
function testExpectContinueFromAClientThatWaitsStillWorks() returns error? {
    http:Response res = check call("POST", UP + "/echo", {"Expect": "100-continue"}, "hello");
    test:assertEquals(res.statusCode, 200);
    test:assertTrue((check res.getTextPayload()).includes("body: hello"));
}

@test:Config
function testMalformedPercentEncodingInTheQueryIsABadRequest() returns error? {
    string response = check rawRequest("GET /?target=%ZZ HTTP/1.1\r\nHost: x\r\nOrigin: " + ORIGIN + "\r\nConnection: close\r\n\r\n");
    test:assertTrue(response.startsWith("HTTP/1.1 400"), response);
    test:assertTrue(response.includes("{\"error\":\"Invalid target URL\"}"), response);
    test:assertTrue(response.includes("Access-Control-Allow-Origin: " + ORIGIN), response);
}

@test:Config
function testLongTargetUrlsAreAccepted() returns error? {
    http:Response res = check call("GET", UP + "/missing?x=" + "".padEnd(6000, "q"));
    test:assertEquals(res.statusCode, 404);
    test:assertEquals(check res.getTextPayload(), "nothing here");
}

@test:Config
function testIllegalCharactersAreEscapedOnTheWire() returns error? {
    http:Response res = check call("GET", UP + "/echo?q=ü|{x}\"");
    test:assertEquals(res.statusCode, 200);
    string text = check res.getTextPayload();
    test:assertTrue(text.includes("q=%C3%BC%7C%7Bx%7D%22"), text);
}

@test:Config
function testResponsesAreNeverCompressed() returns error? {
    string target = check url:encode(UP + "/echo", "UTF-8");
    string response = check rawRequest("GET /?target=" + target + " HTTP/1.1\r\nHost: x\r\nOrigin: " + ORIGIN
            + "\r\nConnection: close\r\nAccept-Encoding: gzip, deflate, br\r\n\r\n");
    test:assertTrue(response.startsWith("HTTP/1.1 200"), response);
    test:assertFalse(response.toLowerAscii().includes("content-encoding"), response);
    test:assertTrue(response.includes("GET /echo"), response);
    string refusal = check rawRequest("GET /?target=" + target + " HTTP/1.1\r\nHost: x\r\nOrigin: https://evil.example\r\nConnection: close\r\nAccept-Encoding: gzip\r\n\r\n");
    test:assertFalse(refusal.toLowerAscii().includes("content-encoding"), refusal);
    test:assertTrue(refusal.includes("{\"error\":\"Origin not allowed\"}"), refusal);
}

@test:Config
function testCacheableStreamsAreStillStreamedLive() returns error? {
    decimal started = time:monotonicNow();
    http:Response res = check call("GET", UP + "/cacheable");
    test:assertTrue((headerOf(res, "Cache-Control") ?: "").includes("max-age=60"), headerOf(res, "Cache-Control") ?: "no header");
    stream<http:SseEvent, error?> events = check res.getSseEventStream();
    record {|http:SseEvent value;|}? first = check events.next();
    decimal firstAfter = time:monotonicNow() - started;
    if first is () {
        test:assertFail("no event arrived");
    }
    test:assertEquals(first.value.data, "event 1");
    test:assertTrue(firstAfter < 0.5d, "first event after " + firstAfter.toString());
}
