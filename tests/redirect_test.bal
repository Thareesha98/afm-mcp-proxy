import ballerina/http;
import ballerina/test;
import ballerina/url;

function toLocation(int status, string location) returns string|error {
    return "/to?status=" + status.toString() + "&location=" + check url:encode(location, "UTF-8");
}

function echoOf(string path, string method = "GET", map<string|string[]> headers = {}, byte[] body = []) returns string|error {
    return textOf(sendTo(localTarget(path), method, headers, body));
}

const map<string|string[]> CREDENTIALS = {
    "Authorization": "Bearer secret-token",
    "X-Api-Key": "key-1",
    "Mcp-Session-Id": "session-1",
    "Accept": "application/json"
};

@test:Config
function testRelativeRedirectIsFollowed() returns error? {
    string text = check echoOf("/redirect");
    test:assertTrue(text.startsWith("GET /echo\n"), text);
}

@test:Config
function testRedirectKeepsMethodAndBodyFor307And308() returns error? {
    foreach int status in [307, 308] {
        string text = check echoOf(check toLocation(status, "/echo"), "POST", {"Content-Type": "text/plain"}, "hello".toBytes());
        test:assertTrue(text.startsWith("POST /echo\n"), text);
        test:assertTrue(text.includes("content-type: text/plain"), text);
        test:assertTrue(text.endsWith("body: hello"), text);
    }
}

@test:Config
function testPostBecomesGetAfter301302And303() returns error? {
    foreach int status in [301, 302, 303] {
        string text = check echoOf(check toLocation(status, "/echo"), "POST", {"Content-Type": "text/plain"}, "hello".toBytes());
        test:assertTrue(text.startsWith("GET /echo\n"), text);
        test:assertFalse(text.includes("content-type"), text);
        test:assertTrue(text.endsWith("body: "), text);
    }
}

@test:Config
function testDeleteStaysDeleteAfter302ButBecomesGetAfter303() returns error? {
    test:assertTrue((check echoOf(check toLocation(302, "/echo"), "DELETE")).startsWith("DELETE /echo\n"));
    test:assertTrue((check echoOf(check toLocation(303, "/echo"), "DELETE")).startsWith("GET /echo\n"));
}

@test:Config
function testAllHeadersStayOnTheSameHost() returns error? {
    string text = check echoOf("/redirect", "GET", CREDENTIALS);
    test:assertTrue(text.includes("authorization: Bearer secret-token"), text);
    test:assertTrue(text.includes("x-api-key: key-1"), text);
    test:assertTrue(text.includes("mcp-session-id: session-1"), text);
    test:assertTrue(text.includes("host: 127.0.0.1:9301"), text);
}

@test:Config
function testCredentialsAreDroppedOnAnotherHost() returns error? {
    string text = check echoOf(check toLocation(307, "http://localhost:9301/echo"), "GET", CREDENTIALS);
    test:assertTrue(text.includes("accept: application/json"), text);
    test:assertTrue(text.includes("host: localhost:9301"), text);
    foreach string name in ["authorization", "x-api-key", "mcp-session-id"] {
        test:assertFalse(text.includes(name), name + " was sent to another host: " + text);
    }
}

@test:Config
function testCredentialsStayDroppedWhenTheRedirectComesBack() returns error? {
    string back = check toLocation(307, "http://127.0.0.1:9301/echo");
    string text = check echoOf(check toLocation(307, "http://localhost:9301" + back), "GET", CREDENTIALS);
    test:assertTrue(text.startsWith("GET /echo\n"), text);
    test:assertTrue(text.includes("host: 127.0.0.1:9301"), text);
    test:assertFalse(text.includes("authorization"), text);
    test:assertFalse(text.includes("x-api-key"), text);
}

@test:Config
function testSameHostAndPortKeepsCredentials() returns error? {
    string text = check echoOf(check toLocation(307, "http://127.0.0.1:9301/echo"), "GET", CREDENTIALS);
    test:assertTrue(text.includes("authorization"), text);
}

@test:Config
function testLocationFormsAreResolvedAgainstTheCurrentUrl() returns error? {
    test:assertTrue((check echoOf(check toLocation(302, "echo"))).startsWith("GET /echo\n"));
    test:assertTrue((check echoOf(check toLocation(302, "/echo?a=1"))).startsWith("GET /echo?a=1\n"));
    test:assertTrue((check echoOf(check toLocation(302, "?a=1"))).startsWith("GET /to?a=1\n"));
    test:assertTrue((check echoOf(check toLocation(302, "//localhost:9301/echo"))).startsWith("GET /echo\n"));
    test:assertTrue((check echoOf(check toLocation(302, "/echo#section"))).startsWith("GET /echo\n"));
}

