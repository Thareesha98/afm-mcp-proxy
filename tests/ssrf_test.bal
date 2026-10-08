import ballerina/test;

final int[] TEST_PORTS = [80, 443, 3000, 8443];

function assertStatus(Target|RequestError? result, int status) {
    if result is RequestError {
        test:assertEquals(result.detail().status, status);
    } else {
        test:assertFail("expected an error but the target was accepted");
    }
}

@test:Config
function testPublicAddressesAreAllowed() {
    string[] ips = [
        "8.8.8.8",
        "1.1.1.1",
        "93.184.216.34",
        "100.63.255.255",
        "100.128.0.1",
        "172.15.255.255",
        "172.32.0.1",
        "192.0.1.1",
        "198.17.255.255",
        "198.20.0.1",
        "168.63.129.15",
        "168.63.129.17",
        "168.63.128.16",
        "168.63.130.16",
        "168.62.129.16",
        "168.64.129.16",
        "167.63.129.16",
        "169.63.129.16",
        "2606:4700:10:0:0:0:ac42:93f3",
        "2a00:1450:4001:0:0:0:0:200e",
        "2001:200:0:0:0:0:0:1",
        "3fff:1000:0:0:0:0:0:1"
    ];
    foreach string ip in ips {
        test:assertFalse(isBlockedIp(ip, false), ip);
    }
}

@test:Config
function testNonPublicAddressesAreBlocked() {
    string[] ips = [
        "0.0.0.0",
        "0.1.2.3",
        "10.0.0.1",
        "10.255.255.255",
        "100.64.0.1",
        "100.127.255.255",
        "127.0.0.1",
        "127.1.2.3",
        "168.63.129.16",
        "169.254.169.254",
        "172.16.0.1",
        "172.31.255.255",
        "192.0.0.1",
        "192.0.2.1",
        "192.88.99.1",
        "192.168.1.1",
        "198.18.0.1",
        "198.19.255.255",
        "198.51.100.1",
        "203.0.113.1",
        "224.0.0.1",
        "239.255.255.255",
        "240.0.0.1",
        "255.255.255.255",
        "0:0:0:0:0:0:0:1",
        "0:0:0:0:0:0:0:0",
        "fe80:0:0:0:0:0:0:1%lo0",
        "fc00:0:0:0:0:0:0:1",
        "fd12:3456:0:0:0:0:0:1",
        "ff02:0:0:0:0:0:0:1",
        "2001:db8:0:0:0:0:0:1",
        "2001:0:0:0:0:0:0:1",
        "2001:1ff:0:0:0:0:0:1",
        "2002:a00:1:0:0:0:0:1",
        "64:ff9b:0:0:0:0:a00:1",
        "3fff:fff:0:0:0:0:0:1"
    ];
    foreach string ip in ips {
        test:assertTrue(isBlockedIp(ip, false), ip);
    }
}

@test:Config
function testMalformedAddressesAreBlocked() {
    foreach string ip in ["", "garbage", "1.2.3", "1.2.3.4.5", "1.2.3.x", "::1", "2001"] {
        test:assertTrue(isBlockedIp(ip, false), ip);
    }
}

@test:Config
function testAddressesThatAreNotCanonicalAreBlockedEvenIfTheyLookPublic() {
    string[] ips = [
        "1.300.1.1",
        "1.2.3.-4",
        "1.2.3.+4",
        "256.1.1.1",
        "1.2.3.256",
        " 1.2.3.4",
        "1.2.3.4 ",
        "12345.1.1.1",
        "2001:db8",
        "2606:4700:10:0:0:0:ac42:93f3:1",
        "2606:4700:10:0:0:0:ac42:fffff",
        "2606:4700:10:0:0:0:ac42:g",
        "2606:-1:10:0:0:0:ac42:93f3",
        "2606:4700:10:0:0:0:ac42:93f3 ",
        "2606:4700:10::ac42:93f3",
        "127.0.0.256",
        "127.garbage",
        "127.0.0.1.5",
        "127.1",
        "0:0:0:0:0:0:0:1:5",
        "0:0:0:0:0:0:0:01x"
    ];
    foreach string ip in ips {
        test:assertTrue(isBlockedIp(ip, false), ip);
        test:assertTrue(isBlockedIp(ip, true), ip);
    }
}

