import ballerina/http;
import ballerina/lang.runtime;
import ballerina/test;
import ballerina/time;

Target publicTarget = {scheme: "https", host: "api.example.com", port: 443, pathAndQuery: "/mcp", addresses: ["8.8.8.8"]};

function localTarget(string pathAndQuery, string[] addresses = ["127.0.0.1"], int port = 9301) returns Target {
    return {scheme: "http", host: "127.0.0.1", port, pathAndQuery, addresses};
}

function hasHeader(map<string|string[]> headers, string name) returns boolean {
    return headers.keys().some(key => key.toLowerAscii() == name.toLowerAscii());
}

function sendTo(Target target, string method = "GET", map<string|string[]> headers = {}, byte[] body = []) returns http:Response|RequestError {
    return forward(target, method, headers, body, 10);
}

function textOf(http:Response|RequestError result) returns string|error {
    if result is http:Response {
        return result.getTextPayload();
    }
    return result;
}

function assertForwardStatus(http:Response|RequestError result, int status) {
    if result is RequestError {
        test:assertEquals(result.detail().status, status);
    } else {
        test:assertFail("expected an error but got status " + result.statusCode.toString());
    }
}

@test:Config
function testUpstreamConnectionIsClosedAfterTheResponse() returns error? {
    int before = closedCount();
    http:Response res = check sendTo(localTarget("/", port = 9302));
    test:assertEquals(check res.getTextPayload(), "ok");
    runtime:sleep(1);
    test:assertEquals(closedCount(), before + 1);
}

@test:Config
function testRequestHeadersAreFiltered() {
    http:Request req = new;
    foreach string name in ["Authorization", "X-Custom", "Content-Type", "Mcp-Session-Id"] {
        req.setHeader(name, "keep");
    }
    foreach string name in [
        "Cookie",
        "Origin",
        "Referer",
        "Content-Length",
        "Connection",
        "Keep-Alive",
        "Proxy-Authenticate",
        "Proxy-Authorization",
        "TE",
        "Trailer",
        "Transfer-Encoding",
        "Upgrade",
        "Forwarded",
        "Via",
        "X-Real-IP",
        "X-Client-IP",
        "Client-IP",
        "X-Amzn-Trace-Id",
        "X-Forwarded-For",
        "X-Forwarded-Host",
        "X-Forwarded-Proto",
        "Host"
    ] {
        req.setHeader(name, "drop");
    }
    map<string|string[]> headers = requestHeaders(req, publicTarget);
    foreach string name in ["Authorization", "X-Custom", "Content-Type", "Mcp-Session-Id"] {
        test:assertTrue(hasHeader(headers, name), name);
    }
    foreach string name in [
        "Cookie",
        "Origin",
        "Referer",
        "Content-Length",
        "Connection",
        "Keep-Alive",
        "Proxy-Authenticate",
        "Proxy-Authorization",
        "TE",
        "Trailer",
        "Transfer-Encoding",
        "Upgrade",
        "Forwarded",
        "Via",
        "X-Real-IP",
        "X-Client-IP",
        "Client-IP",
        "X-Amzn-Trace-Id",
        "X-Forwarded-For",
        "X-Forwarded-Host",
        "X-Forwarded-Proto"
    ] {
        test:assertFalse(hasHeader(headers, name), name);
    }
}

@test:Config
function testExpectAndProxyOnlyHeadersAreNotForwarded() {
    http:Request req = new;
    foreach string name in ["Expect", "Proxy-Connection", "HTTP2-Settings", "X-Keep"] {
        req.setHeader(name, "value");
    }
    map<string|string[]> headers = requestHeaders(req, publicTarget);
    test:assertTrue(hasHeader(headers, "X-Keep"));
    foreach string name in ["Expect", "Proxy-Connection", "HTTP2-Settings"] {
        test:assertFalse(hasHeader(headers, name), name);
    }
}

@test:Config
function testHeadersNamedByTheConnectionHeaderAreNotForwarded() {
    http:Request req = new;
    req.addHeader("Connection", "close, X-Hop-One");
    req.addHeader("Connection", "x-hop-two");
    req.setHeader("X-HOP-ONE", "1");
    req.setHeader("X-Hop-Two", "2");
    req.setHeader("X-Hop-Three", "3");
    req.setHeader("Authorization", "Bearer abc");
    map<string|string[]> headers = requestHeaders(req, publicTarget);
    test:assertFalse(hasHeader(headers, "X-Hop-One"));
    test:assertFalse(hasHeader(headers, "X-Hop-Two"));
    test:assertTrue(hasHeader(headers, "X-Hop-Three"));
    test:assertTrue(hasHeader(headers, "Authorization"));
}

