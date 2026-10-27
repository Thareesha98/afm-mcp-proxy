import ballerina/http;
import ballerina/test;
import ballerina/url;

function toLocation(int status, string location) returns string|error {
    return "/to?status=" + status.toString() + "&location=" + check url:encode(location, "UTF-8");
}

function echoOf(string path, string method = "GET", map<string|string[]> headers = {}, byte[] body = []) returns string|error {
    return textOf(sendTo(localTarget(path), method, headers, body));
}

const map<string|string[]> PLAIN = {
    "Accept": "application/json",
    "Accept-Language": "en",
    "Mcp-Protocol-Version": "2025-03-26",
    "Sec-Fetch-Mode": "cors",
    "X-Custom": "v"
};

const map<string|string[]> BROWSER = {
    "Accept": "text/plain",
    "Accept-Language": "en-GB,en-US;q=0.9",
    "Priority": "u=1, i",
    "Sec-Ch-Ua": "\"Google Chrome\";v=\"155\"",
    "Sec-Ch-Ua-Mobile": "?0",
    "Sec-Ch-Ua-Platform": "\"macOS\"",
    "Sec-Fetch-Dest": "empty",
    "Sec-Fetch-Mode": "cors",
    "Sec-Fetch-Site": "cross-site",
    "User-Agent": "Mozilla/5.0"
};

function shareLink(int hops, string file = "/file/text") returns string|error {
    string[] hosts = ["http://127.0.0.1:9301", "http://localhost:9301"];
    string path = file;
    int hop = hops;
    while hop >= 1 {
        path = check toLocation(302, hosts[hop % 2] + path);
        hop -= 1;
    }
    return path;
}

function assertNotFollowed(http:Response|RequestError result, string context) {
    assertForwardStatus(result, 502);
    if result is RequestError {
        test:assertEquals(result.message(), "The target answered with a redirect, which is not followed for a request with a body or credentials", context);
    }
}

@test:Config
function testRelativeRedirectIsFollowed() returns error? {
    string text = check echoOf("/redirect");
    test:assertTrue(text.startsWith("GET /echo\n"), text);
}

@test:Config
function testAFileComesThroughWithItsBodyAndContentTypeUnchanged() returns error? {
    http:Response text = check sendTo(localTarget("/file/text"));
    test:assertEquals(check text.getTextPayload(), SHARED_FILE);
    test:assertEquals(check text.getHeader("Content-Type"), SHARED_FILE_TYPE);
    http:Response binary = check sendTo(localTarget("/file/binary"));
    test:assertEquals(check binary.getBinaryPayload(), allByteValues());
    test:assertEquals(check binary.getHeader("Content-Type"), "application/octet-stream");
}

@test:Config
function testAShareLinkIsFollowedThroughUpToThreeHosts() returns error? {
    foreach int hops in [1, 2, 3] {
        http:Response res = check sendTo(localTarget(check shareLink(hops)), "GET", BROWSER);
        test:assertEquals(check res.getTextPayload(), SHARED_FILE, hops.toString());
        test:assertEquals(check res.getHeader("Content-Type"), SHARED_FILE_TYPE, hops.toString());
        http:Response binary = check sendTo(localTarget(check shareLink(hops, "/file/binary")), "GET", BROWSER);
        test:assertEquals(check binary.getBinaryPayload(), allByteValues(), hops.toString());
        test:assertEquals(check binary.getHeader("Content-Type"), "application/octet-stream", hops.toString());
    }
    http:Response|RequestError tooMany = sendTo(localTarget(check shareLink(4)), "GET", BROWSER);
    assertForwardStatus(tooMany, 502);
    if tooMany is RequestError {
        test:assertEquals(tooMany.message(), "Too many redirects");
    }
}

@test:Config
function testTheHeadersOfARealBrowserDoNotStopARedirectAndAreTrimmedForAnotherHost() returns error? {
    string text = check echoOf(check shareLink(2, "/echo"), "GET", BROWSER);
    test:assertTrue(text.startsWith("GET /echo\n"), text);
    foreach string line in ["accept: text/plain", "accept-language: en-GB,en-US;q=0.9", "user-agent: Mozilla/5.0"] {
        test:assertTrue(text.includes(line), line + " in " + text);
    }
    foreach string name in ["sec-fetch-mode", "sec-ch-ua", "priority"] {
        test:assertFalse(text.includes(name + ":"), name + " was sent to another host: " + text);
    }
    string sameHost = check echoOf("/redirect", "GET", BROWSER);
    test:assertTrue(sameHost.includes("sec-fetch-mode: cors"), sameHost);
}