@test:Config
function testLoopbackFlagAllowsOnlyLoopback() {
    foreach string ip in ["127.0.0.1", "127.5.5.5", "0:0:0:0:0:0:0:1"] {
        test:assertFalse(isBlockedIp(ip, true), ip);
    }
    foreach string ip in ["10.0.0.1", "169.254.169.254", "0.0.0.0", "192.168.1.1", "fe80:0:0:0:0:0:0:1", "fc00:0:0:0:0:0:0:1"] {
        test:assertTrue(isBlockedIp(ip, true), ip);
    }
}

@test:Config
function testCheckAddresses() {
    test:assertTrue(checkAddresses(["8.8.8.8"], false) is ());
    test:assertTrue(checkAddresses(["8.8.8.8", "1.1.1.1"], false) is ());
    assertStatus(checkAddresses(["8.8.8.8", "10.0.0.1"], false), 403);
    assertStatus(checkAddresses(["10.0.0.1", "8.8.8.8"], false), 403);
    assertStatus(checkAddresses([], false), 400);
}

@test:Config
function testResolveNormalizesAddresses() returns error? {
    test:assertEquals(check resolve("2130706433"), ["127.0.0.1"]);
    test:assertEquals(check resolve("127.1"), ["127.0.0.1"]);
    test:assertEquals(check resolve("::ffff:10.0.0.1"), ["10.0.0.1"]);
    test:assertEquals(check resolve("::1"), ["0:0:0:0:0:0:0:1"]);
    test:assertEquals(check resolve("2001:db8::1"), ["2001:db8:0:0:0:0:0:1"]);
    test:assertTrue(resolve("0x7f.1") is error);
    test:assertTrue(resolve("no-such-host.invalid") is error);
}

@test:Config
function testInvalidUrlsAreRejected() {
    string[] urls = [
        "not a url",
        "",
        "https://",
        "https:///path",
        "https://user@example.com",
        "https://user:pass@example.com",
        "https://example.com\\@evil.com",
        "https://[::1]/",
        "https://example.com:0",
        "https://example.com:99999",
        "https://example.com:99999999999999999999",
        "https://example.com:/x",
        "https://example.com/a b",
        "https://example.com/a\r\nHost: evil.com",
        "https://example.com/a\u{0}b"
    ];
    foreach string url in urls {
        assertStatus(checkTarget(url, false, TEST_PORTS), 400);
    }
}

@test:Config
function testOnlyHttpAndHttpsAreAllowed() {
    assertStatus(checkTarget("ftp://example.com", true, TEST_PORTS), 400);
    assertStatus(checkTarget("file://localhost/etc/passwd", true, TEST_PORTS), 400);
    assertStatus(checkTarget("gopher://example.com", false, TEST_PORTS), 400);
}

@test:Config
function testPlainHttpNeedsTheDevFlag() {
    assertStatus(checkTarget("http://8.8.8.8", false, TEST_PORTS), 400);
    assertStatus(checkTarget("http://example.com", false, TEST_PORTS), 400);
    test:assertTrue(checkTarget("http://8.8.8.8", true, TEST_PORTS) is Target);
}

@test:Config
function testPrivateTargetsAreRejected() {
    string[] urls = [
        "https://10.0.0.1",
        "https://169.254.169.254/latest/meta-data",
        "https://127.1",
        "https://2130706433",
        "https://localhost",
        "https://0",
        "https://192.168.0.1:8443/mcp"
    ];
    foreach string url in urls {
        assertStatus(checkTarget(url, false, TEST_PORTS), 403);
    }
}

