import ballerina/lang.runtime;
import ballerina/log;

type Window record {|
    int requests;
    int ok;
    int redirects;
    int clientErrors;
    int serverErrors;
    int forbidden;
    int rateLimited;
    int upstreamErrors;
    int internalErrors;
    int inFlight;
    int peakInFlight;
|};

isolated function emptyWindow(int inFlight) returns Window {
    return {
        requests: 0,
        ok: 0,
        redirects: 0,
        clientErrors: 0,
        serverErrors: 0,
        forbidden: 0,
        rateLimited: 0,
        upstreamErrors: 0,
        internalErrors: 0,
        inFlight,
        peakInFlight: inFlight
    };
}

isolated class Stats {
    private Window window = emptyWindow(0);

    isolated function opened() {
        lock {
            self.window.inFlight += 1;
            if self.window.inFlight > self.window.peakInFlight {
                self.window.peakInFlight = self.window.inFlight;
            }
        }
    }

    isolated function closed(int status) {
        lock {
            self.window.inFlight -= 1;
            self.window.requests += 1;
            if status >= 200 && status < 300 {
                self.window.ok += 1;
            } else if status >= 300 && status < 400 {
                self.window.redirects += 1;
            } else if status >= 400 && status < 500 {
                self.window.clientErrors += 1;
            } else if status >= 500 && status < 600 {
                self.window.serverErrors += 1;
            }
        }
    }

    isolated function refused(int status) {
        lock {
            match status {
                403 => {
                    self.window.forbidden += 1;
                }
                429 => {
                    self.window.rateLimited += 1;
                }
                500 => {
                    self.window.internalErrors += 1;
                }
                502|504 => {
                    self.window.upstreamErrors += 1;
                }
            }
        }
    }

    isolated function take() returns readonly & Window {
        lock {
            readonly & Window done = self.window.cloneReadOnly();
            self.window = emptyWindow(done.inFlight);
            return done;
        }
    }
}

final Stats stats = new;

function summaryLine(Window w) returns string {
    return string `stats requests=${w.requests} ok=${w.ok} redirects=${w.redirects} clientErrors=${w.clientErrors} serverErrors=${w.serverErrors} forbidden=${w.forbidden} rateLimited=${w.rateLimited} upstreamErrors=${w.upstreamErrors} internalErrors=${w.internalErrors} inFlight=${w.inFlight} peakInFlight=${w.peakInFlight}`;
}

function warnings(Window w) returns string[] {
    string[] lines = [];
    if w.rateLimited > 0 {
        lines.push(string `rate limit refused ${w.rateLimited} requests since the last stats line`);
    }
    if w.internalErrors > 0 {
        lines.push(string `internal errors: ${w.internalErrors} since the last stats line`);
    }
    return lines;
}

function reportEvery(int seconds) {
    while true {
        runtime:sleep(<decimal>seconds);
        Window window = stats.take();
        log:printInfo(summaryLine(window));
        foreach string line in warnings(window) {
            log:printWarn(line);
        }
    }
}