@test:Config
function testUpToThreeRedirectsAreFollowed() returns error? {
    test:assertTrue((check echoOf("/chain/3")).startsWith("GET /chain/0\n"));
    assertForwardStatus(sendTo(localTarget("/chain/4")), 502);
    assertForwardStatus(sendTo(localTarget("/loop")), 502);
}

@test:Config
function testRedirectLoopMessage() {
    http:Response|RequestError result = sendTo(localTarget("/loop"));
    test:assertTrue(result is RequestError);
    if result is RequestError {
        test:assertEquals(result.message(), "Too many redirects");
    }
}

@test:Config
function testRedirectToABlockedOrUnknownAddressIsRefused() returns error? {
    foreach string location in ["http://10.0.0.1/", "https://169.254.169.254/", "https://no-such-host.invalid/", "ftp://example.com/", "http://user@127.0.0.1/"] {
        http:Response|RequestError result = sendTo(localTarget(check toLocation(302, location)));
        assertForwardStatus(result, 502);
        if result is RequestError {
            test:assertEquals(result.message(), "Redirect target is not allowed", location);
        }
    }
}

@test:Config
function testRedirectWithoutLocationOrOfAnotherKindIsReturnedAsItIs() returns error? {
    http:Response bare = check sendTo(localTarget("/bare"));
    test:assertEquals(bare.statusCode, 302);
    test:assertFalse(bare.hasHeader("Location"));
    http:Response choices = check sendTo(localTarget(check toLocation(300, "/echo")));
    test:assertEquals(choices.statusCode, 300);
    test:assertEquals(check choices.getHeader("Location"), "/echo");
}

@test:Config
function testTimeLeftIsSharedByAllHops() returns error? {
    assertForwardStatus(forward(localTarget("/slowredirect"), "GET", {}, [], 2), 504);
    test:assertEquals(check textOf(forward(localTarget("/slowredirect"), "GET", {}, [], 10)), "slow but fine");
}

function target(string scheme, string host, int port, string pathAndQuery) returns Target {
    return {scheme, host, port, pathAndQuery, addresses: []};
}

@test:Config
function testLocationResolvesLikeRfc3986ForTheCommonForms() {
    Target base = target("http", "a", 80, "/b/c/d;p?q");
    map<string> expected = {
        "g:h": "g:h",
        "g": "http://a/b/c/g",
        "g/": "http://a/b/c/g/",
        "/g": "http://a/g",
        "//g": "http://g",
        "?y": "http://a/b/c/d;p?y",
        "g?y": "http://a/b/c/g?y",
        "#s": "http://a/b/c/d;p?q",
        "g#s": "http://a/b/c/g",
        "g?y#s": "http://a/b/c/g?y",
        ";x": "http://a/b/c/;x",
        "g;x": "http://a/b/c/g;x",
        "g;x?y#s": "http://a/b/c/g;x?y",
        "": "http://a/b/c/d;p?q",
        "g.": "http://a/b/c/g.",
        ".g": "http://a/b/c/.g",
        "g..": "http://a/b/c/g..",
        "..g": "http://a/b/c/..g",
        "g?y/./x": "http://a/b/c/g?y/./x",
        "g?y/../x": "http://a/b/c/g?y/../x",
        "g#s/./x": "http://a/b/c/g",
        "g#s/../x": "http://a/b/c/g",
        "http:g": "http:g",
        "https://x/y?z#f": "https://x/y?z"
    };
    foreach [string, string] [reference, want] in expected.entries() {
        test:assertEquals(resolveLocation(base, reference), want, "reference '" + reference + "'");
    }
}

@test:Config
function testDotSegmentsAreKeptAsWritten() {
    Target base = target("http", "a", 80, "/b/c/d;p?q");
    map<string> expected = {
        ".": "http://a/b/c/.",
        "./": "http://a/b/c/./",
        "./g": "http://a/b/c/./g",
        "..": "http://a/b/c/..",
        "../g": "http://a/b/c/../g",
        "../../g": "http://a/b/c/../../g",
        "/./g": "http://a/./g",
        "/../g": "http://a/../g",
        "g/./h": "http://a/b/c/g/./h"
    };
    foreach [string, string] [reference, want] in expected.entries() {
        test:assertEquals(resolveLocation(base, reference), want, "reference '" + reference + "'");
    }
}

