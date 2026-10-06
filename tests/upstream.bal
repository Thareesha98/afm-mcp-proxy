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

service / on upstreamListener {
    resource function default [string... path](http:Request req) returns http:Response|error {
        http:Response res = new;
        string route = path.length() > 0 ? path[0] : "";
        match route {
            "echo" => {
                string text = req.method + " " + req.rawPath + "\n";
                foreach string name in req.getHeaderNames() {
                    text += name.toLowerAscii() + ": " + string:'join(",", ...check req.getHeaders(name)) + "\n";
                }
                string|error body = req.getTextPayload();
                text += "body: " + (body is string ? body : "");
                res.setTextPayload(text);
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
                res.setHeader("Vary", "Accept-Encoding");
                res.setHeader("WWW-Authenticate", "Bearer realm=\"mcp\"");
            }
        }
        return res;
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
