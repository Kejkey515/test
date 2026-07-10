# BeEF Render Deployment

Browser Exploitation Framework (BeEF) deployed to Render via Docker.

## Quick Start

### Local Testing
```bash
docker-compose up --build
```
- UI: http://localhost:3000/ui/
- Hook: http://localhost:3000/hook.js

### Render Deployment
1. Push this repo to GitHub
2. Go to https://dashboard.render.com/new?type=web
3. Select "Build & deploy from a Git repository"
4. Choose Docker runtime
5. Set persistent disk mount at `/beef/data`

## Credentials
- User: `redteam`
- Pass: `[REDACTED]`

To change credentials:
```bash
# Generate bcrypt hash
htpasswd -bnBC 10 "" 'YourNewPassword' | tr -d ':\n'
```
Update `config.yaml` and restart.

## Ports
| Port | Service |
|------|---------|
| 3000 | BeEF UI / Hook |
| 6789 | Proxy |
| 61985 | WebSocket |
| 61986 | WebSocket Secure |

> Render only exposes port 3000 publicly. Internal ports (6789, 61985, 61986) are accessible within the Docker network.

## Environment Variables
| Var | Default | Description |
|-----|---------|-------------|
| `PORT` | 3000 | Main BeEF port (set by Render) |
| `RACK_ENV` | production | Rails environment |
| `BEEF_CREDENTIALS_USER` | redteam | Admin username |
| `BEEF_CREDENTIALS_PASS` | `[REDACTED]` | Admin password |

## Updating
```bash
git push origin main
```
Render auto-redeploys on push to main branch.
