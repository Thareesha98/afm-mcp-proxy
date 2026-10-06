import ballerina/jballerina.java;
import ballerina/jballerina.java.arrays as jarrays;
import ballerina/lang.regexp;

type RequestError error<record {|int status;|}>;

type Target record {|
    string scheme;
    string host;
    int port;
    string pathAndQuery;
    string[] addresses;
|};

function checkTarget(string rawUrl, boolean allowLoopback) returns Target|RequestError {
    regexp:Groups? groups = re `([a-zA-Z][a-zA-Z0-9+.\-]*)://([^/:?#@\\\s\[\]]+)(:\d+|)([/?][^#\s\p{Cc}]*|)(?:#.*)?`
        .fullMatchGroups(rawUrl);
    if groups is () {
        return error RequestError("Invalid target URL", status = 400);
    }
    string scheme = groupText(groups, 1).toLowerAscii();
    if scheme != "https" && scheme != "http" {
        return error RequestError("Unsupported protocol: " + scheme, status = 400);
    }
    if scheme == "http" && !allowLoopback {
        return error RequestError("Plain http targets are not allowed; use https", status = 400);
    }

    int targetPort = scheme == "https" ? 443 : 80;
    string portText = groupText(groups, 3);
    if portText != "" {
        int|error parsed = int:fromString(portText.substring(1));
        if parsed is error || parsed < 1 || parsed > 65535 {
            return error RequestError("Invalid target port", status = 400);
        }
        targetPort = parsed;
    }

    string host = groupText(groups, 2).toLowerAscii();
    string[]|error addresses = resolve(host);
    if addresses is error {
        return error RequestError("Failed to validate target", status = 502);
    }
    check checkAddresses(addresses, allowLoopback);

    string rest = groupText(groups, 4);
    return {scheme, host, port: targetPort, pathAndQuery: encodeRequestTarget(rest.startsWith("/") ? rest : "/" + rest), addresses};
}

function encodeRequestTarget(string target) returns string {
    string encoded = "";
    foreach string:Char char in target {
        if char.toCodePointInts()[0] > 126 || "\"<>\\^`{|}".includes(char) {
            foreach byte octet in char.toBytes() {
                encoded += "%" + int:toHexString(octet).toUpperAscii().padStart(2, "0");
            }
        } else {
            encoded += char;
        }
    }
    return encoded;
}

function groupText(regexp:Groups groups, int index) returns string {
    regexp:Span? span = groups[index];
    return span is regexp:Span ? span.substring() : "";
}

function checkAddresses(string[] addresses, boolean allowLoopback) returns RequestError? {
    if addresses.length() == 0 {
        return error RequestError("Target host did not resolve", status = 400);
    }
    foreach string address in addresses {
        if isBlockedIp(address, allowLoopback) {
            return error RequestError("Target resolves to a blocked address range", status = 403);
        }
    }
}

function isBlockedIp(string ip, boolean allowLoopback) returns boolean {
    return ip.includes(":") ? isBlockedIpv6(ip, allowLoopback) : isBlockedIpv4(ip, allowLoopback);
}

function isBlockedIpv4(string ip, boolean allowLoopback) returns boolean {
    if !re `\d{1,3}(\.\d{1,3}){3}`.isFullMatch(ip) {
        return true;
    }
    int[] parts = [];
    foreach string text in re `\.`.split(ip) {
        int|error part = int:fromString(text);
        if part is error || part > 255 {
            return true;
        }
        parts.push(part);
    }
    int a = parts[0];
    int b = parts[1];
    int c = parts[2];
    return a == 0 || a == 10 || (a == 127 && !allowLoopback) || a >= 224
        || (a == 100 && b >= 64 && b <= 127)
        || (a == 169 && b == 254)
        || (a == 172 && b >= 16 && b <= 31)
        || (a == 192 && b == 168)
        || (a == 192 && b == 0 && (c == 0 || c == 2))
        || (a == 192 && b == 88 && c == 99)
        || (a == 198 && (b == 18 || b == 19))
        || (a == 198 && b == 51 && c == 100)
        || (a == 203 && b == 0 && c == 113);
}

function isBlockedIpv6(string ip, boolean allowLoopback) returns boolean {
    if !re `[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){7}(%[0-9a-zA-Z._\-]+)?`.isFullMatch(ip) {
        return true;
    }
    if allowLoopback && re `(0:){7}1`.isFullMatch(ip) {
        return false;
    }
    string[] groups = re `:`.split(ip);
    if groups[0] == "64" && groups[1] == "ff9b" && groups.slice(2, 6).every(group => group == "0") {
        int|error high = int:fromHexString(groups[6]);
        int|error low = int:fromHexString(groups[7]);
        if high is error || low is error {
            return true;
        }
        return isBlockedIpv4(string `${high / 256}.${high % 256}.${low / 256}.${low % 256}`, allowLoopback);
    }
    int|error first = int:fromHexString(groups[0]);
    int|error second = int:fromHexString(groups[1]);
    int|error third = int:fromHexString(groups[2]);
    if first is error || second is error || third is error {
        return true;
    }
    boolean global = first >= 0x2000 && first <= 0x3fff;
    boolean special = (first == 0x2001 && (second < 0x200 || second == 0xdb8))
        || first == 0x2002
        || (first == 0x2620 && second == 0x4f && third == 0x8000)
        || (first == 0x3fff && second < 0x1000);
    return !global || special;
}

function resolve(string host) returns string[]|error {
    handle all = check getAllByName(java:fromString(host));
    string[] addresses = [];
    foreach int i in 0 ..< jarrays:getLength(all) {
        string? address = java:toString(getHostAddress(jarrays:get(all, i)));
        if address is string {
            addresses.push(address);
        }
    }
    return addresses;
}

function getAllByName(handle host) returns handle|error = @java:Method {
    'class: "java.net.InetAddress",
    name: "getAllByName"
} external;

function getHostAddress(handle address) returns handle = @java:Method {
    'class: "java.net.InetAddress",
    name: "getHostAddress"
} external;
