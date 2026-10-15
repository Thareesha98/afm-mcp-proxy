import ballerina/lang.runtime;
import ballerina/test;
import ballerina/uuid;

function newSessions(int perMinute = 1, int burst = 3, int newPerMinute = 1, int newBurst = 5, int capacity = 100, int lifetime = 60) returns Sessions {
    return new (perMinute, burst, newPerMinute, newBurst, capacity, lifetime);
}

function issuedId(Sessions sessions) returns string {
    string? id = sessions.admit(()).issued;
    return id is string ? id : "";
}

function isSessionId(string id) returns boolean {
    return re `afm-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}`.isFullMatch(id);
}

function forgedId() returns string {
    return "afm-" + uuid:createRandomUuid();
}

@test:Config
function testAnIdIsIssuedWhenNoneIsPresented() {
    Sessions sessions = newSessions();
    Admission admission = sessions.admit(());
    test:assertTrue(admission.allowed);
    string? id = admission.issued;
    test:assertTrue(id is string && isSessionId(id), id.toString());
    test:assertEquals(sessions.size(), 1);
}

@test:Config
function testAnIssuedIdIsRecognisedAndNotIssuedAgain() {
    Sessions sessions = newSessions();
    string id = issuedId(sessions);
    foreach int i in 0 ..< 2 {
        Admission again = sessions.admit(id);
        test:assertTrue(again.allowed);
        test:assertEquals(again.issued, ());
    }
    test:assertEquals(sessions.size(), 1);
}

@test:Config
function testAnIdThatWasNeverIssuedIsNotAccepted() {
    Sessions sessions = newSessions();
    string forged = forgedId();
    Admission first = sessions.admit(forged);
    string? replacement = first.issued;
    test:assertTrue(replacement is string && replacement != forged, replacement.toString());
    Admission second = sessions.admit(forged);
    test:assertTrue(second.issued is string);
    test:assertEquals(sessions.size(), 2);
}

@test:Config
function testAnythingThatWasNeverIssuedIsTreatedAsNone() {
    Sessions sessions = newSessions(newBurst = 20);
    string valid = forgedId();
    int count = 0;
    foreach string presented in [
        "",
        "afm-",
        "6e68f0ade3bfc1c93129461af0baa4c5",
        valid.toUpperAscii(),
        valid + " ",
        valid + "\n",
        "afm-" + valid + "," + valid,
        "".padEnd(16000, "a")
    ] {
        Admission admission = sessions.admit(presented);
        string? replacement = admission.issued;
        test:assertTrue(replacement is string && isSessionId(replacement) && replacement != presented, presented.length().toString());
        count += 1;
    }
    test:assertEquals(sessions.size(), count);
}

@test:Config
function testEverySessionHasItsOwnBucket() {
    Sessions sessions = newSessions(burst = 3);
    string noisy = issuedId(sessions);
    string quiet = issuedId(sessions);
    test:assertTrue(sessions.admit(noisy).allowed);
    test:assertTrue(sessions.admit(noisy).allowed);
    test:assertFalse(sessions.admit(noisy).allowed);
    test:assertFalse(sessions.admit(noisy).allowed);
    test:assertTrue(sessions.admit(quiet).allowed);
    test:assertTrue(sessions.admit(quiet).allowed);
    test:assertFalse(sessions.admit(noisy).allowed);
}

@test:Config
function testNewSessionsAreLimitedAndTheRestShareOneAnonymousBucket() {
    Sessions sessions = newSessions(burst = 3, newBurst = 2);
    Admission first = sessions.admit(());
    Admission second = sessions.admit(());
    test:assertTrue(first.issued is string && second.issued is string);
    foreach int i in 0 ..< 3 {
        Admission anonymous = sessions.admit(());
        test:assertEquals(anonymous.issued, ());
        test:assertTrue(anonymous.allowed, i.toString());
    }
    Admission refused = sessions.admit(());
    test:assertEquals(refused.issued, ());
    test:assertFalse(refused.allowed);
    test:assertEquals(sessions.size(), 2);
    string? known = first.issued;
    test:assertTrue(known is string && sessions.admit(known).allowed);
}

@test:Config
function testTheLeastRecentlyUsedSessionIsEvictedWhenTheTableIsFull() {
    Sessions sessions = newSessions(newBurst = 10, capacity = 3);
    string a = issuedId(sessions);
    string b = issuedId(sessions);
    string c = issuedId(sessions);
    test:assertEquals(sessions.admit(a).issued, ());
    string d = issuedId(sessions);
    test:assertTrue(sessions.size() <= 3, sessions.size().toString());
    test:assertEquals(sessions.admit(a).issued, ());
    test:assertEquals(sessions.admit(c).issued, ());
    test:assertEquals(sessions.admit(d).issued, ());
    test:assertTrue(sessions.admit(b).issued is string);
}

@test:Config
function testAFullTableDropsOnlyTheLeastRecentlyUsedSession() {
    Sessions sessions = newSessions(newBurst = 30, capacity = 20);
    string[] ids = [];
    foreach int i in 0 ..< 20 {
        ids.push(issuedId(sessions));
    }
    string extra = issuedId(sessions);
    test:assertEquals(sessions.size(), 20);
    foreach int i in 1 ..< 20 {
        test:assertEquals(sessions.admit(ids[i]).issued, (), i.toString());
    }
    test:assertEquals(sessions.admit(extra).issued, ());
    test:assertTrue(sessions.admit(ids[0]).issued is string);
}

@test:Config
function testASessionExpiresAfterItsLifetime() {
    Sessions sessions = newSessions(lifetime = 1);
    string id = issuedId(sessions);
    runtime:sleep(2.2);
    test:assertTrue(sessions.admit(id).issued is string);
    test:assertEquals(sessions.size(), 1);
}

@test:Config
function testUsingASessionDoesNotExtendItsLifetime() {
    Sessions sessions = newSessions(burst = 10, lifetime = 3);
    string id = issuedId(sessions);
    runtime:sleep(1.0);
    test:assertEquals(sessions.admit(id).issued, ());
    runtime:sleep(2.5);
    test:assertTrue(sessions.admit(id).issued is string);
}

@test:Config
function testConcurrentRequestsOfOneSessionGetExactlyTheBurst() returns error? {
    Sessions sessions = newSessions(burst = 30);
    string id = issuedId(sessions);
    future<Admission>[] calls = [];
    foreach int i in 0 ..< 100 {
        future<Admission> pending = start sessions.admit(id);
        calls.push(pending);
    }
    int allowed = 0;
    foreach future<Admission> pending in calls {
        Admission admission = check wait pending;
        if admission.allowed {
            allowed += 1;
        }
    }
    test:assertEquals(allowed, 29);
    test:assertEquals(sessions.size(), 1);
}

@test:Config
function testConcurrentFirstRequestsGetDistinctIds() returns error? {
    Sessions sessions = newSessions(newBurst = 40);
    future<Admission>[] calls = [];
    foreach int i in 0 ..< 40 {
        future<Admission> pending = start sessions.admit(());
        calls.push(pending);
    }
    map<boolean> ids = {};
    foreach future<Admission> pending in calls {
        Admission admission = check wait pending;
        string? id = admission.issued;
        if id is string {
            ids[id] = true;
        }
    }
    test:assertEquals(ids.length(), 40);
    test:assertEquals(sessions.size(), 40);
}