@test:Config
function testACookieSetByARedirectIsNotSentOnTheNextHop() returns error? {
    string text = check echoOf("/cookiehop?to=%2Fecho");
    test:assertTrue(text.startsWith("GET /echo\n"), text);
    test:assertFalse(text.includes("cookie:"), text);
}

@test:Config
function testPlainGetIsFollowedForEveryRedirectStatus() returns error? {
    foreach string location in ["/echo", "http://localhost:9301/echo"] {
        foreach int status in [301, 302, 303, 307, 308] {
            string text = check echoOf(check toLocation(status, location), "GET", PLAIN);
            test:assertTrue(text.startsWith("GET /echo\n"), text);
        }
    }
}

@test:Config
function testNothingButAPlainGetIsEverRedirected() returns error? {
    byte[][] bodies = [
        [],
        "grant_type=refresh_token&refresh_token=FAKE_AUDIT_REFRESH_TOKEN&client_secret=FAKE_SECRET".toBytes(),
        "grant_type=authorization_code&code=FAKE_CODE&code_verifier=FAKE_VERIFIER".toBytes(),
        "{\"tool_data\":\"FAKE_PRIVATE_DATA\"}".toBytes()
    ];
    foreach string location in ["/mark", "http://localhost:9301/mark"] {
        foreach int status in [301, 302, 303, 307, 308] {
            int before = markCount();
            foreach string method in ["POST", "DELETE"] {
                foreach byte[] body in bodies {
                    string context = string `${method} with ${body.length()} bytes, ${status} to ${location}`;
                    assertNotFollowed(sendTo(localTarget(check toLocation(status, location)), method, {"Content-Type": "text/plain"}, body), context);
                }
            }
            test:assertEquals(markCount(), before, string `${status} to ${location}`);
        }
    }
}

@test:Config
function testGetWithACredentialIsNotFollowedEvenOnTheSameHost() returns error? {
    foreach string name in ["Authorization", "X-Api-Key", "Mcp-Session-Id", "X-Auth-Token", "Api-Key", "Ocp-Apim-Subscription-Key", "X-Custom-Api-Key"] {
        foreach string location in ["/mark", "http://localhost:9301/mark"] {
            foreach int status in [301, 302, 303, 307, 308] {
                int before = markCount();
                string context = string `${name}, ${status} to ${location}`;
                assertNotFollowed(sendTo(localTarget(check toLocation(status, location)), "GET", {"Accept": "application/json", [name]: "secret"}), context);
                test:assertEquals(markCount(), before, context);
            }
        }
    }
}

@test:Config
function testGetWithABodyIsNotFollowed() returns error? {
    foreach string location in ["/mark", "http://localhost:9301/mark"] {
        foreach int status in [301, 302, 303, 307, 308] {
            int before = markCount();
            string context = string `GET with a body, ${status} to ${location}`;
            assertNotFollowed(sendTo(localTarget(check toLocation(status, location)), "GET", {}, "hello".toBytes()), context);
            test:assertEquals(markCount(), before, context);
        }
    }
}

@test:Config
function testPlainHeadersStayOnTheSameHost() returns error? {
    string text = check echoOf("/redirect", "GET", PLAIN);
    foreach string line in ["accept: application/json", "accept-language: en", "mcp-protocol-version: 2025-03-26", "sec-fetch-mode: cors", "x-custom: v", "host: 127.0.0.1:9301"] {
        test:assertTrue(text.includes(line), line + " in " + text);
    }
}

@test:Config
function testOnlyTheSafeHeadersGoToAnotherHost() returns error? {
    string text = check echoOf(check toLocation(307, "http://localhost:9301/echo"), "GET", PLAIN);
    test:assertTrue(text.includes("accept: application/json"), text);
    test:assertTrue(text.includes("host: localhost:9301"), text);
    foreach string name in ["sec-fetch-mode", "x-custom"] {
        test:assertFalse(text.includes(name), name + " was sent to another host: " + text);
    }
}

