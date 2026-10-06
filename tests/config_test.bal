import ballerina/test;

@test:Config
function testParseListTrimsAndDropsEmpties() {
    test:assertEquals(parseList(" a, b ,,c ,"), ["a", "b", "c"]);
}

@test:Config
function testParseListEmptyString() {
    test:assertEquals(parseList(""), []);
}

@test:Config
function testParseOriginsKeepsExactOrigins() returns error? {
    string[] origins = check parseOrigins("https://app.example.com, http://localhost:5173");
    test:assertEquals(origins, ["https://app.example.com", "http://localhost:5173"]);
}

@test:Config
function testParseOriginsStripsTrailingSlash() returns error? {
    string[] origins = check parseOrigins("https://app.example.com/");
    test:assertEquals(origins, ["https://app.example.com"]);
}

@test:Config
function testParseOriginsRejectsWildcard() {
    test:assertTrue(parseOrigins("*") is error);
    test:assertTrue(parseOrigins("https://*.example.com") is error);
}

@test:Config
function testParseOriginsRejectsPathAndBadScheme() {
    test:assertTrue(parseOrigins("https://app.example.com/path") is error);
    test:assertTrue(parseOrigins("ftp://app.example.com") is error);
    test:assertTrue(parseOrigins("app.example.com") is error);
}

@test:Config
function testParseOriginsRejectsEmptyList() {
    test:assertTrue(parseOrigins(" , ") is error);
}

@test:Config
function testCheckAtLeast() {
    test:assertTrue(checkAtLeast("burst", 1, 1) is ());
    test:assertTrue(checkAtLeast("burst", 0, 1) is error);
}

@test:Config
function testParseOriginsNormalizesCaseAndDefaultPorts() returns error? {
    string[] origins = check parseOrigins("HTTPS://App.Example.com, https://a.com:443, http://b.com:80, https://c.com:8443, http://d.com:443, https://e.com:80");
    test:assertEquals(origins, ["https://app.example.com", "https://a.com", "http://b.com", "https://c.com:8443", "http://d.com:443", "https://e.com:80"]);
}

@test:Config
function testTransportBodyLimitIsTwiceTheLimit() returns error? {
    test:assertEquals(check transportBodyLimit(1), 2);
    test:assertEquals(check transportBodyLimit(1000000), 2000000);
    test:assertEquals(check transportBodyLimit(1073741824), 2147483648);
}

@test:Config
function testTransportBodyLimitRejectsValuesThatMakeNoSense() {
    foreach int value in [0, -1, -5, 1073741825, 4611686018427387904, 9223372036854775807] {
        test:assertTrue(transportBodyLimit(value) is error, value.toString());
    }
}

@test:Config
function testTelemetryMustStayOff() {
    test:assertTrue(checkTelemetryIsOff(false, false, false) is ());
    test:assertTrue(checkTelemetryIsOff(true, false, false) is error);
    test:assertTrue(checkTelemetryIsOff(false, true, false) is error);
    test:assertTrue(checkTelemetryIsOff(false, false, true) is error);
    test:assertTrue(checkTelemetryIsOff(true, true, true) is error);
}
