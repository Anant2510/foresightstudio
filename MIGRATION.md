# Foresight Studio — GitHub Pages → xPerion Azure VM

**VM:** `xPerion2` · Windows Server 2025 · Central India · Standard_B2as_v2
**Target address:** `https://xperion2.centralindia.cloudapp.azure.com/foresightstudio/` (free Azure name; see Phase 2)

## What changes

| | GitHub Pages (today) | Azure VM (after) |
|---|---|---|
| API key | In `config.js`, readable by anyone who opens the page | `C:\xperion\secrets`, readable only by the app server |
| AI calls | Browser → Anthropic | Browser → VM → Anthropic, rate-limited per visitor |
| HTTPS | GitHub | Caddy with a free Let's Encrypt certificate that renews itself |
| Deploy | Push to `main` → Pages | Push to `main` → VM picks it up within ~2 minutes |
| After a reboot | — | Starts on its own (Windows service + startup task) |

```
Visitor ──HTTPS──▶ Caddy (80/443) ──▶ App server, Node (127.0.0.1:8790) ──▶ api.anthropic.com
                                         │  serves the app, adds the API key,
                                         │  rate-limits, optional login
                                         └─ checks GitHub every 2 min for a new index.html
```

The updated `index.html` works on both Pages and the VM, so Pages keeps running until you cut over in Phase 6.

---

## Phase 0 — VM check ✅ done

Windows Server 2025, ports 80/443 free, no IIS, Node 24 installed, Anthropic reachable.

## Phase 1 — Push the updated repo

Replace the repo contents with this package and push to `main`. Pages redeploys as usual.

## Phase 2 — Azure and Anthropic prep (portal, ~5 min)

1. **New API key.** Anthropic Console → API keys → create `foresight-azure-vm`. Don't reuse the GitHub key: it has been publicly readable in `config.js`.
2. **Open the ports.** VM `xPerion2` → Networking → *Add inbound port rule*: TCP `80,443`, source *Any*, action *Allow*. (Restrict the source to Coforge/client ranges if the demo is invite-only.)
3. **Give the VM a name.** VM → Overview → *DNS name: Not configured* → enter `xperion2` → Save. You get `xperion2.centralindia.cloudapp.azure.com`, which is needed for the HTTPS certificate.

## Phase 3 — Get the kit onto the VM

On the VM, in **PowerShell as Administrator**:

```powershell
Invoke-WebRequest https://github.com/anant2510/foresightstudio/archive/refs/heads/main.zip -OutFile "$env:TEMP\fs.zip" -UseBasicParsing
Expand-Archive "$env:TEMP\fs.zip" C:\xperion-src -Force
cd C:\xperion-src\foresightstudio-main
```

If the repo is private, copy the zip into the VM over Remote Desktop instead and unzip it to the same place.

## Phase 4 — Run setup

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\windows\setup.ps1 -Domain xperion2.centralindia.cloudapp.azure.com -Email <your-email>
```

It asks for three things: the new API key (hidden as you paste), whether to add a username/password, and a GitHub token if the repo is private. Then it:

- installs the app server to `C:\xperion` and locks the folders down (the key file is readable only by the app server)
- registers the app server to start with Windows, running under the low-privilege LOCAL SERVICE account
- opens Windows Firewall for 80/443
- downloads Caddy (checksum-verified), sets it up as the `xperion-web` service and gets the certificate
- tests the page, the absence of any key in the page, and a live AI call

Finish line: green **"Foresight Studio is live"**. On your laptop, open the URL, confirm the landing page shows **AI Engine Ready**, and run one demo creative.

Security check from your laptop. It should show the `FORESIGHT_PROXY` line and no key:

```powershell
curl.exe -s https://xperion2.centralindia.cloudapp.azure.com/foresightstudio/config.js
```

No DNS name yet? Run setup without `-Domain` to go live on `http://<public-ip>/foresightstudio/` straight away, then re-run with `-Domain` later. It keeps your key and settings.

## Phase 5 — Confirm auto-deploy

Push any small change to `main`. Within about 2 minutes, this log on the VM shows `deploy updated index.html to <commit>`:

```powershell
Get-Content C:\xperion\logs\foresight-server.log -Tail 20
```

It refuses to deploy a file that contains an API key or lacks server-proxy support, and logs why.

## Phase 6 — Cutover

1. GitHub → Settings → Secrets and variables → Actions → **Variables** → add `FORESIGHT_URL` = `https://xperion2.centralindia.cloudapp.azure.com/foresightstudio/`.
2. Copy `deploy/cutover/deploy.yml` over `.github/workflows/deploy.yml` and push. The old github.io link now redirects to the VM. Query strings are dropped, so old `?key=` links stop carrying keys.
3. Delete the `FORESIGHT_KEY` repo secret.
4. Revoke the old key in the Anthropic Console.
5. Update the link in the gist deck, cheat sheet, demo script and bookmarks.

---

## Rollback

Until Phase 6, Pages is untouched, so you can share the old link. To remove the VM setup:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\windows\uninstall.ps1              # keeps C:\xperion
powershell -ExecutionPolicy Bypass -File .\deploy\windows\uninstall.ps1 -RemoveFiles # deletes it too
```

## Day-2 (PowerShell as Administrator on the VM)

| Task | Command |
|---|---|
| Health | `curl.exe -s http://127.0.0.1:8790/healthz` |
| Status | `Get-ScheduledTask "xPerion Foresight Server" \| Get-ScheduledTaskInfo` and `Get-Service xperion-web` |
| App log | `Get-Content C:\xperion\logs\foresight-server.log -Tail 50` |
| Caddy log | `Get-Content C:\xperion\logs\caddy.log -Tail 50` |
| Restart app server | `Stop-ScheduledTask "xPerion Foresight Server"; Start-ScheduledTask "xPerion Foresight Server"` |
| Restart Caddy | `Restart-Service xperion-web` |
| Rotate the key | Re-run setup and answer `n` to keeping the key (takes effect without a restart) |
| Add/remove the login | Re-run setup and choose |
| Change the rate limit | Edit `rateLimit` in `C:\xperion\foresightstudio\server\config.json`, then restart the app server |
| Update Caddy | Re-run setup with `-UpdateCaddy` |
| Host another xPerion demo | Add a `handle /<app>* { reverse_proxy 127.0.0.1:<port> }` block in `C:\xperion\caddy\Caddyfile`, then `Restart-Service xperion-web` |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Setup stalls at "Waiting for the HTTPS certificate" | Ports 80/443 closed in the NSG, or DNS name not set | Phase 2, then check `caddy.log` and re-run setup |
| Landing shows "AI Engine unavailable: 401" | Key wrong or revoked | Re-run setup with a valid key |
| "AI Engine unavailable: 502" | VM can't reach `api.anthropic.com` | Check outbound rules or a corporate proxy |
| "429 Too many requests" | Rate limit (60/min per visitor, burst 30) | Wait a minute or raise the limit |
| A push isn't live after 5 minutes | GitHub unreachable, private repo without a token, or file refused | App log shows the reason |
| Site down after a reboot | App server task not running | Check status and the app log; the task revives itself within a minute |