@test:Config
function testLocationKeepsTheSchemeAndPortOfTheCurrentUrl() {
    test:assertEquals(resolveLocation(target("https", "h", 8443, "/p/q"), "/x"), "https://h:8443/x");
    test:assertEquals(resolveLocation(target("https", "h", 443, "/p/q"), "x"), "https://h/p/x");
    test:assertEquals(resolveLocation(target("https", "h", 443, "/p/q"), "//other/x"), "https://other/x");
    test:assertEquals(resolveLocation(target("http", "h", 80, "/"), "x"), "http://h/x");
    test:assertEquals(resolveLocation(target("https", "h", 443, "/mcp"), "/mcp/"), "https://h/mcp/");
}

@test:Config
function testHostHeaderLeavesOutTheDefaultPort() {
    test:assertEquals(hostHeader(target("https", "h", 443, "/")), "h");
    test:assertEquals(hostHeader(target("http", "h", 80, "/")), "h");
    test:assertEquals(hostHeader(target("https", "h", 8443, "/")), "h:8443");
    test:assertEquals(hostHeader(target("http", "h", 443, "/")), "h:443");
}

@test:Config
function testOnlyRedirectsWithALocationAreFollowed() {
    foreach int status in [301, 302, 303, 307, 308] {
        http:Response res = new;
        res.statusCode = status;
        res.setHeader("Location", "/next");
        test:assertEquals(redirectLocation(res), "/next", status.toString());
    }
    foreach int status in [200, 204, 300, 304, 305, 400, 404, 500] {
        http:Response res = new;
        res.statusCode = status;
        res.setHeader("Location", "/next");
        test:assertEquals(redirectLocation(res), (), status.toString());
    }
    http:Response bare = new;
    bare.statusCode = 302;
    test:assertEquals(redirectLocation(bare), ());
    bare.setHeader("Location", "");
    test:assertEquals(redirectLocation(bare), ());
}

@test:Config
function testWhichRedirectsTurnIntoGet() {
    foreach string method in ["GET", "POST", "DELETE", "PUT"] {
        test:assertTrue(turnsIntoGet(303, method), method);
        test:assertFalse(turnsIntoGet(307, method), method);
        test:assertFalse(turnsIntoGet(308, method), method);
    }
    foreach int status in [301, 302] {
        test:assertTrue(turnsIntoGet(status, "POST"));
        foreach string method in ["GET", "DELETE", "PUT"] {
            test:assertFalse(turnsIntoGet(status, method), status.toString() + " " + method);
        }
    }
}

@test:Config
function testOriginMeansSchemeHostAndPort() {
    Target base = target("https", "h", 443, "/a");
    test:assertTrue(sameOrigin(base, target("https", "h", 443, "/other")));
    test:assertFalse(sameOrigin(base, target("http", "h", 443, "/a")));
    test:assertFalse(sameOrigin(base, target("https", "other", 443, "/a")));
    test:assertFalse(sameOrigin(base, target("https", "h", 8443, "/a")));
}

@test:Config
function testSameHostKeepsEveryHeaderExceptTheHost() {
    map<string|string[]> headers = {"Host": "old", "authorization": "Bearer a", "X-Api-Key": "k", "X-Many": ["1", "2"], "Content-Type": "text/plain"};
    map<string|string[]> result = redirectHeaders(headers, target("https", "new.example", 443, "/"), true, true);
    test:assertEquals(result, {"authorization": "Bearer a", "X-Api-Key": "k", "X-Many": ["1", "2"], "Content-Type": "text/plain", "Host": "new.example"});
}

@test:Config
function testAnotherHostKeepsOnlyTheSafeHeaders() {
    map<string|string[]> headers = {
        "Host": "old",
        "AUTHORIZATION": "Bearer a",
        "X-Api-Key": "k",
        "Mcp-Session-Id": "s",
        "Cookie": "c=1",
        "X-Custom": "v",
        "Accept": "application/json",
        "accept-encoding": "identity",
        "Accept-Language": "en",
        "Content-Type": "application/json",
        "Mcp-Protocol-Version": "2025-03-26",
        "User-Agent": "agent"
    };
    map<string|string[]> result = redirectHeaders(headers, target("https", "new.example", 8443, "/"), false, true);
    test:assertEquals(result.keys().sort(), ["Accept", "Accept-Language", "Content-Type", "Host", "Mcp-Protocol-Version", "User-Agent", "accept-encoding"]);
    test:assertEquals(result["Host"], "new.example:8443");
}

@test:Config
function testBodyHeadersAreDroppedWhenTheBodyIs() {
    map<string|string[]> headers = {"Content-Type": "text/plain", "content-encoding": "gzip", "Content-Language": "en", "Content-Location": "/x", "Accept": "*/*"};
    map<string|string[]> result = redirectHeaders(headers, target("https", "h", 443, "/"), true, false);
    test:assertEquals(result, {"Accept": "*/*", "Host": "h"});
}
