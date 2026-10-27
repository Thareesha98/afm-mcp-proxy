# AFM MCP proxy

A small relay, written in Ballerina, that lets a browser app talk to remote MCP and OAuth servers. A browser cannot call most of them directly because of CORS. The proxy makes the call for it and sends the answer back with the right CORS headers.

It adds nothing to the traffic and has no database and no logging of requests. The only things it holds are in memory and are lost on a restart: the rate limit buckets, the counts, and a small table of session ids (see Sessions). Its only log output is a startup line and, every minute, one line of counts (see Monitoring).

## What it does

- Takes `GET`, `POST` and `DELETE` requests for `/?target=<url-encoded https URL>` and forwards them to the target. The response, including a server-sent event stream, is passed back as it arrives.
- Answers the browser's `OPTIONS` preflight and adds CORS headers, but only for the origins in `allowedOrigins`. A request from any other origin gets 403.
- Refuses targets that resolve to private, loopback or otherwise non-public addresses. The name is resolved once and the proxy connects to the address it checked, over TLS with the host name verified. The next checked address is tried only when the connection could not be made (refused, unreachable, timed out or the TLS handshake failed); a request that has been sent to a server is never sent again. A target may only use a port from `allowedPorts` (443 by default).
- Follows redirects (301, 302, 303, 307, 308) itself, up to 3, but only for a `GET` that has no body and no credential. A credential is any header whose name contains `auth`, `key`, `token`, `secret`, `session`, `cookie`, `password` or `credential`, such as `Authorization`, `X-Api-Key` or `Mcp-Session-Id`. Every hop is checked exactly like the first target, so a redirect to a private address is refused with 502. A hop to another host is sent with only `Accept`, `Accept-Encoding`, `Accept-Language`, `Content-Type`, `Mcp-Protocol-Version` and `User-Agent`.
- Never follows a redirect for a request that has a body or a credential, nor for `POST` and `DELETE`, not even on the same host. The proxy answers 502 `The target answered with a redirect, which is not followed for a request with a body or credentials` and does not pass the redirect on, because the browser would send the body again itself. A server that redirects its MCP address (for example `/mcp` to `/mcp/`) has to be used at the final address.
- Passes `Authorization`, `X-Api-Key` and similar headers to the target, and never forwards `Cookie`, `Origin`, `Referer`, proxy headers or the headers Choreo adds (`X-Choreo-*`, `X-Envoy-*`, `X-Correlation-Id`, `X-Trace-Key`). `Set-Cookie` is never returned.
- Applies one shared rate limit to the whole relay, and a separate limit to every session (see Sessions). A request from an origin that is not allowed is refused before it uses any of either.

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
| `maxRequestSeconds` | `50` | Time allowed for the target to answer. Keep it below the 1 minute the Choreo gateway allows. |
| `statsIntervalSeconds` | `60` | Seconds between the summary lines of counts. |
| `sessionRequestsPerMinute` | `120` | Refill rate of the bucket every session has. Requests that carry no valid session id share one bucket of the same size. |
| `sessionBurst` | `30` | Size of a session bucket. |
| `newSessionsPerMinute` | `12` | Refill rate of the limit on handing out new session ids, for the whole proxy. |
| `newSessionBurst` | `6` | Size of that limit: how many ids can be handed out at once. |
| `maxSessions` | `10000` | Most sessions held at once. When the table is full the least recently used session is dropped. Each costs about 1 KB. |
| `sessionLifetimeSeconds` | `1800` | How long a session lasts, counted from when it was handed out, however much it is used. |
| `allowedPorts` | `443` | Comma-separated ports a target may use. Applies in development too: with `allowLoopback`, list the ports of your local servers as well. |

The proxy refuses to start when Ballerina observability, metrics or tracing is switched on, because they would record request URLs, and the URL holds the target.

`Config.toml` also sets `maxBackPressureStallTime = 10` for `ballerina/http`, so a transfer nobody reads is released after seconds instead of minutes. As an environment variable that is `BAL_CONFIG_VAR_BALLERINA_HTTP_MAXBACKPRESSURESTALLTIME`.

## Monitoring

Every `statsIntervalSeconds` the proxy writes one line of counts, and nothing else about requests: no URLs, headers, addresses or bodies.

```text
stats requests=412 ok=380 redirects=2 clientErrors=25 serverErrors=5 forbidden=12 rateLimited=8 upstreamErrors=2 internalErrors=0 newSessions=9 inFlight=3 peakInFlight=17 sessions=41
```

