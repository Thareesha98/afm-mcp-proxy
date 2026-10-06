# Deploying the proxy to Choreo

This is the exact order of steps. Do them in order and stop at the first surprise: each step says what you should see.

## What is already checked and what only your first deploy can show

Checked here, on this machine, with the real build:

- The project builds (`bal build`) and all 107 tests pass. The tests use the ports 9300, 9301 and 9302, so stop anything else on them first: `tools/afm-mcp-lab-upstream.mjs` also uses 9301, and while it runs 22 tests fail for that reason alone.
- The built jar starts in about 2 seconds, listens on all interfaces, and runs fine with a 128 MB heap (7,500 mixed requests, no errors, about 210 MB of memory).
- With production-like settings (no loopback, one allowed origin) `docs/smoke-test.sh` passes all its checks. It also fails correctly against a wrong origin and against a fake gateway that answers 401.
- The environment variable that sets the `ballerina/http` stall time is `BAL_CONFIG_VAR_BALLERINA_HTTP_MAXBACKPRESSURESTALLTIME`. Any other name is rejected at startup as "unused environment variable".

Taken from Choreo's own documentation (docs repository, latest commit 2026-09-15) and sample projects:

- `.choreo/component.yaml` is needed here: Choreo cannot detect a port that is a configurable.
- With no schema file Choreo exposes `/*` on every HTTP method.
- Endpoint authentication is on by default and can be disabled (Choreo's MCP server guide puts that note at the **Endpoint Details** step of the deploy).
- Limits for services: payload 50 MB, URL 2 KB, headers 40 KB, total request time 1 minute by default (10 seconds to 5 minutes).
- New services scale to zero only on a short list of ports. 8787 is not on it, so the proxy stays running.

Not documented anywhere, so your first deploy and the smoke test must show it:

- Whether Choreo supports Ballerina **2201.13.4**. Choreo's docs list versions only up to 2201.7.0 and its own samples go up to 2201.10.4. The first build answers this.
- What the gateway does with CORS preflights, and whether it forwards the `Authorization` header when security is off.
- Whether the gateway log records the `?target=` part of the URL.
- The default CPU and memory of a component.

## 1. Before you start

- A GitHub account (decide which one: run `gh auth status` if you use the GitHub CLI, and check the active account before pushing).
- A Choreo account at https://console.choreo.dev/ with an organization. The free tier allows 5 APIs. This proxy uses 1.
- The origin of your browser app in production, for example `https://app.example.com` (scheme and host, plus a port only if it is not the default, and no path).

## 2. Put the project in a private GitHub repository

Decide what goes in. These files are not part of the proxy itself and are yours to decide on:

- `AFM_PROXY_TERMINAL_LAB.md` still describes a per-client burst limit and a response size cap, which were removed, and says the development settings are in `Config.toml`, where they are not. Update or leave it out.
- `tools/afm-mcp-lab-upstream.mjs` and `MCP_PROXY_FAST_GUIDE.md`.

Then, from the project folder:

```bash
cd /Users/thareesha/mcp-proxy
git init -b main
git add .
git status          # check the list: there must be no target/ folder and nothing you do not want to publish
git commit -m "Initial commit"
```

Create an empty **private** repository on GitHub (web page: New repository, no README, no .gitignore), then:

```bash
git remote add origin git@github.com:<your-account>/<repo-name>.git
git push -u origin main
```

## 3. Create the component in Choreo

1. Sign in at https://console.choreo.dev/. The default project is fine, or click **+ Create Project**.
2. On the project home page click **Service** under **Create a Component**.
3. Click **Authorize with GitHub**. In the GitHub page that opens, install the Choreo GitHub App and give it access to **only this repository**.
4. Fill in:

   | Field | Value |
   |---|---|
   | Organization | your GitHub account |
   | Repository | the repository you pushed |
   | Branch | `main` |
   | Component Directory | `/` |

5. Select **Ballerina** as the build preset.
6. Give it a display name (for example `MCP Proxy`) and a component name (for example `mcp-proxy`). **The component name cannot be changed later.**
7. Click **Create**.

## 4. Build

1. In the left menu click **Build**, then **Build Latest**. (For Ballerina components the first build must be started by hand.)
2. Watch **Build Details**. It must end with **Success**.

If it fails with a message about the Ballerina version or distribution, stop and keep the build log. Do not change versions blindly: `Ballerina.toml` and `Dependencies.toml` must always show the same version, and the code was only verified on 2201.13.4.

## 5. Configure and deploy

1. Left menu **Deploy**. On the **Set Up** card click **Configure & Deploy**.
2. The first pane lists the proxy's settings (they are read from the code). Set:

   | Setting | Value | Why |
   |---|---|---|
   | `allowedOrigins` | your app origin, for example `https://app.example.com`. Several origins are comma-separated. | Without it only `http://localhost:5173` is allowed, and your app gets 403. No `*`, no path. |
   | `maxRequestSeconds` | `50` | The gateway cuts a request at 1 minute by default. With 50 the proxy answers first, and its error carries CORS headers so the browser app can read it. Raise both together if you raise the gateway timeout. |
   | everything else | leave the default | `port` stays 8787 and must always match `.choreo/component.yaml`. `allowLoopback` must stay `false`. `requestsPerMinute` 1200, `burst` 300 and `maxBodyBytes` 1000000 are fine for now. |

   Optional but recommended, after the first successful deploy: on the **Deploy** page click **Manage Configs and Secrets** in the environment card, expand **Environment Variables**, click **+ Add a Configuration**, add `BAL_CONFIG_VAR_BALLERINA_HTTP_MAXBACKPRESSURESTALLTIME` with the value `10`, then **Save and Deploy**. It makes an abandoned transfer free its connection in seconds instead of minutes. Spell the name exactly, because a wrong `BAL_CONFIG_VAR_` name stops the proxy from starting. Check the **Application** log again afterwards for the `listening` line.

3. Click **Next** through **File Mount** (nothing to add).
4. In **Endpoint Details** check: one endpoint named `mcp-proxy`, type REST, port 8787, visibility **Public**. Choreo enables endpoint authentication by default. **Turn authentication off** (clear OAuth2 if the pane shows that checkbox): a browser app cannot send a Choreo token, and the `Authorization` header must belong to the MCP server. (This setting is also on the **Set Up** card under **Endpoint Configurations**.)
5. Click **Deploy**. Wait until the **Development** card shows **Deployment Status: Active**.
6. Open **Observability** → **Runtime Logs**, log type **Application**. You must see the line `MCP proxy listening on :8787 (allowed origins: ...)` and the origins must be yours.

## 6. Test it

1. On the component's **Overview** tab copy the invoke URL (the copy icon in the **URL** field).
2. From any machine with internet and curl 7.87 or newer:

   ```bash
   PROXY_URL='<invoke url>' APP_ORIGIN='https://app.example.com' docs/smoke-test.sh
   ```

   Run it once with the URL as copied and once with a `/` added at the end (or removed). Use the form that passes in your app.

3. Read the result:

   | Failed check | Meaning | What to do |
   |---|---|---|
   | 1 with HTTP 401 | The gateway still wants a token. | Step 5.4: turn endpoint authentication off, deploy again. |
   | 1 with HTTP 404 | The URL path is wrong. | Compare with the invoke URL; try with and without the trailing `/`. |
   | 2 with a different origin or a short header list | The gateway answers the browser's preflight with its own CORS settings. | In the console find the CORS settings for the endpoint (documented as the **CORS, Rate Limiting and Resiliency** pane). If the console lets you turn gateway CORS off, do that, so the proxy answers. Otherwise allow your exact origin, the methods GET, POST, DELETE, OPTIONS, and the headers `authorization`, `content-type`, `mcp-session-id`, `mcp-protocol-version`, `last-event-id`, `x-api-key`, and expose `mcp-session-id` and `www-authenticate`. |
   | 3 to 5 with the proxy's own messages | The proxy works as designed. | Compare the message with the table below. |
   | 6 | Headers are altered on the way. | Keep the printed output and look at the gateway logs. |

4. See which hop answered: **Observability** → **Runtime Logs**, log type **Gateway**, field `gatewayCode`: `BACKEND_RESPONSE` means the proxy answered, `CORS_RESPONSE` the gateway answered a preflight, `AUTH_FAILURE` security is still on, `RESOURCE_NOT_FOUND` a path or method mismatch, `BACKEND_TIMEOUT` the gateway timed out, `RATE_LIMITED` the gateway limit.
5. Look at what the gateway logs contain: search the gateway log for `169.254.169.254` (a target the smoke test used). If the `RequestPath` shows the target, Choreo keeps the full URL in its gateway logs for as long as it keeps logs. The proxy itself never logs it. Decide whether that is acceptable.
6. Open **DevOps** → **Containers** and note the CPU and memory limits, and **DevOps** → **Runtime** for restarts. In my tests the proxy used about 150 MB right after start and about 210 MB under heavy load with the heap capped at 128 MB, and up to about 480 MB with no cap. A limit of 512 MB is comfortable. Below 256 MB is untested.

## 7. The proxy's own answers

| Status | Body | Cause |
|---|---|---|
| 400 | `Missing target URL` / `Invalid target URL` / `Plain http targets are not allowed; use https` / `Unsupported protocol` / `Invalid target port` / `Target host did not resolve` / `Could not read request body` | the request itself |
| 403 | `Origin not allowed` / `Target resolves to a blocked address range` | origin not in `allowedOrigins`, or a private target |
| 405 | `Method not allowed` | anything but GET, POST, DELETE, OPTIONS |
| 413 | `Request body too large` | body over `maxBodyBytes` |
| 429 | `Too many requests` (with `Retry-After: 60`) | the proxy's own limit |
| 500 | `Internal error` | an unexpected failure inside the proxy (report it with the time) |
| 502 | `Failed to validate target` / `Upstream request failed` | DNS failed or the target could not be reached |
| 504 | `Upstream timed out` | no answer within `maxRequestSeconds` |

## 8. If something is wrong

| Symptom | Where to look | Likely cause |
|---|---|---|
| Deployment never becomes Active, restarts | **DevOps** → **Runtime** events, then **Runtime Logs** (Application) | `invalid origin: ...` (bad `allowedOrigins`), `unused environment variable` (misspelled `BAL_CONFIG_VAR_` name), `observability must stay disabled` (the platform turned telemetry on; send me the log) |
| Browser says Access-Control-Allow-Origin has multiple values | browser console | the gateway and the proxy both add the header: turn gateway CORS off |
| Everything stops after 60 seconds | gateway log `BACKEND_TIMEOUT` | gateway timeout is shorter than the call: raise it (maximum 5 minutes) and `maxRequestSeconds` with it |
| First request after a quiet period is slow or 503 | **DevOps** → **Scaling** | only if scale-to-zero is on, which needs a port from Choreo's list; keep 8787 |
| Requests are limited too early | `RATE_LIMITED` in the gateway log, or 429 from the proxy | the two limits are separate; rate limiting is tested later |

## 9. Later, once the smoke test passes

- Point the app at the proxy: set the app's proxy URL to the invoke URL (the app adds `?target=` itself) and test with a real MCP server. Do this only when you decide to.
- Rate limiting: configure the gateway limit (environment card → view icon of the endpoint → settings icon → **Manage** → **Rate Limiting**) and test the four things listed in the project notes: the 429 after N requests, a second client sharing the count, whether the preflight counts, and whether the 429 has CORS headers.
- Production: **Promote** from the **Deploy** page, set `allowedOrigins` for production, and repeat steps 5.4 and 6 there, because settings are per environment.
- To take it down: **Deploy** page, undeploy. Nothing else depends on it until you point the app at it.
