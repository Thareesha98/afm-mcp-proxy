import ballerina/http;
import ballerina/lang.runtime;
import ballerina/tcp;
import ballerina/test;
import ballerina/url;

function finish(Stats stats, int... statuses) {
    foreach int status in statuses {
        stats.opened();
        stats.closed(status);
    }
}

@test:Config
function testStatusClassesAreCounted() {
    Stats counters = new;
    finish(counters, 200, 204, 299, 300, 301, 399, 400, 404, 499, 500, 599);
    Window window = counters.take();
    test:assertEquals(window.requests, 11);
    test:assertEquals(window.ok, 3);
    test:assertEquals(window.redirects, 3);
    test:assertEquals(window.clientErrors, 3);
    test:assertEquals(window.serverErrors, 2);
}

@test:Config
function testOddStatusesAreOnlyCountedAsRequests() {
    Stats counters = new;
    finish(counters, 0, 99, 100, 199, 600, 1000, -5);
    Window window = counters.take();
    test:assertEquals(window.requests, 7);
    test:assertEquals(window.ok + window.redirects + window.clientErrors + window.serverErrors, 0);
}

@test:Config
function testOwnRefusalsAreCountedByStatus() {
    Stats counters = new;
    foreach int status in [403, 403, 429, 500, 502, 504, 400, 405, 413, 404, 200] {
        counters.refused(status);
    }
    Window window = counters.take();
    test:assertEquals(window.forbidden, 2);
    test:assertEquals(window.rateLimited, 1);
    test:assertEquals(window.internalErrors, 1);
    test:assertEquals(window.upstreamErrors, 2);
    test:assertEquals(window.requests, 0);
}

@test:Config
function testInFlightAndItsPeakFollowTheWindows() {
    Stats counters = new;
    counters.opened();
    counters.opened();
    counters.opened();
    counters.closed(200);
    Window first = counters.take();
    test:assertEquals(first.inFlight, 2);
    test:assertEquals(first.peakInFlight, 3);
    counters.closed(200);
    Window second = counters.take();
    test:assertEquals(second.inFlight, 1);
    test:assertEquals(second.peakInFlight, 2);
    counters.opened();
    counters.closed(200);
    counters.closed(200);
    Window third = counters.take();
    test:assertEquals(third.inFlight, 0);
    test:assertEquals(third.peakInFlight, 2);
    test:assertEquals(third.requests, 2);
}

@test:Config
function testTakeStartsAnEmptyWindow() {
    Stats counters = new;
    finish(counters, 200, 404);
    counters.refused(429);
    _ = counters.take();
    Window empty = counters.take();
    test:assertEquals(empty, {requests: 0, ok: 0, redirects: 0, clientErrors: 0, serverErrors: 0, forbidden: 0, rateLimited: 0, upstreamErrors: 0, internalErrors: 0, newSessions: 0, inFlight: 0, peakInFlight: 0});
}

@test:Config
function testCountersAreSafeUnderConcurrency() {
    Stats counters = new;
    future<()>[] runs = [];
    foreach int i in 0 ..< 100 {
        future<()> run = start finish(counters, 200, 503);
        runs.push(run);
    }
    foreach future<()> run in runs {
        error? done = wait run;
        test:assertTrue(done is ());
    }
    Window window = counters.take();
    test:assertEquals(window.requests, 200);
    test:assertEquals(window.ok, 100);
    test:assertEquals(window.serverErrors, 100);
    test:assertEquals(window.inFlight, 0);
}

@test:Config
function testSummaryLineShowsEveryCount() {
    Window window = {requests: 7, ok: 3, redirects: 1, clientErrors: 2, serverErrors: 1, forbidden: 4, rateLimited: 5, upstreamErrors: 6, internalErrors: 8, newSessions: 11, inFlight: 9, peakInFlight: 10};
    test:assertEquals(summaryLine(window, 12), "stats requests=7 ok=3 redirects=1 clientErrors=2 serverErrors=1 forbidden=4 rateLimited=5 upstreamErrors=6 internalErrors=8 newSessions=11 inFlight=9 peakInFlight=10 sessions=12");
}

