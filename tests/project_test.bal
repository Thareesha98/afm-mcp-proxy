import ballerina/io;
import ballerina/test;

@test:Config
function testUnreadTransfersAreReclaimedQuickly() returns error? {
    string config = check io:fileReadString("Config.toml");
    test:assertTrue(config.includes("[ballerina.http]"), config);
    test:assertTrue(config.includes("maxBackPressureStallTime = 10"), config);
}

@test:Config
function testObservabilityIsNotCompiledIn() returns error? {
    string project = check io:fileReadString("Ballerina.toml");
    test:assertFalse(project.includes("observabilityIncluded"), project);
}