@test:Config
function testHeadersStayDroppedWhenTheRedirectComesBack() returns error? {
    string back = check toLocation(307, "http://127.0.0.1:9301/echo");
    string text = check echoOf(check toLocation(307, "http://localhost:9301" + back), "GET", PLAIN);
    test:assertTrue(text.startsWith("GET /echo\n"), text);
    test:assertTrue(text.includes("host: 127.0.0.1:9301"), text);
    test:assertFalse(text.includes("x-custom"), text);
}

@test:Config
function testSameHostAndPortKeepsThePlainHeaders() returns error? {
    string text = check echoOf(check toLocation(307, "http://127.0.0.1:9301/echo"), "GET", PLAIN);
    test:assertTrue(text.includes("x-custom: v"), text);
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
    foreach int hops in [1, 2, 3] {
        test:assertTrue((check echoOf("/chain/" + hops.toString())).startsWith("GET /chain/0\n"), hops.toString());
    }
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
function testEveryHopIsCheckedAgain() returns error? {
    foreach string blocked in ["http://10.0.0.1/", "https://169.254.169.254/", "http://127.0.0.1:9399/echo", "https://example.com:8443/", "https://192.168.1.1/", "https://172.16.0.1/", "https://100.64.0.1/", "https://no-such-host.invalid/"] {
        string second = check toLocation(302, blocked);
        http:Response|RequestError result = sendTo(localTarget(check toLocation(302, second)));
        assertForwardStatus(result, 502);
        if result is RequestError {
            test:assertEquals(result.message(), "Redirect target is not allowed", blocked);
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
    http:Response postBare = check sendTo(localTarget("/bare"), "POST", {}, "hello".toBytes());
    test:assertEquals(postBare.statusCode, 302);
    http:Response postChoices = check sendTo(localTarget(check toLocation(300, "/mark")), "POST", {}, "hello".toBytes());
    test:assertEquals(postChoices.statusCode, 300);
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
    test:assertFalse(isRedirect(bare));
    bare.setHeader("Location", "");
    test:assertEquals(redirectLocation(bare), ());
    test:assertTrue(isRedirect(bare));
    http:Response twice = new;
    twice.statusCode = 307;
    twice.addHeader("Location", "");
    twice.addHeader("Location", "https://other.example/");
    test:assertTrue(isRedirect(twice));
}

@test:Config
function testOnlyAPlainGetMayBeRedirected() {
    byte[] none = [];
    byte[] some = "x".toBytes();
    test:assertTrue(mayFollowRedirects("GET", {}, none));
    test:assertTrue(mayFollowRedirects("GET", PLAIN, none));
    test:assertTrue(mayFollowRedirects("GET", {"Sec-CH-UA": "x", "Priority": "u=1", "Last-Event-ID": "5", "Cache-Control": "no-cache", "Upgrade-Insecure-Requests": "1", "Host": "h"}, none));
    foreach string method in ["POST", "DELETE", "PUT", "PATCH", "HEAD"] {
        test:assertFalse(mayFollowRedirects(method, {}, none), method);
        test:assertFalse(mayFollowRedirects(method, {}, some), method);
    }
    test:assertFalse(mayFollowRedirects("GET", {}, some));
    foreach string name in [
        "Authorization",
        "AUTHORIZATION",
        "Proxy-Authorization",
        "X-Api-Key",
        "Api-Key",
        "apikey",
        "X-Auth-Token",
        "X-Access-Token",
        "X-Amz-Security-Token",
        "Ocp-Apim-Subscription-Key",
        "Mcp-Session-Id",
        "X-Client-Secret",
        "Cookie",
        "X-Password",
        "X-Credentials"
    ] {
        test:assertFalse(mayFollowRedirects("GET", {"Accept": "*/*", [name]: "v"}, none), name);
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
    map<string|string[]> headers = {"Host": "old", "Accept": "*/*", "X-Custom": "v", "X-Many": ["1", "2"], "Sec-Fetch-Mode": "cors"};
    map<string|string[]> result = redirectHeaders(headers, target("https", "new.example", 443, "/"), true);
    test:assertEquals(result, {"Accept": "*/*", "X-Custom": "v", "X-Many": ["1", "2"], "Sec-Fetch-Mode": "cors", "Host": "new.example"});
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
    map<string|string[]> result = redirectHeaders(headers, target("https", "new.example", 8443, "/"), false);
    test:assertEquals(result.keys().sort(), ["Accept", "Accept-Language", "Content-Type", "Host", "Mcp-Protocol-Version", "User-Agent", "accept-encoding"]);
    test:assertEquals(result["Host"], "new.example:8443");
}
