import ballerina/log;
import ballerina/observe;

configurable string allowedOrigins = "http://localhost:5173";
configurable int port = 8787;
configurable boolean allowLoopback = false;
configurable int requestsPerMinute = 1200;
configurable int burst = 300;
configurable int maxBodyBytes = 1000000;
configurable int maxRequestSeconds = 120;

const int MAX_BODY_BYTES_LIMIT = 1073741824;

final int transportLimit = check transportBodyLimit(maxBodyBytes);
final string[] origins = check parseOrigins(allowedOrigins);

function init() returns error? {
    if port < 1 || port > 65535 {
        return error("port must be between 1 and 65535");
    }
    check checkAtLeast("requestsPerMinute", requestsPerMinute, 1);
    check checkAtLeast("burst", burst, 1);
    check checkAtLeast("maxRequestSeconds", maxRequestSeconds, 1);
    check checkTelemetryIsOff(observe:isObservabilityEnabled(), observe:isMetricsEnabled(), observe:isTracingEnabled());

    log:printInfo(string `MCP proxy listening on :${port} (allowed origins: ${string:'join(", ", ...origins)})`);
    if allowLoopback {
        log:printWarn("allowLoopback is on: loopback addresses and plain http are allowed. Development only.");
    }
}

function checkTelemetryIsOff(boolean observability, boolean metrics, boolean tracing) returns error? {
    if observability || metrics || tracing {
        return error("observability must stay disabled: it records request URLs, which hold the target");
    }
}

function checkAtLeast(string name, int value, int min) returns error? {
    if value < min {
        return error(string `${name} must be at least ${min}`);
    }
}

function transportBodyLimit(int maxBytes) returns int|error {
    if maxBytes < 1 || maxBytes > MAX_BODY_BYTES_LIMIT {
        return error(string `maxBodyBytes must be between 1 and ${MAX_BODY_BYTES_LIMIT}`);
    }
    return 2 * maxBytes;
}

function parseList(string csv) returns string[] {
    string[] items = [];
    foreach string part in re `,`.split(csv) {
        if part.trim() != "" {
            items.push(part.trim());
        }
    }
    return items;
}

function parseOrigins(string csv) returns string[]|error {
    string[] result = [];
    foreach string item in parseList(csv.toLowerAscii()) {
        string origin = item.endsWith("/") ? item.substring(0, item.length() - 1) : item;
        if !re `https?://[^/*\s?#]+`.isFullMatch(origin) {
            return error(string `invalid origin: ${item}`);
        }
        result.push(withoutDefaultPort(origin));
    }
    if result.length() == 0 {
        return error("allowedOrigins must contain at least one origin");
    }
    return result;
}

function withoutDefaultPort(string origin) returns string {
    if origin.startsWith("https://") && origin.endsWith(":443") {
        return origin.substring(0, origin.length() - 4);
    }
    if origin.startsWith("http://") && origin.endsWith(":80") {
        return origin.substring(0, origin.length() - 3);
    }
    return origin;
}