@test:Config
function testHostAndEncodingAreSetForTheTarget() {
    http:Request req = new;
    req.setHeader("Host", "proxy.example.org");
    req.setHeader("Accept-Encoding", "gzip, deflate");
    map<string|string[]> headers = requestHeaders(req, publicTarget);
    test:assertEquals(headers["Host"], "api.example.com");
    test:assertEquals(headers["Accept-Encoding"], "identity");
    test:assertEquals(headers.keys().filter(key => key.toLowerAscii() == "accept-encoding").length(), 1);
    test:assertEquals(headers.keys().filter(key => key.toLowerAscii() == "host").length(), 1);
}

@test:Config
function testHostHeaderKeepsNonDefaultPortsOnly() {
    http:Request req = new;
    test:assertEquals(requestHeaders(req, {scheme: "https", host: "a.com", port: 8443, pathAndQuery: "/", addresses: []})["Host"], "a.com:8443");
    test:assertEquals(requestHeaders(req, {scheme: "https", host: "a.com", port: 443, pathAndQuery: "/", addresses: []})["Host"], "a.com");
    test:assertEquals(requestHeaders(req, {scheme: "http", host: "a.com", port: 80, pathAndQuery: "/", addresses: []})["Host"], "a.com");
    test:assertEquals(requestHeaders(req, {scheme: "http", host: "a.com", port: 443, pathAndQuery: "/", addresses: []})["Host"], "a.com:443");
}

@test:Config
function testMultiValuedHeadersAreKept() {
    http:Request req = new;
    req.addHeader("X-Multi", "a");
    req.addHeader("X-Multi", "b");
    test:assertEquals(requestHeaders(req, publicTarget)["X-Multi"], ["a", "b"]);
}

@test:Config
function testForwardRelaysMethodPathQueryAndBody() returns error? {
    string text = check textOf(sendTo(localTarget("/echo?x=1&y=2"), "POST", {"Content-Type": "application/json"}, "{\"a\":1}".toBytes()));
    test:assertTrue(text.includes("POST /echo?x=1&y=2"), text);
    test:assertTrue(text.includes("body: {\"a\":1}"), text);
    test:assertTrue(text.includes("content-type: application/json"), text);
}

@test:Config
function testForwardOfAGetSendsNoBody() returns error? {
    string text = check textOf(sendTo(localTarget("/echo")));
    test:assertTrue(text.startsWith("GET /echo"), text);
    test:assertTrue(text.endsWith("body: "), text);
}

@test:Config
function testForwardAlsoSupportsDelete() returns error? {
    string text = check textOf(sendTo(localTarget("/echo"), "DELETE"));
    test:assertTrue(text.startsWith("DELETE /echo"), text);
}

@test:Config
function testUpstreamSeesTheForwardedHeadersOnly() returns error? {
    http:Request req = new;
    req.setHeader("Authorization", "Bearer abc");
    req.setHeader("X-Custom", "yes");
    req.setHeader("Cookie", "session=1");
    req.setHeader("Origin", "https://app.example.com");
    req.setHeader("X-Forwarded-For", "6.6.6.6");
    req.setHeader("Accept-Encoding", "gzip");
    Target target = localTarget("/echo");
    string text = check textOf(sendTo(target, "GET", requestHeaders(req, target)));
    test:assertTrue(text.includes("authorization: Bearer abc"), text);
    test:assertTrue(text.includes("x-custom: yes"), text);
    test:assertTrue(text.includes("host: 127.0.0.1:9301"), text);
    test:assertTrue(text.includes("accept-encoding: identity"), text);
    foreach string name in ["cookie", "origin", "x-forwarded-for", "referer", "forwarded", "via"] {
        test:assertFalse(text.includes(name + ":"), name);
    }
}

@test:Config
function testExpectDoesNotDelayTheRequest() returns error? {
    http:Request req = new;
    req.setHeader("Expect", "100-continue");
    req.setHeader("Content-Type", "application/json");
    Target target = localTarget("/echo");
    decimal started = time:monotonicNow();
    string text = check textOf(sendTo(target, "POST", requestHeaders(req, target), "{\"a\":1}".toBytes()));
    test:assertTrue(time:monotonicNow() - started < 1d);
    test:assertFalse(text.includes("expect:"), text);
    test:assertTrue(text.includes("body: {\"a\":1}"), text);
}

@test:Config
function testStatusesAreRelayedAndRedirectsAreNotFollowed() returns error? {
    http:Response missing = check sendTo(localTarget("/missing"));
    test:assertEquals(missing.statusCode, 404);
    test:assertEquals(check missing.getTextPayload(), "nothing here");
    http:Response redirect = check sendTo(localTarget("/redirect"));
    test:assertEquals(redirect.statusCode, 302);
    test:assertEquals(check redirect.getHeader("Location"), "/echo");
}

