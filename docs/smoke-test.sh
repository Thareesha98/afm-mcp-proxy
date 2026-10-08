#!/usr/bin/env bash
set -u

: "${PROXY_URL:?set PROXY_URL to the invoke URL of the deployed endpoint}"
: "${APP_ORIGIN:?set APP_ORIGIN to an origin listed in allowedOrigins}"

HEADERS=$(mktemp)
BODY=$(mktemp)
trap 'rm -f "$HEADERS" "$BODY"' EXIT
FAILURES=0
STATUS=""

call() {
    local method=$1 target=$2
    shift 2
    if [ -n "$target" ]; then
        STATUS=$(curl -s -m 40 -X "$method" --url-query "target=$target" -D "$HEADERS" -o "$BODY" -w '%{http_code}' "$@" "$PROXY_URL")
    else
        STATUS=$(curl -s -m 40 -X "$method" -D "$HEADERS" -o "$BODY" -w '%{http_code}' "$@" "$PROXY_URL")
    fi
}

header() {
    grep -i "^$1:" "$HEADERS" | tail -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '\r'
}

body_has() {
    grep -q -- "$1" "$BODY"
}

pass() {
    echo "PASS  $1"
}

fail() {
    echo "FAIL  $1"
    echo "      $2"
    FAILURES=$((FAILURES + 1))
}

from_proxy() {
    [ "$(header referrer-policy)" = "no-referrer" ]
}

if ! curl --help all 2>/dev/null | grep -q -- '--url-query'; then
    echo "curl is too old: --url-query needs curl 7.87 or newer"
    exit 2
fi

echo "Proxy: $PROXY_URL"
echo "Origin: $APP_ORIGIN"
echo

call GET "" -H "Origin: $APP_ORIGIN"
if [ "$STATUS" = "400" ] && body_has "Missing target URL" && from_proxy; then
    pass "1  a request without a target is answered by the proxy (400 Missing target URL)"
elif [ "$STATUS" = "401" ] || [ "$STATUS" = "403" ]; then
    fail "1  the gateway refused the request (HTTP $STATUS)" "Either endpoint security is still on (clear OAuth2 for the endpoint in the Choreo console and redeploy) or APP_ORIGIN is not in allowedOrigins. Body: $(head -c 200 "$BODY")"
else
    fail "1  unexpected answer (HTTP $STATUS)" "Check PROXY_URL (try it with and without a trailing slash). Body: $(head -c 200 "$BODY")"
fi

REQUESTED="authorization, content-type, mcp-session-id, mcp-protocol-version, last-event-id, x-api-key"
call OPTIONS "" -H "Origin: $APP_ORIGIN" -H "Access-Control-Request-Method: POST" -H "Access-Control-Request-Headers: $REQUESTED"
ALLOW_ORIGIN=$(header access-control-allow-origin)
ALLOW_HEADERS=$(header access-control-allow-headers | tr 'A-Z' 'a-z')
MISSING=""
for name in authorization content-type mcp-session-id mcp-protocol-version last-event-id x-api-key; do
    case ",$(echo "$ALLOW_HEADERS" | tr -d ' ')," in
        *",$name,"*) ;;
        *) MISSING="$MISSING $name" ;;
    esac
done
if [ "$STATUS" != "204" ] && [ "$STATUS" != "200" ]; then
    fail "2  the preflight was refused (HTTP $STATUS)" "OPTIONS does not reach the proxy. Check the gateway CORS and security settings. Body: $(head -c 200 "$BODY")"
elif [ -z "$ALLOW_ORIGIN" ]; then
    fail "2  the preflight has no Access-Control-Allow-Origin" "APP_ORIGIN is probably not in allowedOrigins."
elif [ "$ALLOW_ORIGIN" != "$APP_ORIGIN" ]; then
    fail "2  Access-Control-Allow-Origin is '$ALLOW_ORIGIN', expected '$APP_ORIGIN'" "The gateway is answering the preflight with its own CORS settings (the proxy never sends *). Fix them in the console."
