import ballerina/http;
import ballerina/time;

const decimal CONNECT_TIMEOUT = 10;

final string[] blockedRequestHeaders = [
    "host",
    "origin",
    "cookie",
    "referer",
    "content-length",
    "connection",
    "keep-alive",
    "proxy-connection",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "http2-settings",
    "expect",
    "forwarded",
    "via",
    "x-real-ip",
    "x-client-ip",
    "client-ip",
    "x-amzn-trace-id",
    "accept-encoding",
    "x-correlation-id",
    "x-trace-key"
];

final string[] blockedRequestPrefixes = ["x-forwarded-", "x-envoy-", "x-choreo-"];

final string[] blockedResponseHeaders = [
    "connection",
    "keep-alive",
    "proxy-connection",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "http2-settings",
    "set-cookie",
    "x-choreo-correlation-id"
];

function connectionTokens(string[]|error connection) returns string[] {
    string[] tokens = [];
    if connection is string[] {
        foreach string value in connection {
            tokens.push(...parseList(value.toLowerAscii()));
        }
    }
    return tokens;
}

function requestHeaders(http:Request req, Target target) returns map<string|string[]> {
    map<string|string[]> headers = {};
    string[] named = connectionTokens(req.getHeaders("connection"));
    foreach string name in req.getHeaderNames() {
        string lower = name.toLowerAscii();
        string[]|error values = req.getHeaders(name);
        if values is string[] && blockedRequestHeaders.indexOf(lower) is () && named.indexOf(lower) is ()
                && blockedRequestPrefixes.every(prefix => !lower.startsWith(prefix)) {
            headers[name] = values;
        }
    }
    headers["Host"] = hostHeader(target);
    headers["Accept-Encoding"] = "identity";
    return headers;
}

function hostHeader(Target target) returns string {
    boolean defaultPort = target.port == (target.scheme == "https" ? 443 : 80);
    return defaultPort ? target.host : string `${target.host}:${target.port}`;
}

function forward(Target target, string method, map<string|string[]> headers, byte[] body, decimal seconds,
        decimal connectTimeout = CONNECT_TIMEOUT) returns http:Response|RequestError {
    decimal deadline = time:monotonicNow() + seconds;
    boolean followRedirects = mayFollowRedirects(method, headers, body);
    Target current = target;
    map<string|string[]> currentHeaders = headers;
    int redirects = 0;
    while true {
        http:Response response = check send(current, method, currentHeaders, body, deadline - time:monotonicNow(), connectTimeout);
        if !followRedirects && isRedirect(response) {
            return error RequestError("The target answered with a redirect, which is not followed for a request with a body or credentials", status = 502);
        }
        string? location = redirectLocation(response);
        if location is () {
            return response;
        }
        if redirects == MAX_REDIRECTS {
            return error RequestError("Too many redirects", status = 502);
        }
        Target|RequestError next = checkTarget(resolveLocation(current, location), allowLoopback, targetPorts);
        if next is RequestError {
            return error RequestError("Redirect target is not allowed", status = 502);
        }
        currentHeaders = redirectHeaders(currentHeaders, next, sameOrigin(current, next));
        current = next;
        redirects += 1;
    }
}

function send(Target target, string method, map<string|string[]> headers, byte[] body, decimal seconds,
        decimal connectTimeout) returns http:Response|RequestError {
    decimal deadline = time:monotonicNow() + seconds;
    foreach string address in target.addresses {
        decimal remaining = deadline - time:monotonicNow();
        if remaining <= 0d {
            return error RequestError("Upstream timed out", status = 504);
        }
        decimal connecting = decimal:min(connectTimeout, remaining);
        http:ClientConfiguration config = {
            httpVersion: http:HTTP_1_1,
            http1Settings: {keepAlive: http:KEEPALIVE_NEVER},
            timeout: remaining,
            socketConfig: {connectTimeOut: connecting},
            cache: {enabled: false}
        };
        if target.scheme == "https" {
            config.secureSocket = {serverName: target.host, handshakeTimeout: connecting};
        }
        string host = address.includes(":") ? "[" + address + "]" : address;
        http:Client|error upstream = new (string `${target.scheme}://${host}:${target.port}`, config);
        if upstream is error {
            continue;
        }
        http:Response|http:ClientError response = upstream->execute(method, target.pathAndQuery, body.length() > 0 ? body : (), headers);
        if response is http:Response {
            return response;
        }
        if response is http:IdleTimeoutError {
            return error RequestError("Upstream timed out", status = 504);
        }
    }
    return error RequestError("Upstream request failed", status = 502);
}

function prepareResponse(http:Response up) returns http:Response {
    string[] named = connectionTokens(up.getHeaders("connection"));
    foreach string name in up.getHeaderNames() {
        string lower = name.toLowerAscii();
        if blockedResponseHeaders.indexOf(lower) is int || named.indexOf(lower) is int || lower.startsWith("access-control-") {
            up.removeHeader(name);
        }
    }
    return up;
}
