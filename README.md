# AFM MCP proxy

A small relay, written in Ballerina, that lets a browser app talk to remote MCP and OAuth servers. A browser cannot call most of them directly because of CORS. The proxy makes the call for it and sends the answer back with the right CORS headers.

It adds nothing to the traffic and keeps nothing: no sessions, no database, no logging of requests. Its only log output is a startup line and, every minute, one line of counts (see Monitoring).

## What it does

- Takes `GET`, `POST` and `DELETE` requests for `/?target=<url-encoded https URL>` and forwards them to the target. The response, including a server-sent event stream, is passed back as it arrives.
- Answers the browser's `OPTIONS` preflight and adds CORS headers, but only for the origins in `allowedOrigins`. A request from any other origin gets 403.
- Refuses targets that resolve to private, loopback or otherwise non-public addresses. The name is resolved once and the proxy connects to the address it checked, over TLS with the host name verified. A target may only use a port from `allowedPorts` (443 by default).
- Follows redirects (301, 302, 303, 307, 308) itself, up to 3, and checks every hop exactly like the first target, so a redirect to a private address is refused with 502. A hop to another host is sent without credentials: only `Accept`, `Accept-Encoding`, `Accept-Language`, `Content-Type`, `Mcp-Protocol-Version` and `User-Agent` go on. 307 and 308 keep the method and body; 303, and 301 or 302 on a POST, become a GET.
- Passes `Authorization`, `X-Api-Key` and similar headers to the target, and never forwards `Cookie`, `Origin`, `Referer`, proxy headers or the headers Choreo adds (`X-Choreo-*`, `X-Envoy-*`, `X-Correlation-Id`, `X-Trace-Key`). `Set-Cookie` is never returned.
- Applies one shared rate limit to the whole relay. A request from an origin that is not allowed is refused before it uses any of it.

## Configuration

Values come from `Config.toml`, from environment variables named `BAL_CONFIG_VAR_<NAME>` in upper case (for example `BAL_CONFIG_VAR_ALLOWEDORIGINS`), or from the command line. A wrong `BAL_CONFIG_VAR_` name stops the proxy at startup.

| Setting | Default | Meaning |
|---|---|---|
| `allowedOrigins` | `http://localhost:5173` | Comma-separated origins (`scheme://host[:port]`). No wildcard, no path. |
| `port` | `8787` | Listening port. Keep `.choreo/component.yaml` in step with it. |
| `allowLoopback` | `false` | Development only: allows loopback and plain `http` targets. |
| `requestsPerMinute` | `1200` | Refill rate of the shared rate limit. |
| `burst` | `300` | Size of the shared rate limit bucket. |
| `maxBodyBytes` | `1000000` | Largest accepted request body (1 to 1073741824). |
| `maxRequestSeconds` | `120` | Time allowed for the target to answer. |
| `statsIntervalSeconds` | `60` | Seconds between the summary lines of counts. |
| `allowedPorts` | `443` | Comma-separated ports a target may use. Applies in development too: with `allowLoopback`, list the ports of your local servers as well. |

The proxy refuses to start when Ballerina observability, metrics or tracing is switched on, because they would record request URLs, and the URL holds the target.

`Config.toml` also sets `maxBackPressureStallTime = 10` for `ballerina/http`, so a transfer nobody reads is released after seconds instead of minutes. As an environment variable that is `BAL_CONFIG_VAR_BALLERINA_HTTP_MAXBACKPRESSURESTALLTIME`.

## Monitoring

Every `statsIntervalSeconds` the proxy writes one line of counts, and nothing else about requests: no URLs, headers, addresses or bodies.

```text
stats requests=412 ok=380 redirects=2 clientErrors=25 serverErrors=5 forbidden=12 rateLimited=8 upstreamErrors=2 internalErrors=0 inFlight=3 peakInFlight=17
```

| Count | Meaning |
|---|---|
| `requests` | requests answered since the last line |
| `ok`, `redirects`, `clientErrors`, `serverErrors` | the status class (2xx, 3xx, 4xx, 5xx) of every answer, whoever produced it |
| `forbidden` | the proxy's own 403: an origin that is not allowed, a private target, or a port that is not allowed |
| `rateLimited` | the proxy's own 429 |
| `upstreamErrors` | the proxy's own 502 and 504: DNS failed, the target was unreachable or too slow, or a redirect went somewhere refused |
| `internalErrors` | the proxy's own 500 |
| `inFlight`, `peakInFlight` | requests being answered now, and the most at once since the last line |

A target's own 403 or 500 only shows in the status classes, never in the proxy's own counts. When the rate limit refused anything, or an internal error happened, a `WARN` line follows: `rate limit refused N requests since the last stats line` or `internal errors: N since the last stats line`. The counts start from zero on a restart and cover one instance.

## Who can use the proxy

`allowedOrigins` keeps other websites out. A browser always sends its real `Origin`, and a page cannot change it. It is not a login: anything that is not a browser, such as curl or a script, can send any `Origin` it likes. So anyone who knows the proxy's URL and one allowed origin can have it fetch any public address, and the target sees the proxy's address, not theirs. A browser app has no place to keep a secret, so this cannot be closed completely.

What limits the damage: the shared rate limit, the body size limit, targets restricted to public addresses and to `allowedPorts`, at most 3 redirects, and the counts and `WARN` lines (see Monitoring) that show when it is being abused.

To stop all use quickly while keeping the endpoint, set `allowedOrigins` to a made-up origin that only you know (for example `https://off-` followed by random letters and `.invalid`) and redeploy. Every request then gets 403 and no browser can read the preflight answer.

## Run and test

```bash
bal run
bal test                              # needs ports 9300, 9301 and 9302 free
bal test --disable-groups network     # without the two tests that need the internet
```

The code is split by job: `config.bal` (settings and startup checks), `ssrf.bal` (target checks), `limits.bal` (rate limit), `gate.bal` (CORS and request checks), `forward.bal` (the call to the target), `redirect.bal` (following redirects), `stats.bal` (the counts), `service.bal` (the listener that ties them together).

## Deploy

See [docs/CHOREO_DEPLOYMENT.md](docs/CHOREO_DEPLOYMENT.md) for the Choreo steps and `docs/smoke-test.sh` to check a deployed proxy. The architecture is drawn in [docs/architecture.png](docs/architecture.png).

## Known limits

- A response is never capped in size, and a stream is not cut at a deadline: the timeout is an idle timeout.
- A request body is read into memory in full, up to `maxBodyBytes`.
- Rejections made by the HTTP listener itself (414, 431, 408, and a body over twice `maxBodyBytes`) carry no CORS headers.
- IPv6 literals, internationalised host names and URLs with user-info are not accepted as targets.
- `./` and `../` in a path, in a target or in a redirect's `Location`, are passed on as written and not normalised.
- The rate limit and the counts are kept in memory per instance and start from zero on a restart.
- A request waiting for a slow target keeps its body in memory, about 1.3 times its size in a test with 1 MB bodies. Many large bodies at once can use up the memory of a small container, so lower `maxBodyBytes` if you run with little memory.