@test:Config
function testOnlyListedPortsAreAllowed() returns error? {
    test:assertEquals((check checkTarget("https://8.8.8.8", false, [443])).port, 443);
    test:assertEquals((check checkTarget("https://8.8.8.8:443", false, [443])).port, 443);
    test:assertEquals((check checkTarget("https://8.8.8.8:8443", false, [443, 8443])).port, 8443);
    foreach string port in ["22", "80", "444", "8443", "65535"] {
        assertStatus(checkTarget("https://8.8.8.8:" + port, false, [443]), 403);
    }
}

@test:Config
function testThePortRuleAlsoHoldsInDevMode() returns error? {
    assertStatus(checkTarget("http://127.0.0.1:3000/mcp", true, [443]), 403);
    assertStatus(checkTarget("http://8.8.8.8", true, [443]), 403);
    test:assertTrue(checkTarget("http://127.0.0.1:3000/mcp", true, [3000]) is Target);
}

@test:Config
function testARefusedPortSaysSoAndNeverTriggersDns() {
    Target|RequestError result = checkTarget("https://no-such-host.invalid:22", false, [443]);
    assertStatus(result, 403);
    if result is RequestError {
        test:assertEquals(result.message(), "Target port is not allowed");
    }
}

@test:Config
function testUnresolvableTargetsAreRejected() {
    assertStatus(checkTarget("https://0x7f.1", false, TEST_PORTS), 502);
    assertStatus(checkTarget("https://no-such-host.invalid", false, TEST_PORTS), 502);
}

@test:Config
function testPublicTargetIsParsed() returns error? {
    Target target = check checkTarget("https://8.8.8.8:8443/mcp?x=1#frag", false, TEST_PORTS);
    test:assertEquals(target, {scheme: "https", host: "8.8.8.8", port: 8443, pathAndQuery: "/mcp?x=1", addresses: ["8.8.8.8"]});
}

@test:Config
function testDefaultPortsAndPaths() returns error? {
    Target target = check checkTarget("HTTPS://8.8.8.8", false, TEST_PORTS);
    test:assertEquals(target, {scheme: "https", host: "8.8.8.8", port: 443, pathAndQuery: "/", addresses: ["8.8.8.8"]});
    target = check checkTarget("https://8.8.8.8?x=1", false, TEST_PORTS);
    test:assertEquals(target.pathAndQuery, "/?x=1");
    target = check checkTarget("https://8.8.8.8/mcp", false, TEST_PORTS);
    test:assertEquals([target.port, target.pathAndQuery], [443, "/mcp"]);
    target = check checkTarget("https://8.8.8.8:8443", false, TEST_PORTS);
    test:assertEquals([target.port, target.pathAndQuery], [8443, "/"]);
    target = check checkTarget("http://8.8.8.8", true, TEST_PORTS);
    test:assertEquals(target.port, 80);
}

@test:Config
function testDevFlagAllowsLoopbackOnly() returns error? {
    Target target = check checkTarget("http://127.0.0.1:3000/mcp", true, TEST_PORTS);
    test:assertEquals(target, {scheme: "http", host: "127.0.0.1", port: 3000, pathAndQuery: "/mcp", addresses: ["127.0.0.1"]});
    test:assertTrue(checkTarget("http://localhost:3000", true, TEST_PORTS) is Target);
    assertStatus(checkTarget("http://10.0.0.1", true, TEST_PORTS), 403);
    assertStatus(checkTarget("https://169.254.169.254", true, TEST_PORTS), 403);
}

@test:Config
function testNat64AddressesAreJudgedByTheIpv4AddressTheyEmbed() {
    foreach string ip in ["64:ff9b:0:0:0:0:625b:275f", "64:ff9b:0:0:0:0:808:808", "64:ff9b:0:0:0:0:8c52:7116"] {
        test:assertFalse(isBlockedIp(ip, false), ip);
    }
    foreach string ip in [
        "64:ff9b:0:0:0:0:a00:1",
        "64:ff9b:0:0:0:0:7f00:1",
        "64:ff9b:0:0:0:0:a9fe:a9fe",
        "64:ff9b:0:0:0:0:c0a8:101",
        "64:ff9b:0:0:0:0:0:0",
        "64:ff9b:0:0:0:0:ffff:ffff",
        "64:ff9b:0:0:0:0:6440:1",
        "64:ff9b:0:0:0:0:e000:1",
        "64:ff9b:0:0:0:0:ac10:1",
        "64:ff9b:0:0:0:0:c000:201",
        "64:ff9b:0:0:0:0:cb00:7101"
    ] {
        test:assertTrue(isBlockedIp(ip, false), ip);
    }
}

