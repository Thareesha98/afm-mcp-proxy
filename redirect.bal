import ballerina/http;

const int MAX_REDIRECTS = 3;

final int[] redirectStatuses = [301, 302, 303, 307, 308];
final string[] otherHostHeaders = ["accept", "accept-encoding", "accept-language", "content-type", "mcp-protocol-version", "user-agent"];

function isRedirect(http:Response response) returns boolean {
    return redirectStatuses.indexOf(response.statusCode) is int && response.hasHeader("location");
}

function redirectLocation(http:Response response) returns string? {
    if !isRedirect(response) {
        return ();
    }
    string|error location = response.getHeader("location");
    return location is string && location != "" ? location : ();
}

function mayFollowRedirects(string method, map<string|string[]> headers, byte[] body) returns boolean {
    return method == "GET" && body.length() == 0
        && !headers.keys().some(name => re `.*(auth|key|token|secret|session|cookie|password|credential).*`.isFullMatch(name.toLowerAscii()));
}

function sameOrigin(Target a, Target b) returns boolean {
    return a.scheme == b.scheme && a.host == b.host && a.port == b.port;
}

function redirectHeaders(map<string|string[]> headers, Target next, boolean sameHost) returns map<string|string[]> {
    map<string|string[]> result = {};
    foreach [string, string|string[]] [name, value] in headers.entries() {
        string lower = name.toLowerAscii();
        if lower == "host" || (!sameHost && otherHostHeaders.indexOf(lower) is ()) {
            continue;
        }
        result[name] = value;
    }
    result["Host"] = hostHeader(next);
    return result;
}

function splitQuery(string url) returns [string, string] {
    int? mark = url.indexOf("?");
    if mark is int {
        return [url.substring(0, mark), url.substring(mark)];
    }
    return [url, ""];
}

function resolveLocation(Target base, string location) returns string {
    string reference = location;
    int? fragment = reference.indexOf("#");
    if fragment is int {
        reference = reference.substring(0, fragment);
    }
    if re `[a-zA-Z][a-zA-Z0-9+.\-]*:.*`.isFullMatch(reference) {
        return reference;
    }
    if reference.startsWith("//") {
        return base.scheme + ":" + reference;
    }
    string origin = string `${base.scheme}://${hostHeader(base)}`;
    var [basePath, baseQuery] = splitQuery(base.pathAndQuery);
    var [path, query] = splitQuery(reference);
    if path == "" {
        return origin + basePath + (query == "" ? baseQuery : query);
    }
    if path.startsWith("/") {
        return origin + path + query;
    }
    int lastSlash = basePath.lastIndexOf("/") ?: 0;
    return origin + basePath.substring(0, lastSlash + 1) + path + query;
}
