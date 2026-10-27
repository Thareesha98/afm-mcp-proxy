import ballerina/http;
import ballerina/io;
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
        if !neverSent(response) {
            break;
        }
    }
    return error RequestError("Upstream request failed", status = 502);
}

function neverSent(http:ClientError err) returns boolean {
    error? cause = err.cause();
    return err is http:SslError
        || (cause is error && re `.*(Connection refused|[Cc]onnection time(d )?out|No route to host|Network is unreachable|SSL handshake).*`.isFullMatch(cause.message()));
}

// A response that says it is larger than the limit is refused before any of it is read. One that
// does not say its size is counted as it passes, and the transfer is broken off once it goes over,
// so the browser sees a failed request rather than a cut-off answer that looks complete. An event
// stream is counted event by event, so each event still reaches the browser as soon as it arrives.
function limitResponseSize(http:Response up, int maxBytes) returns http:Response {
    string|error length = up.getHeader("content-length");
    if length is string {
        int|error size = int:fromString(length.trim());
        if size is int && size <= maxBytes {
            return up;
        }
        if size is int {
            stream<byte[], io:Error?>|http:ClientError unread = up.getByteStream();
            if unread is stream<byte[], io:Error?> {
                release(unread);
            }
            return errorResponse(502, "Response too large");
        }
    }
    if isEventStream(up) {
        stream<http:SseEvent, error?>|http:ClientError events = up.getSseEventStream();
        if events is http:ClientError {
            return up;
        }
        http:Response limited = copyHead(up);
        stream<http:SseEvent, error?> counted = new (new LimitedEvents(events, maxBytes));
        limited.setSseEventStream(counted);
        return limited;
    }
    stream<byte[], io:Error?>|http:ClientError bytes = up.getByteStream();
    if bytes is http:ClientError {
        return up;
    }
    http:Response limited = copyHead(up);
    limited.setByteStream(new (new LimitedBytes(bytes, maxBytes)));
    restoreContentType(limited, up);
    return limited;
}

// a new response with the target's status and headers, ready for a counted body
function copyHead(http:Response up) returns http:Response {
    http:Response copy = new;
    copy.statusCode = up.statusCode;
    copy.reasonPhrase = up.reasonPhrase;
    foreach string name in up.getHeaderNames() {
        string lower = name.toLowerAscii();
        if lower == "content-length" || lower == "transfer-encoding" {
            continue;
        }
        string[]|http:HeaderNotFoundError values = up.getHeaders(name);
        if values is string[] {
            foreach string value in values {
                copy.addHeader(name, value);
            }
        }
    }
    return copy;
}

function restoreContentType(http:Response copy, http:Response up) {
    string|error contentType = up.getHeader("content-type");
    if contentType is string {
        copy.setHeader("Content-Type", contentType);
    } else {
        copy.removeHeader("Content-Type");
    }
}

function isEventStream(http:Response up) returns boolean {
    string|error contentType = up.getHeader("content-type");
    return contentType is string && contentType.trim().toLowerAscii().startsWith("text/event-stream");
}

// closing only lets go of the connection to the target, so there is nothing to do if it fails
isolated function release(stream<byte[], io:Error?> bytes) {
    io:Error? closed = bytes.close();
    if closed is io:Error {
        return;
    }
}

class LimitedBytes {
    private final stream<byte[], io:Error?> upstream;
    private final int maxBytes;
    private int passed = 0;

    function init(stream<byte[], io:Error?> upstream, int maxBytes) {
        self.upstream = upstream;
        self.maxBytes = maxBytes;
    }

    public isolated function next() returns record {|byte[] value;|}|io:Error? {
        record {|byte[] value;|}|io:Error? chunk = self.upstream.next();
        if chunk is record {|byte[] value;|} {
            self.passed += chunk.value.length();
            if self.passed > self.maxBytes {
                release(self.upstream);
                return error io:GenericError("Response too large");
            }
        }
        return chunk;
    }

    public isolated function close() returns io:Error? {
        return self.upstream.close();
    }
}

class LimitedEvents {
    private final stream<http:SseEvent, error?> upstream;
    private final int maxBytes;
    private int passed = 0;

    function init(stream<http:SseEvent, error?> upstream, int maxBytes) {
        self.upstream = upstream;
        self.maxBytes = maxBytes;
    }

    public isolated function next() returns record {|http:SseEvent value;|}|error? {
        record {|http:SseEvent value;|}|error? event = self.upstream.next();
        if event is record {|http:SseEvent value;|} {
            self.passed += eventSize(event.value);
            if self.passed > self.maxBytes {
                error? closed = self.upstream.close();
                return error("Response too large", closed = closed);
            }
        }
        return event;
    }

    public isolated function close() returns error? {
        return self.upstream.close();
    }
}

// the size of an event as it goes on the wire, near enough: each field's text and its name
isolated function eventSize(http:SseEvent event) returns int {
    int size = 2;
    foreach [string, string?] [name, value] in [["data", event.data], ["event", event.event], ["id", event.id], ["", event.comment]] {
        if value is string {
            size += value.toBytes().length() + name.length() + 3;
        }
    }
    return event.'retry is int ? size + 10 : size;
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