@test:Config
function testForwardTriesTheNextAddressWhenOneFails() returns error? {
    Target target = localTarget("/echo", ["10.255.255.1", "127.0.0.1"]);
    http:Response res = check forward(target, "GET", {}, [], 10, 1);
    test:assertTrue((check res.getTextPayload()).startsWith("GET /echo"));
}

@test:Config
function testForwardReachesIpv6Addresses() returns error? {
    string text = check textOf(sendTo(localTarget("/echo", ["0:0:0:0:0:0:0:1"])));
    test:assertTrue(text.startsWith("GET /echo"), text);
}

@test:Config
function testForwardConnectsToTheValidatedAddressNotTheName() returns error? {
    Target target = {scheme: "http", host: "no-such-host.invalid", port: 9301, pathAndQuery: "/echo", addresses: ["127.0.0.1"]};
    string text = check textOf(sendTo(target, "GET", requestHeaders(new, target)));
    test:assertTrue(text.includes("host: no-such-host.invalid:9301"), text);
}

@test:Config
function testForwardFailsWhenNoAddressConnects() {
    assertForwardStatus(sendTo(localTarget("/echo", ["127.0.0.1", "0:0:0:0:0:0:0:1"], 1)), 502);
}

@test:Config
function testConnectTimeoutIsSeparateFromTheDeadline() {
    decimal started = time:monotonicNow();
    assertForwardStatus(forward(localTarget("/echo", ["10.255.255.1"]), "GET", {}, [], 30, 1), 502);
    test:assertTrue(time:monotonicNow() - started < 5d);
}

@test:Config
function testSlowResponseIsNotKilledByTheConnectTimeout() returns error? {
    http:Response res = check forward(localTarget("/slow"), "GET", {}, [], 10, 0.5);
    test:assertEquals(check res.getTextPayload(), "slow but fine");
}

@test:Config
function testResponseSlowerThanTheDeadlineIsA504() {
    decimal started = time:monotonicNow();
    assertForwardStatus(forward(localTarget("/slow"), "GET", {}, [], 1), 504);
    test:assertTrue(time:monotonicNow() - started < 3d);
}

@test:Config
function testNoTimeLeftIsA504() {
    assertForwardStatus(forward(localTarget("/echo"), "GET", {}, [], 0), 504);
}

@test:Config
function testResponseHeadersAreCleaned() returns error? {
    http:Response res = prepareResponse(check sendTo(localTarget("/headers")));
    string[] names = res.getHeaderNames().map(name => name.toLowerAscii());
    foreach string name in [
        "set-cookie",
        "keep-alive",
        "proxy-authenticate",
        "access-control-allow-origin",
        "access-control-allow-credentials"
    ] {
        test:assertTrue(names.indexOf(name) is (), name);
    }
    test:assertEquals(check res.getHeader("X-Custom"), "yes");
    test:assertEquals(check res.getHeader("WWW-Authenticate"), "Bearer realm=\"mcp\"");
    test:assertEquals(check res.getTextPayload(), "headers");
}

@test:Config
function testHeadersNamedByTheResponseConnectionHeaderAreRemoved() returns error? {
    http:Response res = new;
    res.setHeader("Connection", "close, X-Internal");
    res.setHeader("X-Internal", "secret");
    res.setHeader("X-Keep", "yes");
    res.setHeader("Proxy-Connection", "keep-alive");
    res.setHeader("HTTP2-Settings", "AAMAAABk");
    http:Response clean = prepareResponse(res);
    string[] names = clean.getHeaderNames().map(name => name.toLowerAscii());
    foreach string name in ["x-internal", "connection", "proxy-connection", "http2-settings"] {
        test:assertTrue(names.indexOf(name) is (), name);
    }
    test:assertEquals(check clean.getHeader("X-Keep"), "yes");
}

@test:Config {groups: ["network"]}
function testHttpsRequestIsPinnedToTheValidatedAddress() returns error? {
    Target target = check checkTarget("https://example.com/", false);
    http:Response res = check forward(target, "GET", requestHeaders(new, target), [], 20);
    test:assertEquals(res.statusCode, 200);
}

@test:Config {groups: ["network"]}
function testHttpsCertificateMustMatchTheHostname() returns error? {
    Target real = check checkTarget("https://example.com/", false);
    Target wrongName = {scheme: "https", host: "wrong.host.badssl.com", port: 443, pathAndQuery: "/", addresses: real.addresses};
    assertForwardStatus(forward(wrongName, "GET", requestHeaders(new, wrongName), [], 20), 502);
}
