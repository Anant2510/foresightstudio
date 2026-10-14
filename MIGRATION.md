# xPerion demo apps on the Azure VM

**VM:** `xPerion2` · Windows Server 2025 · Central India
**AI Engine:** Claude in Microsoft Foundry, `dxp-ai-6530-resource`, deployment `claude-sonnet-5-5`

| App | Address | GitHub repo | AI |
|---|---|---|---|
| Foresight Studio | https://xperion2.centralindia.cloudapp.azure.com/foresightstudio/ | `anant2510/foresightstudio` | Yes |
| CareAI | https://xperion2.centralindia.cloudapp.azure.com/careai/ | `anant2510/CareAI` | — |
| VoyagerAI | https://xperion2.centralindia.cloudapp.azure.com/voyagerai/ | `anant2510/VoyagerAI` | — |
| WealthAI | https://xperion2.centralindia.cloudapp.azure.com/wealthai/ | `anant2510/wealthai` | — |
| IntelliSight (WestJet / Fifth Third AA dashboard) | https://xperion2.centralindia.cloudapp.azure.com/westjet-aa-dashboard/ | `anant2510/westjet-aa-dashboard` | Yes |

Old-style capitalised paths also work: `/CareAI/` forwards to `/careai/`.

## How it works

```
Visitor ──HTTPS──▶ Caddy (80/443) ──▶ App server, Node (127.0.0.1:8790) ──▶ Foundry: dxp-ai-6530-resource
                                        │  serves every app at its own path
                                        │  AI apps: adds the key, pins the model, rate-limits per visitor
                                        └─ mirrors each app's GitHub repo every 2 minutes
```

- **Deploying** is unchanged: push to an app's `main` branch, and it's live within about 2 minutes. Only changed files are downloaded, each one is checked against its git hash, and `index.html` is written last.
- **Safety checks:** an update is refused, and the last good version keeps serving, if any text file contains an Anthropic key, or if an AI app's `index.html` lacks server-proxy support. The reason shows in the log.
- **The list of apps** lives in `deploy/windows/apps.json` in the `foresightstudio` repo.

---

## This update: adding four apps

1. **WestJet dashboard repo.** Upload the patched `index.html` to `anant2510/westjet-aa-dashboard`, replacing the old one. It keeps working on GitHub Pages; on the VM it uses the server's AI proxy.
2. **foresightstudio repo.** Upload the `deploy` folder and `MIGRATION.md`, replacing the old ones. This brings the multi-app server, setup, app list and redirect workflow.
3. **VM, in PowerShell as Administrator:**

```powershell
Remove-Item C:\xperion-src -Recurse -Force
Invoke-WebRequest https://github.com/anant2510/foresightstudio/archive/refs/heads/main.zip -OutFile "$env:TEMP\fs.zip" -UseBasicParsing
Expand-Archive "$env:TEMP\fs.zip" C:\xperion-src -Force
cd C:\xperion-src\foresightstudio-main
powershell -ExecutionPolicy Bypass -File .\deploy\windows\setup.ps1 -Domain xperion2.centralindia.cloudapp.azure.com -Email anant.2.singh@coforge.com
```

Setup carries over the Foundry endpoint, model and key from the Foresight install. Answer **Y** to keeping the key. It moves Foresight into the new layout, downloads all five apps from GitHub (the WestJet datasets take a minute), and tests each one. From now on it also remembers the domain, so later runs need no options.

## Cutover: retire the GitHub Pages copies

**Do this now for the two AI apps.** Their Pages sites publish an Anthropic key.

1. In the repo, open `.github/workflows/deploy.yml` → pencil icon → replace the contents with `deploy/cutover/deploy.yml` from the foresightstudio repo (use **Copy raw file**) → commit.
2. Wait for the green tick under **Actions**, then confirm the github.io link redirects to the VM.
3. **Settings → Secrets and variables → Actions → Secrets**: delete `FORESIGHT_KEY` (foresightstudio) or `INTELLISIGHT_KEY` (westjet-aa-dashboard).
4. Revoke those keys in the Anthropic Console.

**Optional for CareAI, VoyagerAI and WealthAI.** These have no secrets. To redirect them:
1. Create `.github/workflows/deploy.yml` with the same contents.
2. Set **Settings → Pages → Source** to **GitHub Actions**.

Or simply leave their Pages sites running.

Update links in decks, one-pagers, demo scripts and bookmarks to the addresses in the table above.

## Adding another app later

1. The repo needs an `index.html` at its root. Single-file and React-from-CDN apps work as they are. For apps published with `npm run deploy` (like the Emirates VoyagerAI demo), use `"branch": "gh-pages"`, which holds the built files. The app's name in `apps.json` should match the path its build expects.
2. If the app calls the AI Engine directly from the browser, it needs the same small proxy patch as Foresight and IntelliSight, plus a `proxyVar` entry.
3. Add a line to `deploy/windows/apps.json`, push, then re-download and re-run setup on the VM.

---

## Rollback

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\windows\uninstall.ps1              # keeps C:\xperion
powershell -ExecutionPolicy Bypass -File .\deploy\windows\uninstall.ps1 -RemoveFiles # deletes it too
```

GitHub Pages copies keep working until you switch them to redirects.

## Day-2 (PowerShell as Administrator on the VM)

| Task | Command |
|---|---|
| Health of every app | `curl.exe -s http://127.0.0.1:8790/healthz` |
| Status | `Get-ScheduledTask "xPerion App Server" \| Get-ScheduledTaskInfo` and `Get-Service xperion-web` |
| App server log (deploys, AI calls) | `Get-Content C:\xperion\logs\app-server.log -Tail 50` |
| Caddy log | `Get-Content C:\xperion\logs\caddy.log -Tail 50` |
| Restart app server | `Stop-ScheduledTask "xPerion App Server"; Start-ScheduledTask "xPerion App Server"` |
| Restart Caddy | `Restart-Service xperion-web` |
| Rotate the key | Re-run setup and answer `n` to keeping the key (takes effect without a restart) |
| Add/remove the login | Re-run setup and choose (applies to all apps) |
| Change the rate limit | Edit `rateLimit` in `C:\xperion\server\config.json`, then restart the app server |
| Switch model / deployment | Re-run setup with `-Model <deployment-name>` |
| Switch AI endpoint | Re-run setup with `-Upstream <url>` and answer `n` to keeping the key |
| Update Caddy | Re-run setup with `-UpdateCaddy` |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Setup: "app not deployed: GitHub returned 404" | Repo name wrong in `apps.json`, or a private repo | Fix the name, or re-run setup and paste a read-only GitHub token |
| Log: "refused …: lacks server-proxy support" | An AI app's repo still has the old `index.html` | Upload the patched `index.html` to that repo |
| Log: "refused …: contains an API key" | A key was committed to the repo | Remove it, push, and revoke that key |
| Log: "GitHub rate limit reached" | Many checks from a public repo without a token | Wait (it resumes on its own) or add a token in setup |
| Landing shows "AI Engine unavailable: 401" | Key wrong or revoked | Re-run setup with a valid key |
| "AI Engine unavailable: 404" | Foundry deployment name doesn't match | Re-run setup with the exact `-Model` name |
| "429 Too many requests" | Rate limit (60/min per visitor, burst 30) | Wait a minute or raise the limit |
| Setup stalls at the HTTPS certificate | Ports 80/443 closed in the NSG, or DNS name not set | Fix in the Azure portal, then check `caddy.log` |
