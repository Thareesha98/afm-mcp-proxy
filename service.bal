import ballerina/http;

final RateLimiter limiter = new (requestsPerMinute, burst);

@http:ServiceConfig {
    compression: {enable: http:COMPRESSION_NEVER}
}
service / on new http:Listener(port, httpVersion = http:HTTP_1_1,
    timeout = <decimal>maxRequestSeconds + 2 * CONNECT_TIMEOUT + 5,
    requestLimits = {maxUriLength: 16384, maxHeaderSize: 16384, maxEntityBodySize: transportLimit}
) {
    resource function default [string... path](http:Caller caller, http:Request req) returns error? {
        stats.opened();
        http:Response|error response = trap relay(req);
        http:Response result = response is http:Response ? response : errorResponse(500, "Internal error");
        error? decorated = trap addStandardHeaders(req, result);
        if decorated is error {
            result = errorResponse(500, "Internal error");
        }
        http:ListenerError? sent = caller->respond(result);
        stats.closed(result.statusCode);
        if sent is error {
            return;
        }
    }
}

function relay(http:Request req) returns http:Response {
    if req.method == "OPTIONS" {
        http:Response preflight = new;
        preflight.statusCode = 204;
        return preflight;
    }
    if !isAllowedOrigin(origins, headerValue(req, "origin")) {
        return errorResponse(403, "Origin not allowed");
    }
    if !limiter.take() {
        http:Response limited = errorResponse(429, "Too many requests");
        limited.setHeader("Retry-After", "60");
        return limited;
    }
    string?|error requested = trap req.getQueryParamValue("target");
    if requested is error {
        return errorResponse(400, "Invalid target URL");
    }
    Target|RequestError target = checkRequest(req.method, requested, allowLoopback, targetPorts);
    if target is RequestError {
        return failure(target);
    }
    byte[]|error body = req.getBinaryPayload();
    if body is error {
        return errorResponse(400, "Could not read request body");
    }
    if body.length() > maxBodyBytes {
        return errorResponse(413, "Request body too large");
    }
    http:Response|RequestError upstream = forward(target, req.method, requestHeaders(req, target), body, <decimal>maxRequestSeconds);
    if upstream is RequestError {
        return failure(upstream);
    }
    return prepareResponse(upstream);
}

function headerValue(http:Request req, string name) returns string? {
    string|error value = req.getHeader(name);
    return value is string ? value : ();
}

function errorResponse(int status, string message) returns http:Response {
    stats.refused(status);
    http:Response res = new;
    res.statusCode = status;
    res.setHeader("Cache-Control", "no-store");
    res.setJsonPayload({"error": message});
    return res;
}

function failure(RequestError err) returns http:Response {
    return errorResponse(err.detail().status, err.message());
}
