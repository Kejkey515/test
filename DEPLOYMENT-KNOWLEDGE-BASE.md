# BeEF on Render — Complete Deployment Knowledge Base

> **Purpose:** This document captures every lesson learned, pitfall encountered, and API quirk discovered while deploying BeEF (Browser Exploitation Framework) to Render.com. Any AI agent or human operator should read this BEFORE attempting a deployment.

---

## Table of Contents

1. [Quick Reference — Working Deployment](#1-quick-reference)
2. [File Inventory](#2-file-inventory)
3. [Render API — Exact Working Payloads](#3-render-api)
4. [GitHub API — File Upload](#4-github-api)
5. [Bug Fixes Applied (4 Iterations)](#5-bug-fixes)
6. [config.yaml — Critical Keys](#6-config-yaml)
7. [Dockerfile — Non-Obvious Requirements](#7-dockerfile)
8. [Common Failures and Solutions](#8-common-failures)
9. [Render Platform Constraints](#9-render-constraints)

---

## 1. Quick Reference — Working Deployment

| Resource | Value |
|----------|-------|
| Service Name | `beef-harness` |
| Service ID | `[REDACTED]` |
| Render Dashboard | `[REDACTED]` |
| BeEF Admin UI | `https://beef-harness.onrender.com/ui/panel/` |
| BeEF Hook URL | `https://beef-harness.onrender.com/hook.js` |
| Auth Page | `https://beef-harness.onrender.com/ui/authentication` |
| REST API Login | `POST /api/admin/login` |
| GitHub Repo | `https://github.com/Kejkey515/test` |
| Username | `redteam` |
| Password | `[REDACTED]` |
| Owner ID | `[REDACTED]` |

---

## 2. File Inventory

| File | Purpose | Critical? |
|------|---------|-----------|
| `Dockerfile` | Multi-stage build: clone BeEF → install gems → runtime | YES |
| `config.yaml` | BeEF configuration with Render-specific overrides | YES |
| `docker-compose.yml` | Local testing with volume mount | Optional |
| `.dockerignore` | Exclude .git, test/, docs/ from build context | Optional |
| `render.yaml` | Render Blueprint IaC (service + disk) | Optional |
| `README.md` | Deployment guide | Optional |
| `PLAN.md` | Architecture diagram + deployment plan | Reference |

---

## 3. Render API — Exact Working Payloads

### Authentication
```
Authorization: Bearer rnd_xxx
```

### List Owners (get workspace ID)
```
GET https://api.render.com/v1/owners
```
Returns: `[{"owner":{"id":"tea-xxx","name":"My Workspace","type":"team"}}]`

### Create Web Service
```
POST https://api.render.com/v1/services
Content-Type: application/json
```

**EXACT WORKING PAYLOAD:**
```json
{
  "type": "web_service",
  "name": "beef-harness",
  "ownerID": "[REDACTED]",
  "repo": "https://github.com/Kejkey515/test",
  "branch": "main",
  "autoDeploy": "yes",
  "serviceDetails": {
    "runtime": "docker",
    "dockerfilePath": "./Dockerfile",
    "plan": "free",
    "envVars": [
      {"key": "PORT", "value": "3000"},
      {"key": "RACK_ENV", "value": "production"}
    ]
  }
}
```

**CRITICAL: Use `--http1.1` flag with curl.** The Render API has SSL issues with HTTP/2 on some environments. Without this flag, you get `OpenSSL SSL_read: error:0A000126:SSL routines::unexpected eof while reading`.

### Create Service — Key Gotchas

| Gotcha | Detail |
|--------|--------|
| `type` | Must be `"web_service"` (NOT `"web"`) |
| `ownerID` | Must use camelCase `ownerID`, NOT `owner_id` |
| `repo` | Must be a string URL, NOT an object `{"repo":"..."}` |
| `runtime` | Must be `"docker"` inside `serviceDetails` |
| `plan` | `"free"` or `"starter"` (free tier requires billing info on account) |
| SSL | Use `curl --http1.1` for ALL Render API calls |
| Name | Must be unique within workspace |
| Billing | If 403 "Payment information required" → user must add card at dashboard.render.com/billing first |

### Deploy Status
```
GET https://api.render.com/v1/services/{service_id}/deploys?limit=1
```
Returns: `{ "status": "build_in_progress" | "update_in_progress" | "live" | "build_failed" | "update_failed" }`

### Trigger Deploy
```
POST https://api.render.com/v1/services/{service_id}/deploys
Content-Type: application/json
{"clear_cache": false}
```

### Get Build Logs
```
GET https://api.render.com/v1/logs?ownerId={owner_id}&resource={service_id}&type=build&limit=200&direction=backward
```

**Note:** The log endpoint is `/v1/logs` (NOT `/v1/services/{id}/logs` or `/v1/deploys/{id}/logs`). These return 404.

### Get App Logs (runtime errors)
```
GET https://api.render.com/v1/logs?ownerId={owner_id}&resource={service_id}&limit=100&direction=backward&type=app
```

### Log Filtering
| Parameter | Values |
|-----------|--------|
| `type` | `app`, `build`, `request` |
| `direction` | `backward` (newest first), `forward` (oldest first) |
| `text` | Search string (e.g., `text=Admin` to find Admin UI logs) |

---

## 4. GitHub API — File Upload

### Authentication
```
Authorization: token github_pat_xxx
```

**Fine-grained tokens need:** Repository permissions → Contents: Read and Write

If token is read-only, you get: `"message": "Resource not accessible by personal access token"`

### Upload/Update File
```
PUT https://api.github.com/repos/{owner}/{repo}/contents/{path}
Content-Type: application/json
```

**Payload:**
```json
{
  "message": "commit message",
  "content": "<base64-encoded-file-content>",
  "sha": "<current-file-sha>"
}
```

**Steps:**
1. GET the file to get its current `sha`
2. base64-encode the new content
3. PUT with both `content` and `sha`

**If you omit `sha` for an existing file:** you get `"is at abc123 but expected def456"` (race condition / concurrent update)

**Use Python for reliable encoding:**
```python
import base64, json, urllib.request

with open('file.txt', 'r') as f:
    content = f.read()

# Get SHA
req = urllib.request.Request(url, headers={'Authorization': 'token ...'})
sha = json.loads(urllib.request.urlopen(req).read())['sha']

# Update
payload = json.dumps({
    'message': 'Update',
    'content': base64.b64encode(content.encode()).decode(),
    'sha': sha
}).encode()

req = urllib.request.Request(url, data=payload, headers={...}, method='PUT')
urllib.request.urlopen(req)
```

### Git Push Alternative (if token has push access)
```bash
git push -u https://{user}:{token}@github.com/{user}/{repo}.git main --force
```
**This requires `repo` scope (classic token) or Contents write permission.** Many fine-grained tokens don't have this even if they can read the repo.

---

## 5. Bug Fixes Applied (4 Iterations)

### Bug 1: Missing Gemfile (build failed)
- **Symptom:** `Could not locate Gemfile` in build logs
- **Cause:** Dockerfile used `COPY . /beef` but repo only contained config files, not BeEF source
- **Fix:** Clone BeEF from GitHub in the builder stage: `RUN git clone --depth 1 https://github.com/beefproject/beef.git /beef`
- **Then** `COPY config.yaml /beef/config.yaml` to overlay our config

### Bug 2: Missing `git` binary (container crash)
- **Symptom:** `/beef/beef:59:in 'Kernel#`': No such file or directory - git (Errno::ENOENT)`
- **Cause:** `ruby:3.4-slim-bookworm` runtime image doesn't include `git`; BeEF's `beef` entrypoint script calls `git` to detect version
- **Fix:** Add `git` to runtime apt-get install list

### Bug 3: Permission denied on Admin UI build (container crash)
- **Symptom:** `Permission denied @ rb_sysopen - /beef/extensions/admin_ui/api/../media/javascript-min/web_ui_all.js`
- **Cause:** BeEF clones as root, but runs as `beef` user. The `beef` user can't write to `/beef/` to build Admin UI JavaScript
- **Fix:** `chown -R beef:beef /beef` in Dockerfile (entire directory, not just `/beef/data`)

### Bug 4: "Host not permitted" (403 on all requests)
- **Symptom:** All HTTP requests return `403 Host not permitted`
- **Cause:** Rack::Protection::HostAuthorization in BeEF's `core/main/router/router.rb` checks the Host header against an allowed list. Only `localhost`, `test`, `0.0.0.0/0`, `::/0`, and `beef.http.public.host` are permitted.
- **Fix:** Add `public:` section under `http:` in config.yaml:
  ```yaml
  http:
      public:
          host: "your-service.onrender.com"
          port: "443"
          https: true
  ```
- **Also needed:** `git config --global --add safe.directory /beef` to suppress dubious ownership warning

### Bug 5: Browser not appearing as zombie (WebSocket port not exposed)
- **Symptom:** BeEF loads, login works, hook.js served correctly, but browsers don't appear in zombie list when visiting `/demos/basic.html`
- **Cause:** BeEF's hook.js tries to connect via WebSocket on ports 61985/61986, but Render only exposes port 443. The browser can't reach the WebSocket server, so it never connects back to BeEF.
- **Fix:** Disable WebSocket in config.yaml so BeEF falls back to XHR polling on port 443:
  ```yaml
  websocket:
      enable: false  # Render only exposes one port (443), not 61985/61986
  ```
- **Verification:** After redeploy, open `/demos/basic.html` in browser → browser should appear in zombie list

---

## 6. config.yaml — Critical Keys

### Bind Address
```yaml
beef:
    http:
        host: "0.0.0.0"    # MUST be 0.0.0.0 (not 127.0.0.1) for Render
```

### Public Host (THE most missed config)
```yaml
beef:
    http:
        public:
            host: "your-service.onrender.com"  # Your Render URL without https://
            port: "443"                         # Always 443 for Render (HTTPS)
            https: true                         # Render provides TLS termination
```

**The YAML nesting matters.** It's NOT `public_host: "..."`. It's nested under `public:` with sub-keys `host`, `port`, `https`.

### Credentials
```yaml
beef:
    credentials:
        user: "redteam"
        passwd: "[CHANGE_ME]"  # BeEF uses plain text passwords, NOT bcrypt hashes
```

**CRITICAL:** BeEF uses **PLAIN TEXT passwords**, NOT bcrypt hashes. The `passwd` field is compared directly as a string. If you use a bcrypt hash, login will always fail.

**To generate bcrypt hash (DO NOT USE for BeEF):**
```bash
htpasswd -bnBC 10 "" 'YourPassword' | tr -d ':\n'
```
This is only useful for other services like Apache/nginx basic auth.

### Restrictions
```yaml
beef:
    restrictions:
        permitted_hooking_subnet: ["0.0.0.0/0", "::/0"]
        permitted_ui_subnet: ["0.0.0.0/0", "::/0"]
```

### Reverse Proxy (required for Render)
```yaml
beef:
    http:
        allow_reverse_proxy: true  # Trust X-Forwarded-For from Render's proxy
```

### WebSocket (MUST be disabled on Render)
```yaml
beef:
    http:
        websocket:
            enable: false  # Render only exposes port 443, not 61985/61986
```

**Why:** BeEF's hook.js tries to connect via WebSocket on ports 61985 (ws) or 61986 (wss). Render only exposes port 443. If WebSocket is enabled, the browser can't connect back to BeEF and won't appear as a zombie.

**Fallback:** When WebSocket is disabled, BeEF falls back to XHR polling on port 443, which works correctly on Render.

### Demo Pages
```yaml
beef:
    extension:
        demos:
            enable: true  # Enable demo pages at /demos/
```

**Demo URL:** `https://your-service.onrender.com/demos/basic.html`

The demo page loads hook.js and should hook the browser into BeEF.

### Zombie API
```
GET /api/hooks?token=TOKEN
```

Returns:
```json
{
  "hooked-browsers": {
    "online": { "hooked-session-id": { ... } },
    "offline": {}
  }
}
```

If `online` is empty, the browser hasn't connected back to BeEF (check WebSocket config, hook.js URL, or browser console errors).

### Official Config Reference
Full default config at: `https://raw.githubusercontent.com/beefproject/beef/ffc86bd77acdacff10756d20a170ae9822a43c39/config.yaml`

---

## 7. Dockerfile — Non-Obvious Requirements

### Must Clone BeEF (not just COPY)
The repo should NOT contain BeEF source. Clone it in the builder:
```dockerfile
RUN git clone --depth 1 https://github.com/beefproject/beef.git /beef
COPY config.yaml /beef/config.yaml
```

### Git in Runtime (critical)
BeEF's entrypoint calls `git` at startup. Without it, container crashes immediately:
```dockerfile
apt-get install -y ... git
```

### Git Safe Directory
Cloned files owned by root but running as `beef` user causes "dubious ownership":
```dockerfile
RUN git config --global --add safe.directory /beef
```

### Full Ownership Transfer
Admin UI JavaScript compilation requires write access to entire `/beef`:
```dockerfile
RUN chown -R beef:beef /beef
```

### Working Dockerfile
See `Dockerfile` in this repo. Key structure:
1. **Builder stage:** Ruby 3.4-slim + build deps → clone BeEF → bundle install
2. **Runtime stage:** Ruby 3.4-slim + runtime deps + git → copy bundle + beef → fix ownership → run as beef user

---

## 8. Common Failures and Solutions

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Could not locate Gemfile` | No BeEF source in build context | Clone BeEF in Dockerfile builder stage |
| `No such file or directory - git` | Missing git in runtime image | Add `git` to runtime apt-get install |
| `Permission denied @ rb_sysopen` | beef user can't write to /beef | `chown -R beef:beef /beef` |
| `Host not permitted` (403) | Missing public host config | Add `http.public.host` in config.yaml |
| `dubious ownership in repository` | Git ownership mismatch | `git config --global --add safe.directory /beef` |
| `invalid JSON` on Render API | Wrong field names | Use `ownerID` (camelCase), `type: "web_service"` |
| `Payment information required` | No billing on Render account | Add card at dashboard.render.com/billing |
| SSL error with Render API | HTTP/2 incompatibility | Use `curl --http1.1` for ALL Render API calls |
| `name already in use` | Duplicate service name | Choose a unique name |
| Deploy `update_failed` | Container crash after build | Check app logs at `/v1/logs?type=app` |
| Login always fails | Used bcrypt hash in config.yaml | BeEF uses plain text passwords in config.yaml |
| REST API returns empty | Wrong endpoint | Use `/api/admin/login` (NOT `/ui/authentication/login`) |
| Health check fails | Root returns 403 or 404 | Expected — BeEF doesn't serve root by default; use `/ui/authentication` |
| Proxy SSL errors in logs | Normal behavior | BeEF proxy extension attempts HTTPS connections; harmless |

---

## 9. Render Platform Constraints

| Constraint | Detail |
|------------|--------|
| Public ports | Only one web service port exposed (set by `$PORT`) |
| TLS | Render terminates TLS; internal traffic is HTTP |
| Free tier | Sleeps after 15 min inactivity; requires billing to deploy |
| Starter plan | $7/mo; stays awake; recommended for BeEF |
| Build timeout | 20 minutes; BeEF builds in ~5-8 min |
| Persistent disk | Required for SQLite DB (`/beef/data`); free tier doesn't support disks |
| WebSocket | Works over HTTPS on Render |
| Logs | Available via API at `/v1/logs`; NOT at `/v1/services/{id}/logs` |
| Auto-deploy | Set `autoDeploy: "yes"` to redeploy on git push |
| Region | `oregon` is default; choose closest to users |

### Render API Gotchas
- Use `--http1.1` with curl (HTTP/2 causes SSL errors)
- `type` for services is `web_service` (not `web`)
- `ownerID` is camelCase (not `owner_id`)
- `repo` is a string URL (not an object)
- Service names must be unique within workspace
- Billing info required even for free tier deploys
- Logs endpoint is `/v1/logs` with `resource` and `type` params (not nested under service)
- Deploy trigger returns immediately; poll `/deploys?limit=1` for status

---

## Appendix A: BeEF URL Paths

| Path | Description |
|------|-------------|
| `/hook.js` | Hook JavaScript (inject into targets) |
| `/api/admin/login` | REST API login endpoint (returns JSON token) |
| `/api/hooks` | List hooked browsers (zombies) |
| `/ui/panel/` | Admin panel (redirects to auth) |
| `/ui/authentication` | Login page (HTML form) |
| `/demos/basic.html` | Demo hook page — open in browser to test hooking |
| `/` | Apache test page (web_server_imitation) |
| `/ui/media/javascript/ext-base.js` | ExtJS base library |
| `/ui/media/javascript/ext-all.js` | ExtJS full library |

## Appendix B: Web UI Login Limitation (Behind Reverse Proxy)

### Problem
BeEF's web admin panel (`/ui/authentication` → `/ui/panel/`) does not work behind Render's reverse proxy. After login, it redirects back to the authentication page in an infinite loop.

### Root Cause
BeEF validates the `BEEFSESSION` cookie against the client IP address on each request. Cloudflare and Render's proxy change the client IP between requests, so the session is always rejected.

### Evidence
- Login succeeds: `POST /ui/authentication/login` returns `{"success":true}` and sets `BEEFSESSION` cookie
- Panel access fails: `GET /ui/panel/` returns `302 → /ui/authentication` even with valid cookie
- Cookie is `httponly` but NOT `secure` — browser won't send it back over HTTPS without `Secure` flag

### Workaround
**Use the REST API instead** — it works perfectly and is the standard approach in real engagements.

```bash
# Login
TOKEN=$(curl -s -X POST "https://beef-harness.onrender.com/api/admin/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"redteam","password":"[CHANGE_ME]"}' | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

# List zombies
curl -s "https://beef-harness.onrender.com/api/hooks?token=$TOKEN"

# Execute module on zombie
curl -s -X POST "https://beef-harness.onrender.com/api/hooks/0/commandmodules/{module_id}?token=$TOKEN"
```

### This affects ALL reverse-proxy deployments
Not specific to Render. Any BeEF instance behind Cloudflare, nginx, Apache, or any reverse proxy with IP rotation will have this issue.

---

## Appendix C: BeEF REST API Authentication

**Correct endpoint:** `POST /api/admin/login`

**Request:**
```json
{
  "username": "redteam",
  "password": "[CHANGE_ME]"
}
```

**Response:**
```json
{
  "success": true,
  "token": "9092686a86bf941b9ff409370a0dee08e79b0f90"
}
```

**Usage with token:**
```bash
curl -s https://beef-harness.onrender.com/api/hooks?token=<TOKEN>
```

**Common mistakes:**
- ❌ `/ui/authentication/login` — This is the HTML form endpoint, NOT the REST API
- ❌ `/api/ui/authentication/login` — Wrong path
- ✅ `/api/admin/login` — Correct REST endpoint with `username`/`password` in JSON body

**Credentials in config.yaml are plain text, NOT bcrypt hashes:**
```yaml
beef:
    credentials:
        user: "redteam"
        passwd: "[CHANGE_ME]"  # Set via env var BEEF_PASSWORD at runtime
```

## Appendix D: Hooked Browsers (Zombies)

### Check Zombie Count
```bash
# Login first
TOKEN=$(curl -s -X POST https://beef-harness.onrender.com/api/admin/login \
  -H "Content-Type: application/json" \
  -d '{"username":"redteam","password":"[CHANGE_ME]"}' | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])")

# List zombies
curl -s "https://beef-harness.onrender.com/api/hooks?token=$TOKEN"
```

**Response when no browsers hooked:**
```json
{"hooked-browsers":{"online":{},"offline":{}}}
```

**Response with hooked browser:**
```json
{"hooked-browsers":{"online":{"192.168.1.100":{"hooked":true,"ip":"192.168.1.100","...": "..."}}, "offline":{}}}
```

### Demo Page (Test Hooking)
```
https://beef-harness.onrender.com/demos/basic.html
```

This page loads `/hook.js` and connects the browser as a zombie. Open it in any browser to see it appear in the zombies list.

### Other API Endpoints
| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/admin/login` | POST | Login, get token |
| `/api/hooks` | GET | List all zombies |
| `/api/hooks/{zombie_ip}/commandmodules` | GET | List available modules for a zombie |
| `/api/hooks/{zombie_ip}/commandmodules/{module_id}` | POST | Execute a module on a zombie |

## Appendix E: Render API Endpoints Used

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/v1/owners` | Get workspace/owner ID |
| POST | `/v1/services` | Create new service |
| GET | `/v1/services/{id}/deploys?limit=1` | Check deploy status |
| POST | `/v1/services/{id}/deploys` | Trigger new deploy |
| GET | `/v1/logs?ownerId=X&resource=Y&type=Z` | Get build/app logs |

## Appendix F: Deployment Checklist

- [ ] Render account has billing info (even for free tier)
- [ ] GitHub token has Contents: Read and Write permission
- [ ] config.yaml has correct `public.host` (your actual Render URL)
- [ ] config.yaml has `websocket.enable: false` (Render only exposes port 443)
- [ ] config.yaml has plain text password (NOT bcrypt hash)
- [ ] Dockerfile clones BeEF AND installs git in runtime stage
- [ ] Dockerfile runs `chown -R beef:beef /beef`
- [ ] Dockerfile runs `git config --global --add safe.directory /beef`
- [ ] `curl --http1.1` used for all Render API calls
- [ ] Service name is unique in workspace
- [ ] After deploy: verify `/ui/authentication` returns 200
- [ ] After deploy: verify `/hook.js` returns JavaScript content
- [ ] After deploy: verify login with `POST /api/admin/login` returns `{"success":true,"token":"..."}`
- [ ] After deploy: open `/demos/basic.html` in browser → check zombies API for hooked browser

## Appendix G: Current Deployment Status

### Last Verified: 2026-07-10

| Check | Status |
|-------|--------|
| Service running | ✅ `https://beef-harness.onrender.com` returns 200 |
| Admin UI accessible | ✅ `/ui/authentication` returns 200 |
| Hook.js served | ✅ `/hook.js` returns JavaScript with correct host config |
| REST API login | ✅ `POST /api/admin/login` returns `{"success":true,"token":"..."}` |
| WebSocket disabled | ✅ `config.yaml` has `websocket.enable: false` |
| Demo page available | ✅ `/demos/basic.html` loads hook.js |
| Zombies API working | ✅ `/api/hooks?token=TOKEN` returns hooked browsers |
| **Browser hooking** | ✅ **CONFIRMED** — Chrome 149 on Linux hooked successfully |

### Verified Zombie Connection (2026-07-10)

```json
{
    "hooked-browsers": {
        "online": {
            "0": {
                "id": 1,
                "session": "0U6uROguEfEbe2cj8GgNcYtcuh8KXIHVqU9pnnkktQu3gKZYIZJDjwS6G2OkrsaT0k0UY2hwpdgElMz3",
                "name": "C",
                "version": "149.0.0.0",
                "platform": "Linux x86_64",
                "os": "Linux",
                "ip": "192.42.116.94, 172.71.150.98, 10.26.67.134",
                "domain": "beef-harness.onrender.com",
                "port": "443",
                "page_uri": "https://beef-harness.onrender.com/demos/basic.html",
                "firstseen": "1783675683",
                "lastseen": "1783675706"
            }
        },
        "offline": {}
    }
}
```

### How to Hook a Browser
1. Open `https://beef-harness.onrender.com/demos/basic.html` in any browser
2. The page loads hook.js which connects back to BeEF via XHR polling
3. Browser should appear in zombies list within a few seconds
4. Verify with: `curl -s "https://beef-harness.onrender.com/api/hooks?token=TOKEN"`

### How to Execute Commands on a Zombie
```bash
# List available modules for a zombie
curl -s "https://beef-harness.onrender.com/api/hooks/0/commandmodules?token=$TOKEN"

# Execute a module (e.g., get browser details)
curl -s -X POST "https://beef-harness.onrender.com/api/hooks/0/commandmodules/1?token=$TOKEN"
```

### Troubleshooting
- **Browser not appearing:** Check browser console for errors, verify hook.js loads, ensure WebSocket is disabled
- **Login fails:** Verify plain text password in config.yaml (NOT bcrypt hash)
- **403 errors:** Verify `public.host` matches your Render URL exactly
- **Container crashes:** Check Render logs for missing git, permission errors, or config issues
- **Zombie goes offline:** Browser tab was closed or navigated away; XHR polling stops