| Count | Meaning |
|---|---|
| `requests` | requests answered since the last line |
| `ok`, `redirects`, `clientErrors`, `serverErrors` | the status class (2xx, 3xx, 4xx, 5xx) of every answer, whoever produced it |
| `forbidden` | the proxy's own 403: an origin that is not allowed, a private target, or a port that is not allowed |
| `rateLimited` | the proxy's own 429 |
| `upstreamErrors` | the proxy's own 502 and 504: DNS failed, the target was unreachable or too slow, or a redirect was refused or not followed |
| `internalErrors` | the proxy's own 500 |
| `newSessions` | session ids handed out since the last line |
| `sessions` | entries in the session table now, including idle ones that have not been dropped yet |
| `inFlight`, `peakInFlight` | requests being answered now, and the most at once since the last line |

A target's own 403 or 500 only shows in the status classes, never in the proxy's own counts. When the rate limit refused anything, or an internal error happened, a `WARN` line follows: `rate limit refused N requests since the last stats line` or `internal errors: N since the last stats line`. The counts start from zero on a restart and cover one instance.

## Sessions

Every client holds a session id and the proxy keeps one rate limit bucket per id, so one noisy client cannot use up everyone's share. There is no sign-in and nothing is stored on disk: the table lives in memory and a restart only costs each client a new id.

- The id travels in the `X-Choreo-Correlation-Id` request header and looks like `afm-` followed by a UUID. Choreo's gateway passes a client's value of this header through unchanged and fills it with its own random value when the client sends none, so the proxy accepts only ids it handed out itself (they all look like `afm-` followed by a UUID). Anything else, including Choreo's own value, counts as no id.
- A request without a valid id gets a new session if the limit on new ids allows it (`newSessionsPerMinute`, `newSessionBurst`). The request is served as normal and the new id comes back in the same response header, which the client keeps and sends from then on. The response is marked `Cache-Control: no-store` so no cache can hand the id to someone else.
- When the limit on new ids is used up, requests without an id share one anonymous bucket and get no id until a new one is allowed.
- A session that is over its limit gets `429` with the message `Too many requests from this session` and `Retry-After: 60`. The shared limit for the whole relay still applies on top.
- A session ends after `sessionLifetimeSeconds` however much it is used. A client that sends an id the proxy no longer knows, after the lifetime ends, after a restart or after the table dropped it, simply gets a new one in the response.
- The header is removed before the request goes to the target, and a target cannot set it in its answer.
- The browser can only send the header if the Choreo gateway allows it: add `X-Choreo-Correlation-Id` to the allowed headers in the endpoint's CORS settings in the Choreo console (see docs/CHOREO_DEPLOYMENT.md).

After a restart or a redeploy every active client needs a new id at once. If more clients come back together than `newSessionBurst` allows, the others share the anonymous bucket until more ids are allowed (one every `60 / newSessionsPerMinute` seconds), so set `newSessionBurst` at least as high as the number of people you expect to be active.

An id is chosen by the proxy but is not a login. Anyone can ask for new ids, only as fast as the limit on new ids allows, and each id then has its own bucket, so this stops a single noisy or careless client, not a determined attacker who collects many ids. The shared limit for the whole relay is still the outer cap.

## Who can use the proxy

`allowedOrigins` keeps other websites out. A browser always sends its real `Origin`, and a page cannot change it. It is not a login: anything that is not a browser, such as curl or a script, can send any `Origin` it likes. So anyone who knows the proxy's URL and one allowed origin can have it fetch any public address, and the target sees the proxy's address, not theirs. A browser app has no place to keep a secret, so this cannot be closed completely.

What limits the damage: the shared rate limit, the body size limit, targets restricted to public addresses and to `allowedPorts`, at most 3 redirects, and the counts and `WARN` lines (see Monitoring) that show when it is being abused.

To stop all use quickly while keeping the endpoint, set `allowedOrigins` to a made-up origin that only you know (for example `https://off-` followed by random letters and `.invalid`) and redeploy. Every request then gets 403 and no browser can read the preflight answer.

## Run and test

```bash
bal run
bal test                              # needs ports 9300 to 9304 free
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
- The rate limits, the counts and the session table are kept in memory per instance and start from zero on a restart. With more than one replica every replica has its own table, so a session id from one replica is unknown to the others and clients would swap ids; run one replica, or add a signature to the ids first.
- A request waiting for a slow target keeps its body in memory, about 1.3 times its size in a test with 1 MB bodies. Many large bodies at once can use up the memory of a small container, so lower `maxBodyBytes` if you run with little memory.
