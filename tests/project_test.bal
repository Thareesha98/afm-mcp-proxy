import ballerina/io;
import ballerina/test;

@test:Config
function testUnreadTransfersAreReclaimedQuickly() returns error? {
    string config = check io:fileReadString("Config.toml");
    test:assertTrue(config.includes("[ballerina.http]"), config);
    test:assertTrue(config.includes("maxBackPressureStallTime = 10"), config);
}

@test:Config
function testSecurityDefaultsAreSafe() returns error? {
    string config = check io:fileReadString("config.bal");
    test:assertTrue(config.includes("configurable boolean allowLoopback = false;"), config);
    test:assertTrue(config.includes("configurable string allowedPorts = \"443\";"), config);
    test:assertTrue(config.includes("configurable int maxRequestSeconds = 50;"), config);
    test:assertTrue(config.includes("configurable int maxResponseBytes = 10485760;"), config);
}

@test:Config
function testObservabilityIsNotCompiledIn() returns error? {
    string project = check io:fileReadString("Ballerina.toml");
    test:assertFalse(project.includes("observabilityIncluded"), project);
}

@test:Config
function testSessionDefaultsAreTheAgreedOnes() returns error? {
    string config = check io:fileReadString("config.bal");
    foreach string line in [
        "configurable int sessionRequestsPerMinute = 120;",
        "configurable int sessionBurst = 30;",
        "configurable int newSessionsPerMinute = 12;",
        "configurable int newSessionBurst = 6;",
        "configurable int maxSessions = 10000;",
        "configurable int sessionLifetimeSeconds = 1800;"
    ] {
        test:assertTrue(config.includes(line), line);
    }
}
