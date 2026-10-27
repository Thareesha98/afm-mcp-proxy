import ballerina/http;
import ballerina/lang.runtime;
import ballerina/tcp;

listener http:Listener upstreamListener = new (9301, requestLimits = {maxUriLength: 16384, maxHeaderSize: 16384});

class EventTicker {
    private int sent = 0;

    public isolated function next() returns record {|http:SseEvent value;|}|error? {
        if self.sent == 4 {
            return ();
        }
        if self.sent > 0 {
            runtime:sleep(0.4);
        }
        self.sent += 1;
        return {value: {data: "event " + self.sent.toString()}};
    }
}

const string SHARED_FILE = "---\nname: shared agent\n---\nYou are a shared agent.\n";
const string SHARED_FILE_TYPE = "text/plain;charset=utf-8";

function allByteValues() returns byte[] {
    byte[] bytes = [];
    foreach int round in 0 ..< 2 {
        foreach int value in 0 ..< 256 {
            bytes.push(<byte>value);
        }
    }
    return bytes;
}

function echoText(http:Request req) returns string|error {
    string text = req.method + " " + req.rawPath + "\n";
    foreach string name in req.getHeaderNames() {
        text += name.toLowerAscii() + ": " + string:'join(",", ...check req.getHeaders(name)) + "\n";
    }
    string|error body = req.getTextPayload();
    return text + "body: " + (body is string ? body : "");
}

service / on upstreamListener {
    resource function default [string... path](http:Request req) returns http:Response|error {
        http:Response res = new;
        string route = path.length() > 0 ? path[0] : "";
        match route {
            "echo" => {
                res.setTextPayload(check echoText(req));
            }
            "file" => {
                if path[1] == "text" {
                    res.setTextPayload(SHARED_FILE, SHARED_FILE_TYPE);
                } else {
                    res.setBinaryPayload(allByteValues(), "application/octet-stream");
                }
            }
            "cookiehop" => {
                res.statusCode = 302;
                res.setHeader("Location", req.getQueryParamValue("to") ?: "/echo");
                res.addHeader("Set-Cookie", "hop=1");
            }
            "mark" => {
                lock {
                    marks += 1;
                }
                res.setTextPayload("marked");
            }
            "to" => {
                string? location = req.getQueryParamValue("location");
                if location is () {
                    res.setTextPayload(check echoText(req));
                } else {
                    string? status = req.getQueryParamValue("status");
                    res.statusCode = status is string ? check int:fromString(status) : 302;
                    res.setHeader("Location", location);
                }
            }
            "chain" => {
                int left = check int:fromString(path[1]);
                if left > 0 {
                    res.statusCode = 302;
                    res.setHeader("Location", "/chain/" + (left - 1).toString());
                } else {
                    res.setTextPayload(check echoText(req));
                }
            }
            "loop" => {
                res.statusCode = 302;
                res.setHeader("Location", "/loop");
            }
            "bare" => {
                res.statusCode = 302;
            }
            "slowredirect" => {
                runtime:sleep(1.5);
                res.statusCode = 302;
                res.setHeader("Location", "/slow");
            }
            "missing" => {
                res.statusCode = 404;
                res.setTextPayload("nothing here");
            }
            "redirect" => {
                res.statusCode = 302;
                res.setHeader("Location", "/echo");
            }
            "slow" => {
                runtime:sleep(1.5);
                res.setTextPayload("slow but fine");
            }
            "stall" => {
                runtime:sleep(5);
                res.setTextPayload("too late");
            }
            "events" => {
                stream<http:SseEvent, error?> events = new (new EventTicker());
                res.setSseEventStream(events);
            }
            "cacheable" => {
                stream<http:SseEvent, error?> events = new (new EventTicker());
                res.setSseEventStream(events);
                http:ResponseCacheControl cacheControl = new;
                cacheControl.isPrivate = false;
                cacheControl.maxAge = 60;
                res.cacheControl = cacheControl;
                res.setHeader("ETag", "\"abc\"");
            }
            "big" => {
                res.setTextPayload(string:'join("", ...from int i in 0 ..< 2000
                            select "x"));
            }
            "headers" => {
                res.setTextPayload("headers");
                res.addHeader("Set-Cookie", "a=1");
                res.addHeader("Set-Cookie", "b=2");
                res.setHeader("Keep-Alive", "timeout=5");
                res.setHeader("Proxy-Authenticate", "Basic");
                res.setHeader("Access-Control-Allow-Origin", "*");
                res.setHeader("Access-Control-Allow-Credentials", "true");
                res.setHeader("X-Custom", "yes");
                res.setHeader("X-Choreo-Correlation-Id", "afm-evil");
                res.setHeader("Vary", "Accept-Encoding");
                res.setHeader("WWW-Authenticate", "Bearer realm=\"mcp\"");
            }
        }
        return res;
    }
}

isolated int marks = 0;

isolated function markCount() returns int {
    lock {
        return marks;
    }
}

isolated int closedConnections = 0;

isolated function closedCount() returns int {
    lock {
        return closedConnections;
    }
}

service on new tcp:Listener(9302) {
    remote function onConnect(tcp:Caller caller) returns tcp:ConnectionService {
        return new KeepAliveConnection();
    }
}

service class KeepAliveConnection {
    *tcp:ConnectionService;

    remote function onBytes(readonly & byte[] data) returns byte[] {
        return "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".toBytes();
    }

    remote function onClose() {
        lock {
            closedConnections += 1;
        }
    }
}

isolated int requestsSeen = 0;

isolated function seenCount() returns int {
    lock {
        return requestsSeen;
    }
}

listener tcp:Listener answeringListener = new (9303, localHost = "127.0.0.1");
listener tcp:Listener droppingListener = new (9304, localHost = "127.0.0.1");

service on answeringListener, droppingListener {
    remote function onConnect(tcp:Caller caller) returns tcp:ConnectionService {
        return new CountingConnection(caller.localPort == 9304);
    }
}

service class CountingConnection {
    *tcp:ConnectionService;

    private final boolean drop;

    function init(boolean drop) {
        self.drop = drop;
    }

    remote function onBytes(tcp:Caller caller, readonly & byte[] data) returns tcp:Error? {
        string|error text = string:fromBytes(data);
        if text is error || !(text.startsWith("GET /") || text.startsWith("POST /") || text.startsWith("DELETE /")) {
            return;
        }
        lock {
            requestsSeen += 1;
        }
        if self.drop {
            check caller->close();
        } else {
            check caller->writeBytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok".toBytes());
        }
    }
}