@test:Config
function testOnlyTheWellKnownNat64PrefixIsUnwrapped() {
    foreach string ip in [
        "64:ff9b:1:0:0:0:0:1",
        "64:ff9b:1:0:0:0:808:808",
        "64:ff9b:0:0:0:1:808:808",
        "64:ff9b:0:0:1:0:808:808",
        "64:ff9b:0:1:0:0:808:808",
        "64:ff9b:0:0:0:0:0:0",
        "64:ff9a:0:0:0:0:808:808",
        "64:ff9c:0:0:0:0:808:808",
        "63:ff9b:0:0:0:0:808:808"
    ] {
        test:assertTrue(isBlockedIp(ip, false), ip);
    }
}

@test:Config
function testNat64LoopbackFollowsTheDevFlag() {
    test:assertFalse(isBlockedIp("64:ff9b:0:0:0:0:7f00:1", true));
    test:assertTrue(isBlockedIp("64:ff9b:0:0:0:0:a00:1", true));
    test:assertTrue(isBlockedIp("64:ff9b:0:0:0:0:7f00:1", false));
}

@test:Config
function testAHostWithBothAnIpv4AndASynthesizedNat64AddressIsAccepted() {
    test:assertTrue(checkAddresses(["98.91.39.95", "64:ff9b:0:0:0:0:625b:275f"], false) is ());
    assertStatus(checkAddresses(["98.91.39.95", "64:ff9b:0:0:0:0:a00:1"], false), 403);
}

@test:Config
function testAs112DirectDelegationIsBlocked() {
    test:assertTrue(isBlockedIp("2620:4f:8000:0:0:0:0:1", false));
    test:assertTrue(isBlockedIp("2620:4f:8000:ffff:ffff:ffff:ffff:ffff", false));
    test:assertFalse(isBlockedIp("2620:4f:8001:0:0:0:0:1", false));
    test:assertFalse(isBlockedIp("2620:4f:7fff:0:0:0:0:1", false));
    test:assertFalse(isBlockedIp("2620:4e:8000:0:0:0:0:1", false));
    test:assertFalse(isBlockedIp("2620:50:8000:0:0:0:0:1", false));
}

@test:Config
function testIllegalCharactersAreEscapedInTheRequestTarget() {
    map<string> expected = {
        "/mcp?q=ü": "/mcp?q=%C3%BC",
        "/ünï": "/%C3%BCn%C3%AF",
        "/日本": "/%E6%97%A5%E6%9C%AC",
        "/a{x}|b": "/a%7Bx%7D%7Cb",
        "/a\\b^c`d": "/a%5Cb%5Ec%60d",
        "/p?q=\"v\"<t>": "/p?q=%22v%22%3Ct%3E",
        "/a%20b%2Fc": "/a%20b%2Fc",
        "/a%zz%": "/a%zz%",
        "/p?q=a&b=c;d=e,f:g@h/i+j!k$l'm(n)o*p~q-r.s_t=u": "/p?q=a&b=c;d=e,f:g@h/i+j!k$l'm(n)o*p~q-r.s_t=u",
        "/p?a[0]=1&a[1]=2": "/p?a[0]=1&a[1]=2",
        "": "/",
        "?x=1": "/?x=1"
    };
    foreach [string, string] [input, output] in expected.entries() {
        Target|RequestError target = checkTarget("https://8.8.8.8" + input, false, TEST_PORTS);
        if target is Target {
            test:assertEquals(target.pathAndQuery, output, input);
        } else {
            test:assertFail("rejected " + input);
        }
    }
}