function windowWith(int rateLimited, int internalErrors) returns Window {
    return {requests: 50, ok: 40, redirects: 0, clientErrors: 9, serverErrors: 1, forbidden: 9, rateLimited, upstreamErrors: 3, internalErrors, newSessions: 0, inFlight: 0, peakInFlight: 4};
}

@test:Config
function testWarningsAreOnlyWrittenWhenSomethingWasRefused() {
    test:assertEquals(warnings(windowWith(0, 0)), []);
    test:assertEquals(warnings(windowWith(25, 0)), ["rate limit refused 25 requests since the last stats line"]);
    test:assertEquals(warnings(windowWith(0, 2)), ["internal errors: 2 since the last stats line"]);
    test:assertEquals(warnings(windowWith(1, 1)).length(), 2);
}

@test:Config
function testServiceCountsWhatItAnswers() returns error? {
    _ = stats.take();
    _ = check call("GET", UP + "/echo");
    _ = check call("GET", UP + "/missing");
    _ = check call("GET", ());
    _ = check call("GET", UP + "/echo", {"Origin": "https://evil.com"});
    _ = check call("PUT", UP + "/echo");
    Window window = stats.take();
    test:assertEquals(window.requests, 5);
    test:assertEquals(window.ok, 1);
    test:assertEquals(window.clientErrors, 4);
    test:assertEquals(window.forbidden, 1);
    test:assertEquals(window.inFlight, 0);
}

@test:Config
function testTargetErrorsAndOwnErrorsAreCountedApart() returns error? {
    _ = stats.take();
    http:Response fromTarget = check call("GET", UP + "/to?status=500&location=%2Fecho");
    test:assertEquals(fromTarget.statusCode, 500);
    _ = check call("GET", "http://no-such-host.invalid/");
    _ = check call("GET", UP + "/stall");
    Window window = stats.take();
    test:assertEquals(window.requests, 3);
    test:assertEquals(window.serverErrors, 3);
    test:assertEquals(window.upstreamErrors, 2);
    test:assertEquals(window.internalErrors, 0);
}

@test:Config
function testInFlightIsCountedWhileAnAnswerIsOutstanding() returns error? {
    _ = stats.take();
    future<http:Response|error> pending = start call("GET", UP + "/slow");
    runtime:sleep(0.5);
    Window during = stats.take();
    test:assertEquals(during.inFlight, 1);
    http:Response|error answer = wait pending;
    test:assertTrue(answer is http:Response);
    runtime:sleep(0.2);
    Window after = stats.take();
    test:assertEquals(after.inFlight, 0);
    test:assertEquals(after.requests, 1);
    test:assertEquals(after.peakInFlight, 1);
}

@test:Config
function testAnAbandonedRequestIsNoLongerInFlight() returns error? {
    _ = stats.take();
    string target = check url:encode(UP + "/events", "UTF-8");
    tcp:Client socket = check new ("localhost", 9300, timeout = 5);
    check socket->writeBytes(("GET /?target=" + target + " HTTP/1.1\r\nHost: x\r\nOrigin: " + ORIGIN + "\r\n\r\n").toBytes());
    readonly & byte[] first = check socket->readBytes();
    test:assertTrue(first.length() > 0);
    Window during = stats.take();
    test:assertEquals(during.inFlight, 1);
    check socket->close();
    runtime:sleep(2);
    Window after = stats.take();
    test:assertEquals(after.inFlight, 0);
    test:assertEquals(after.requests, 1);
}

@test:Config
function testIssuedSessionsAreCountedPerWindow() {
    Stats counters = new;
    counters.issued();
    counters.issued();
    counters.issued();
    test:assertEquals(counters.take().newSessions, 3);
    test:assertEquals(counters.take().newSessions, 0);
}
