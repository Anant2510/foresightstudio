# Foresight Studio — Deployment Guide

## Predict Creative Performance Before Launch

This guide walks you through deploying Foresight Studio to GitHub Pages with automatic API key injection so your stakeholders never have to enter a key.

---

## Prerequisites

- A **GitHub account** (free is fine)
- A **GitHub repository** (public or private)
- Your **LLM API secret key** (e.g. `sk-ant-api03-xxxxx`)
- **Git** installed on your machine (or use GitHub's web UI)

---

## What You're Deploying

| File | Committed to Git? | Purpose |
|------|-------------------|---------|
| `index.html` | Yes | The Foresight Studio application |
| `.gitignore` | Yes | Tells Git to never track `config.js` |
| `.github/workflows/deploy.yml` | Yes | Automates deployment with key injection |
| `config.js` | **Never** | Generated at deploy time from your secret |

---

## Step-by-Step Setup

### Step 1: Create a GitHub Repository

1. Go to [github.com/new](https://github.com/new)
2. Repository name: `foresightstudio`
3. Choose **Public** or **Private**
4. Click **"Create repository"**

### Step 2: Upload Your Files

#### Using GitHub Web UI:

1. Click **"Add file"** → **"Upload files"**
2. Upload `index.html` and `.gitignore`
3. Commit with message: `Add Foresight Studio app`
4. Click **"Add file"** → **"Create new file"**
5. Type: `.github/workflows/deploy.yml`
6. Paste the deploy.yml contents
7. Commit

#### Using Git:

```bash
git clone https://github.com/YOUR_USERNAME/foresightstudio.git
cd foresightstudio
# Copy index.html, .gitignore, .github/workflows/deploy.yml
git add .
git commit -m "Add Foresight Studio with deploy workflow"
git push origin main
```

### Step 3: Add Your API Key as a Secret

1. Go to repo **Settings** → **Secrets and variables** → **Actions**
2. Click **"New repository secret"**
3. Name: `FORESIGHT_KEY`
4. Value: your API key (e.g. `sk-ant-api03-xxxxx`)
5. Click **"Add secret"**

> **Important:** The name must be exactly `FORESIGHT_KEY`.

### Step 4: Enable GitHub Pages

1. Go to **Settings** → **Pages**
2. Source: change to **"GitHub Actions"**

### Step 5: Deploy

1. Go to **Actions** tab
2. The workflow runs automatically on push
3. Green checkmark = your site is live

### Step 6: Access Your Site

```
https://YOUR_USERNAME.github.io/foresightstudio/
```

The API key is auto-loaded. No setup needed for end users.

---

## How It Works

```
Push to main
    │
    ▼
GitHub Actions starts
    │
    ▼
Creates config.js: window.FORESIGHT_KEY = 'sk-ant-...';
    │
    ▼
Deploys to GitHub Pages
    │
    ▼
User opens URL → config.js loads → key auto-detected
    │
    ▼
Landing page shows → Click "Launch Studio" → Ready
```

---

## Key Resolution Priority

| Priority | Source | Scenario |
|----------|--------|----------|
| 1 | `config.js` | Deployed via GitHub Actions (recommended) |
| 2 | `localStorage` | Return visitor |
| 3 | URL `?key=...` | Shared link with key |
| 4 | URL `#key=...` | Key in hash (safer) |
| 5 | URL `?bkey=...` | Base64-encoded key (safest for links) |

---

## Updating

### Update the app
Push changes to `main` — auto-redeploys.

### Change the API key
Settings → Secrets → edit `FORESIGHT_KEY` → Re-run workflow.

---

## Local Development

Create a local `config.js`:
```javascript
window.FORESIGHT_KEY = 'sk-ant-api03-your-key-here';
```

Run a local server:
```bash
python3 -m http.server 8000
```

Open `http://localhost:8000`

> Opening via `file://` won't load config.js due to browser security. Always use a local server.

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Pages deploy fails | Settings → Pages → Source → "GitHub Actions" |
| Key not loading | Check secret name is exactly `FORESIGHT_KEY` |
| "Awaiting key" on landing | config.js wasn't generated — check Actions for errors |
| Works locally but not hosted | Ensure deploy.yml is in `.github/workflows/` |