elif [ -n "$MISSING" ]; then
    fail "2  the preflight does not allow these headers:$MISSING" "The gateway is answering the preflight with its own list. Add them in the console CORS settings, or turn gateway CORS off."
else
    if [ "$(header access-control-max-age)" = "600" ] && from_proxy; then
        pass "2  preflight allowed, answered by the proxy"
    else
        pass "2  preflight allowed, but answered by the gateway (its CORS settings are in effect)"
    fi
fi

call GET "https://example.com/" -H "Origin: https://not-allowed.example"
if [ "$STATUS" = "403" ] && body_has "Origin not allowed"; then
    pass "3  an origin that is not allowed gets 403"
else
    fail "3  an origin that is not allowed got HTTP $STATUS" "Body: $(head -c 200 "$BODY")"
fi

call GET "https://169.254.169.254/latest/meta-data/" -H "Origin: $APP_ORIGIN"
if [ "$STATUS" = "403" ] && body_has "blocked address range"; then
    pass "4a the cloud metadata address is refused (403)"
else
    fail "4a the cloud metadata address got HTTP $STATUS" "Body: $(head -c 200 "$BODY")"
fi
call GET "http://example.com/" -H "Origin: $APP_ORIGIN"
if [ "$STATUS" = "400" ] && body_has "Plain http targets are not allowed"; then
    pass "4b a plain http target is refused (400)"
else
    fail "4b a plain http target got HTTP $STATUS" "Body: $(head -c 200 "$BODY")"
fi

call GET "https://example.com:8443/" -H "Origin: $APP_ORIGIN"
if [ "$STATUS" = "403" ] && body_has "Target port is not allowed"; then
    pass "4c a port outside allowedPorts is refused (403)"
else
    fail "4c a port outside allowedPorts got HTTP $STATUS" "The deployed proxy may be an older build without the port rule. Body: $(head -c 200 "$BODY")"
fi

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"smoke-test","version":"1"}}}'
call POST "https://mcp.deepwiki.com/mcp" -H "Origin: $APP_ORIGIN" -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" --data "$INIT"
if [ "$STATUS" = "200" ] && body_has "protocolVersion"; then
    if [ "$(header access-control-allow-origin)" = "$APP_ORIGIN" ]; then
        pass "5  an MCP initialize through the proxy works and carries CORS headers"
    else
        fail "5  the relay works but Access-Control-Allow-Origin is '$(header access-control-allow-origin)'" "A browser would reject this answer."
    fi
else
    fail "5  an MCP initialize got HTTP $STATUS" "Body: $(head -c 300 "$BODY")"
fi

call GET "https://httpbin.org/headers" -H "Origin: $APP_ORIGIN" -H "Authorization: Bearer smoke-test-token" -H "X-Api-Key: smoke-test-key" -H "Cookie: smoke-cookie=1"
if [ "$STATUS" != "200" ]; then
    echo "SKIP  6  httpbin.org answered HTTP $STATUS, so header forwarding was not checked"
elif body_has "smoke-test-token" && body_has "smoke-test-key" && ! body_has "smoke-cookie"; then
    pass "6  Authorization and X-Api-Key reach the target, the Cookie does not"
else
    fail "6  header forwarding is wrong" "The target saw: $(tr -d '\n ' < "$BODY" | head -c 400)"
fi

call GET "https://httpbin.org/redirect-to?url=/get&status_code=307" -H "Origin: $APP_ORIGIN"
if [ "$STATUS" = "200" ] && body_has "httpbin.org/get"; then
    pass "7  a relative redirect is followed by the proxy"
elif [ "$STATUS" = "307" ]; then
    fail "7  the redirect was handed back instead of followed (HTTP 307)" "The deployed proxy is an older build without redirect following. Rebuild and deploy it."
else
    fail "7  following a redirect gave HTTP $STATUS" "Body: $(head -c 300 "$BODY")"
fi

echo
if [ "$FAILURES" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$FAILURES check(s) failed."
    exit 1
fi
