import ballerina/test;

const string[] ORIGINS = ["https://app.example.com", "http://localhost:5173"];

@test:Config
function testCorsEchoesAnAllowedOrigin() {
    map<string> headers = corsHeaders(ORIGINS, "https://app.example.com", ());
    test:assertEquals(headers["Access-Control-Allow-Origin"], "https://app.example.com");
    headers = corsHeaders(ORIGINS, "http://localhost:5173", ());
    test:assertEquals(headers["Access-Control-Allow-Origin"], "http://localhost:5173");
}

@test:Config
function testCorsOmitsAllowOriginForOtherOrigins() {
    foreach string? origin in [(), "", "null", "https://evil.com", "https://app.example.com/", "https://app.example.com.evil.com"] {
        map<string> headers = corsHeaders(ORIGINS, origin, ());
        test:assertFalse(headers.hasKey("Access-Control-Allow-Origin"), origin.toString());
        test:assertTrue(headers.hasKey("Access-Control-Allow-Methods"));
    }
}

@test:Config
function testCorsNeverProducesAWildcard() {
    foreach string? origin in ["*", "https://*.example.com", "https://app.example.com"] {
        map<string> headers = corsHeaders(ORIGINS, origin, "*");
        test:assertNotEquals(headers["Access-Control-Allow-Origin"], "*");
    }
}

@test:Config
function testCorsAllowedHeaders() {
    test:assertEquals(corsHeaders(ORIGINS, "https://app.example.com", "authorization, x-custom")["Access-Control-Allow-Headers"],
            "authorization, x-custom");
    string defaults = "authorization, content-type, mcp-session-id, mcp-protocol-version, last-event-id";
    test:assertEquals(corsHeaders(ORIGINS, "https://app.example.com", ())["Access-Control-Allow-Headers"], defaults);
    test:assertEquals(corsHeaders(ORIGINS, "https://app.example.com", "")["Access-Control-Allow-Headers"], defaults);
}

@test:Config
function testCorsFixedHeaders() {
    map<string> headers = corsHeaders(ORIGINS, "https://app.example.com", ());
    test:assertEquals(headers["Access-Control-Allow-Methods"], "GET, POST, DELETE, OPTIONS");
    test:assertEquals(headers["Access-Control-Expose-Headers"], "mcp-session-id, www-authenticate");
    test:assertEquals(headers["Access-Control-Max-Age"], "600");
    test:assertEquals(headers["Vary"], "Origin, Access-Control-Request-Headers");
}

function gate(string method, string? target) returns Target|RequestError {
    return checkRequest(method, target, false, [443]);
}

function assertRequestStatus(Target|RequestError result, int status) {
    if result is RequestError {
        test:assertEquals(result.detail().status, status);
    } else {
        test:assertFail("expected an error but the request was accepted");
    }
}

@test:Config
function testOnlyGetPostAndDeleteAreAllowed() {
    foreach string method in ["PATCH", "PUT", "HEAD", "TRACE", "CONNECT", "get", ""] {
        assertRequestStatus(gate(method, "https://8.8.8.8"), 405);
    }
    foreach string method in ["GET", "POST", "DELETE"] {
        test:assertTrue(gate(method, "https://8.8.8.8") is Target, method);
    }
}

@test:Config
function testOriginMustMatchExactly() {
    foreach string? origin in [
        (),
        "",
        "null",
        "*",
        "https://app.example.com/",
        "http://app.example.com",
        "https://app.example.com:8443",
        "https://app.example.com.evil.com",
        "HTTPS://APP.EXAMPLE.COM",
        "https://evil.com"
    ] {
        test:assertFalse(isAllowedOrigin(ORIGINS, origin), origin.toString());
    }
}

@test:Config
function testBothConfiguredOriginsAreAccepted() {
    test:assertTrue(isAllowedOrigin(ORIGINS, "https://app.example.com"));
    test:assertTrue(isAllowedOrigin(ORIGINS, "http://localhost:5173"));
}

@test:Config
function testTargetIsRequired() {
    assertRequestStatus(gate("GET", ()), 400);
    assertRequestStatus(gate("GET", ""), 400);
}

@test:Config
function testChecksRunInOrder() {
    assertRequestStatus(gate("PATCH", ()), 405);
    assertRequestStatus(gate("GET", ()), 400);
    assertRequestStatus(gate("GET", "not a url"), 400);
    assertRequestStatus(gate("GET", "https://no-such-host.invalid"), 502);
}

@test:Config
function testSettingsReachTheTargetCheck() {
    string target = "http://127.0.0.1:3000/mcp";
    assertRequestStatus(checkRequest("POST", target, false, [3000]), 400);
    test:assertTrue(checkRequest("POST", target, true, [3000]) is Target);
    assertRequestStatus(checkRequest("POST", target, true, [443]), 403);
}
