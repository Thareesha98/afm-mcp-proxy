import ballerina/http;

const string DEFAULT_ALLOWED_HEADERS = "authorization, content-type, mcp-session-id, mcp-protocol-version, last-event-id";

function corsHeaders(string[] allowedOrigins, string? origin, string? requestedHeaders) returns map<string> {
    map<string> headers = {
        "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
        "Access-Control-Allow-Headers": requestedHeaders is () || requestedHeaders == "" ? DEFAULT_ALLOWED_HEADERS : requestedHeaders,
        "Access-Control-Expose-Headers": "mcp-session-id, www-authenticate",
        "Access-Control-Max-Age": "600",
        "Vary": "Origin, Access-Control-Request-Headers"
    };
    if origin is string && isAllowedOrigin(allowedOrigins, origin) {
        headers["Access-Control-Allow-Origin"] = origin;
    }
    return headers;
}

function addStandardHeaders(http:Request req, http:Response res) {
    map<string> headers = corsHeaders(origins, headerValue(req, "origin"), headerValue(req, "access-control-request-headers"));
    foreach [string, string] [name, value] in headers.entries() {
        if name == "Vary" {
            res.addHeader(name, value);
        } else {
            res.setHeader(name, value);
        }
    }
    res.setHeader("X-Content-Type-Options", "nosniff");
    res.setHeader("Referrer-Policy", "no-referrer");
}

function isAllowedOrigin(string[] allowedOrigins, string? origin) returns boolean {
    return origin is string && allowedOrigins.indexOf(origin) is int;
}

function checkRequest(string method, string? target, boolean allowLoopback, int[] ports) returns Target|RequestError {
    if method != "GET" && method != "POST" && method != "DELETE" {
        return error RequestError("Method not allowed", status = 405);
    }
    if target is () || target == "" {
        return error RequestError("Missing target URL", status = 400);
    }
    return checkTarget(target, allowLoopback, ports);
}
