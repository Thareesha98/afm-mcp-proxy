# AFM MCP proxy

A small relay, written in Ballerina, that lets a browser app talk to remote MCP and OAuth servers. A browser cannot call most of them directly because of CORS. The proxy makes the call for it and sends the answer back with the right CORS headers.

It adds nothing to the traffic and keeps nothing: no sessions, no database, no logging of requests.

## What it does

- Takes `GET`, `POST` and `DELETE` requests for `/?target=<url-encoded https URL>` and forwards them to the target. The response, including a server-sent event stream, is passed back as it arrives.
- Answers the browser's `OPTIONS` preflight and adds CORS headers, but only for the origins in `allowedOrigins`. A request from any other origin gets 403.
- Refuses targets that resolve to private, loopback or otherwise non-public addresses. The name is resolved once and the proxy connects to the address it checked, over TLS with the host name verified. Redirects are not followed.
- Passes `Authorization`, `X-Api-Key` and similar headers to the target, and never forwards `Cookie`, `Origin`, `Referer` or proxy headers. `Set-Cookie` is never returned.
- Applies one shared rate limit to the whole relay.

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

The proxy refuses to start when Ballerina observability, metrics or tracing is switched on, because they would record request URLs, and the URL holds the target.

`Config.toml` also sets `maxBackPressureStallTime = 10` for `ballerina/http`, so a transfer nobody reads is released after seconds instead of minutes. As an environment variable that is `BAL_CONFIG_VAR_BALLERINA_HTTP_MAXBACKPRESSURESTALLTIME`.

## Run and test

```bash
bal run
bal test                              # needs ports 9300, 9301 and 9302 free
bal test --disable-groups network     # without the two tests that need the internet
```

The code is split by job: `config.bal` (settings and startup checks), `ssrf.bal` (target checks), `limits.bal` (rate limit), `gate.bal` (CORS and request checks), `forward.bal` (the call to the target), `service.bal` (the listener that ties them together).

## Deploy

See [docs/CHOREO_DEPLOYMENT.md](docs/CHOREO_DEPLOYMENT.md) for the Choreo steps and `docs/smoke-test.sh` to check a deployed proxy. The architecture is drawn in [docs/architecture.png](docs/architecture.png).

## Known limits

- A response is never capped in size, and a stream is not cut at a deadline: the timeout is an idle timeout.
- A request body is read into memory in full, up to `maxBodyBytes`.
- Rejections made by the HTTP listener itself (414, 431, 408, and a body over twice `maxBodyBytes`) carry no CORS headers.
- IPv6 literals, internationalised host names and URLs with user-info are not accepted as targets.
- The rate limit is one shared budget kept in memory per instance.
